class_name PlayerController
extends CharacterBody3D
## Gameplay "proxy": a capsule that owns movement (momentum, jump, crouch, slide, roll)
## and a state machine. It drives a physical puppet (RagdollRig) that follows it with
## muscles, and hands control over to the puppet while ragdolled.

signal state_changed(old_state: State, new_state: State)

enum State { IDLE, WALK, RUN, CROUCH, SLIDE, AIR, ROLL, STUMBLE, RAGDOLL, GET_UP, LEDGE_HANG, CLIMB, GRAB, ATTACK, STAGGER }

const CROUCH_STATES: Array[State] = [State.CROUCH, State.SLIDE, State.ROLL, State.CLIMB]
const JUMP_STATES: Array[State] = [State.IDLE, State.WALK, State.RUN, State.CROUCH, State.SLIDE]

@export var config: MovementConfig
@export var body_color := Color(0.22, 0.42, 0.82)
@export var skin_color := Color(0.62, 0.5, 0.42)

var state: State = State.IDLE
var state_time := 0.0
var facing_yaw := 0.0
var camera_yaw := 0.0

## Tests / AI can drive the character instead of the Input singleton.
var use_external_input := false
var external_input := {"move": Vector2.ZERO, "jump": false, "crouch": false, "run": false, "roll": false}

var rig: RagdollRig
var skin: HumanoidSkin
var combat: CombatComponent
var face_target: Node3D = null      ## AI: keep turning toward this while slow / guarding / attacking
var pose_gen := PoseGenerator.new()

## Debug readouts.
var last_impact := 0.0
var last_hit := 0.0

var _in := {}
var _prev_ext := {}
var _shape: CapsuleShape3D
var _col: CollisionShape3D
var _crouched_shape := false
var _coyote := 0.0
var _jump_buffer := 0.0
var _roll_buffer := 99.0
var _roll_cooldown := 0.0
var _takeoff_speed := 0.0
var _land_squash := 0.0
var _skidding := false
var _last_hv := Vector3.ZERO
var _lean := Vector2.ZERO
var _settle := 0.0
var _spawn := Transform3D()
var _ledge := {}             ## current ledge (see _find_ledge)
var _grab_cooldown := 0.0
var _climb_from := Vector3.ZERO
var _climb_to := Vector3.ZERO
var _climb_time := 0.5
var _climb_from_hang := false
var _climb_exit_speed := 0.0
var _shimmy := 0.0
var _carried: RigidBody3D           ## lifted object
var _grabbed: RigidBody3D           ## pushed / pulled object (GRAB state)
var _grab_local := Vector3.ZERO     ## grab point in the object's frame
var _grab_normal_local := Vector3.ZERO
var _push_amount := 0.0
var _released: Array = []           ## [{body, t}] collision exceptions to restore


func _ready() -> void:
	InputSetup.ensure_actions()
	if config == null:
		config = MovementConfig.new()
	collision_layer = InputSetup.LAYER_PROXY
	collision_mask = InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS | InputSetup.LAYER_PROXY_ONLY | InputSetup.LAYER_PROXY
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.35
	floor_constant_speed = true
	facing_yaw = rotation.y
	rotation = Vector3.ZERO
	_spawn = Transform3D(Basis(Vector3.UP, facing_yaw), global_position)

	_shape = CapsuleShape3D.new()
	_col = CollisionShape3D.new()
	_col.shape = _shape
	add_child(_col)
	_set_capsule(false)

	rig = RagdollRig.new()
	rig.name = "Puppet"
	rig.top_level = true
	rig.limb_hit_threshold = config.limb_hit_threshold
	add_child(rig)
	rig.build(root_transform(), body_color)
	skin = HumanoidSkin.new()
	skin.name = "Skin"
	skin.skin_color = skin_color
	rig.add_child(skin)
	skin.setup(rig)
	rig.set_bodies_visible(false)
	combat = CombatComponent.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(self)
	add_to_group("characters")


func _unhandled_input(event: InputEvent) -> void:
	if use_external_input:
		return
	if event.is_action_pressed("toggle_ragdoll"):
		if state == State.RAGDOLL:
			_start_get_up()
		else:
			enter_ragdoll()
	elif event.is_action_pressed("reset_player"):
		reset()
	elif event.is_action_pressed("toggle_debug_bodies"):
		skin.visible = not skin.visible
		rig.set_bodies_visible(not skin.visible)


func root_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, facing_yaw), global_position)


func facing_dir() -> Vector3:
	return Vector3(-sin(facing_yaw), 0.0, -cos(facing_yaw))


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func camera_target() -> Vector3:
	if state == State.RAGDOLL:
		return rig.pelvis().global_position + Vector3.UP * 0.4
	return global_position + Vector3.UP * (1.5 if not _crouched_shape else 1.1)


func is_crouched_shape() -> bool:
	return _crouched_shape


func capsule_height() -> float:
	return _shape.height


# ---------------------------------------------------------------- main loop

func _physics_process(dt: float) -> void:
	_in = _read_input()
	state_time += dt
	match state:
		State.RAGDOLL:
			_update_ragdoll(dt)
		State.GET_UP:
			_update_get_up(dt)
		State.LEDGE_HANG:
			_update_hang(dt)
		State.CLIMB:
			_update_climb(dt)
		State.GRAB:
			_update_grab(dt)
		_:
			_update_locomotion(dt)
	_update_objects(dt)
	combat.physics_update(dt, _in)
	_update_puppet(dt)


func _read_input() -> Dictionary:
	if use_external_input:
		var d := {"move": Vector2.ZERO, "jump": false, "crouch": false, "run": false, "roll": false,
			"interact": false, "throw": false, "punch": false, "kick": false, "guard": false}
		d.merge(external_input, true)
		d["jump_pressed"] = d.get("jump", false) and not _prev_ext.get("jump", false)
		d["roll_pressed"] = d.get("roll", false) and not _prev_ext.get("roll", false)
		d["crouch_pressed"] = d.get("crouch", false) and not _prev_ext.get("crouch", false)
		d["interact_pressed"] = d.get("interact", false) and not _prev_ext.get("interact", false)
		d["throw_pressed"] = d.get("throw", false) and not _prev_ext.get("throw", false)
		d["punch_pressed"] = d.get("punch", false) and not _prev_ext.get("punch", false)
		d["kick_pressed"] = d.get("kick", false) and not _prev_ext.get("kick", false)
		_prev_ext = external_input.duplicate()
		return d
	return {
		"move": Input.get_vector("move_left", "move_right", "move_forward", "move_back"),
		"jump": Input.is_action_pressed("jump"),
		"jump_pressed": Input.is_action_just_pressed("jump"),
		"crouch": Input.is_action_pressed("crouch"),
		"crouch_pressed": Input.is_action_just_pressed("crouch"),
		"run": Input.is_action_pressed("run"),
		"roll": Input.is_action_pressed("roll"),
		"roll_pressed": Input.is_action_just_pressed("roll"),
		"interact_pressed": Input.is_action_just_pressed("interact"),
		"throw_pressed": Input.is_action_just_pressed("throw"),
		"punch_pressed": Input.is_action_just_pressed("punch"),
		"kick_pressed": Input.is_action_just_pressed("kick"),
		"guard": Input.is_action_pressed("guard"),
	}


func _wish_dir() -> Vector3:
	var mv: Vector2 = _in.get("move", Vector2.ZERO)
	if mv.length() > 1.0:
		mv = mv.normalized()
	return Basis(Vector3.UP, camera_yaw) * Vector3(mv.x, 0.0, mv.y)


# ---------------------------------------------------------------- locomotion

func _update_locomotion(dt: float) -> void:
	var cfg := config
	var wish := _wish_dir()
	var on_floor := is_on_floor()
	_coyote = cfg.coyote_time if on_floor else _coyote - dt
	_jump_buffer = cfg.jump_buffer if _in.jump_pressed else _jump_buffer - dt
	_roll_buffer = 0.0 if _in.roll_pressed else _roll_buffer + dt
	_roll_cooldown -= dt
	_grab_cooldown -= dt
	_land_squash = move_toward(_land_squash, 0.0, dt * 4.0)
	var hs := horizontal_speed()

	# --- transitions
	match state:
		State.ROLL:
			if state_time >= cfg.roll_duration:
				_roll_cooldown = cfg.roll_cooldown
				_set_state(_ground_state(wish))
			elif not on_floor and _coyote <= 0.0:
				_set_state(State.AIR)
		State.STUMBLE:
			if state_time >= cfg.stumble_duration:
				_set_state(_ground_state(wish))
		State.ATTACK:
			if combat.attack == &"":
				_set_state(_ground_state(wish))
		State.STAGGER:
			if state_time >= cfg.stagger_time and on_floor:
				_set_state(_ground_state(wish))
		State.SLIDE:
			if not on_floor and _coyote <= 0.0:
				_set_state(State.AIR)
			elif hs < cfg.crouch_speed + 0.3 or (not _in.crouch and _can_stand()):
				_set_state(_ground_state(wish))
		State.AIR:
			pass  # landing is resolved after move_and_slide
		_:
			if not on_floor and _coyote <= 0.0:
				_set_state(State.AIR)
			elif _in.roll_pressed and _roll_cooldown <= 0.0 and _carried == null:
				_start_roll()
			elif _in.crouch_pressed and hs >= cfg.slide_min_speed and _carried == null:
				_set_state(State.SLIDE)
				velocity += Vector3(velocity.x, 0, velocity.z).normalized() * cfg.slide_boost
			else:
				var gs := _ground_state(wish)
				if gs != state:
					_set_state(gs)

	if _jump_buffer > 0.0 and _coyote > 0.0 and state in JUMP_STATES:
		# Jump facing a chest-high ledge = mantle instead.
		var ledge := {} if _carried else _find_ledge(_probe_dir(wish), global_position)
		if not ledge.is_empty() and ledge.height >= cfg.mantle_min_height and ledge.height <= cfg.mantle_max_height:
			_start_climb(ledge, false)
			return
		if not _crouched_shape or _can_stand():
			_do_jump()

	# --- horizontal velocity
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	match state:
		State.AIR:
			if wish.length() > 0.05:
				hv = hv.move_toward(wish * maxf(cfg.walk_speed, _takeoff_speed), cfg.air_accel * dt)
			hv *= maxf(0.0, 1.0 - cfg.air_drag * dt)
		State.ROLL:
			if wish.length() > 0.1:
				var ang := facing_dir().signed_angle_to(wish, Vector3.UP)
				facing_yaw += clampf(ang, -2.0 * dt, 2.0 * dt)
			hv = facing_dir() * maxf(hv.length() - cfg.roll_friction * dt, 0.0)
		State.SLIDE:
			var sp := maxf(hv.length() - cfg.slide_friction * dt, 0.0)
			var dir := hv.normalized() if hv.length() > 0.01 else facing_dir()
			if wish.length() > 0.1:
				dir = dir.rotated(Vector3.UP, clampf(dir.signed_angle_to(wish, Vector3.UP), -1.0 * dt, 1.0 * dt))
			hv = dir * sp
		State.STUMBLE:
			hv = hv.move_toward(Vector3.ZERO, cfg.ground_friction * 1.5 * dt)
		State.ATTACK:
			var lunging := combat.attack_phase() in [&"windup", &"active"]
			var d: Dictionary = CombatComponent.ATTACKS.get(combat.attack, {})
			var want: Vector3 = facing_dir() * float(d.get("lunge", 0.0)) if lunging else Vector3.ZERO
			# Momentum carries into the attack: slowing down from a run takes a moment.
			var rate := 6.0 if hv.length() > want.length() + 0.5 else 14.0
			hv = hv.move_toward(want, rate * dt)
		State.STAGGER:
			hv = hv.move_toward(Vector3.ZERO, cfg.stagger_friction * dt)
		_:
			hv = _ground_velocity(hv, wish, dt)

	# --- vertical velocity
	var vy := velocity.y
	if on_floor and state != State.AIR:
		vy = minf(vy, 0.0)
	else:
		var g := cfg.gravity
		if vy < 0.0:
			g *= cfg.fall_gravity_mult
		elif not _in.jump:
			g *= cfg.low_jump_gravity_mult
		vy = maxf(vy - g * dt, -cfg.terminal_speed)

	velocity = Vector3(hv.x, vy, hv.z)
	var pre_vy := vy
	var was_air := state == State.AIR
	move_and_slide()
	_push_props()

	if was_air and is_on_floor() and state == State.AIR:
		_on_land(-pre_vy)
	elif state == State.AIR and _carried == null:
		_try_air_ledge(wish)

	_update_facing(dt)
	var hv_now := Vector3(velocity.x, 0, velocity.z)
	var accel := (hv_now - _last_hv) / dt
	_last_hv = hv_now
	var right := Basis(Vector3.UP, facing_yaw) * Vector3.RIGHT
	_lean = _lean.lerp(Vector2(accel.dot(right), accel.dot(facing_dir())), 1.0 - exp(-10.0 * dt))
	rig.muscle = move_toward(rig.muscle, 1.0, dt * 2.0)


func _ground_velocity(hv: Vector3, wish: Vector3, dt: float) -> Vector3:
	var cfg := config
	var speed := hv.length()
	var target_speed := cfg.walk_speed
	if state == State.RUN:
		target_speed = cfg.run_speed
	elif state == State.CROUCH:
		target_speed = cfg.crouch_speed
	if wish.length() <= 0.05:
		_skidding = false
		speed = maxf(speed - cfg.ground_friction * dt, 0.0)
		return hv.normalized() * speed if speed > 0.0 else Vector3.ZERO
	var amt := minf(wish.length(), 1.0)
	var wdir := wish.normalized()
	var dir := hv / speed if speed > 0.05 else wdir
	var ang := dir.signed_angle_to(wdir, Vector3.UP)
	if speed > cfg.skid_min_speed and absf(ang) > deg_to_rad(cfg.skid_angle_deg):
		_skidding = true
	elif _skidding and (speed < 1.0 or absf(ang) < PI * 0.5):
		_skidding = false
	if _skidding:
		speed = maxf(speed - cfg.skid_decel * dt, 0.0)
		return dir * speed
	var k := clampf(speed / cfg.run_speed, 0.0, 1.0)
	var tr := lerpf(cfg.turn_rate_slow, cfg.turn_rate_fast, k)
	dir = dir.rotated(Vector3.UP, clampf(ang, -tr * dt, tr * dt))
	var tgt := target_speed * amt * carry_speed_factor() * (config.guard_speed_factor if combat.guarding else 1.0)
	if speed < tgt:
		var a := cfg.walk_accel if speed < cfg.walk_speed else cfg.run_accel
		speed = minf(speed + a * dt, tgt)
	else:
		speed = maxf(speed - cfg.ground_decel * dt, tgt)
	return dir * speed


func _ground_state(wish: Vector3) -> State:
	if _in.get("crouch", false) or (_crouched_shape and not _can_stand()):
		return State.CROUCH
	var moving := wish.length() > 0.05 or horizontal_speed() > 0.3
	if not moving:
		return State.IDLE
	if _in.get("run", false) and wish.length() > 0.05:
		return State.RUN
	return State.WALK


func _update_facing(dt: float) -> void:
	if state in [State.ROLL, State.STAGGER] or _skidding:
		return
	var hv := Vector3(velocity.x, 0, velocity.z)
	if face_target and is_instance_valid(face_target) and (combat.guarding or state == State.ATTACK or hv.length() < 2.5):
		var to := face_target.global_position - global_position
		if Vector2(to.x, to.z).length() > 0.05:
			facing_yaw = rotate_toward(facing_yaw, atan2(-to.x, -to.z), 8.0 * dt)
		return
	if state == State.ATTACK:
		return
	if hv.length() < 0.3:
		return
	var target := atan2(-hv.x, -hv.z)
	var rate := 3.0 if state == State.AIR else 12.0
	facing_yaw = rotate_toward(facing_yaw, target, rate * dt)


func _do_jump() -> void:
	velocity.y = sqrt(2.0 * config.gravity * config.jump_height)
	_takeoff_speed = horizontal_speed()
	_jump_buffer = 0.0
	_coyote = 0.0
	_set_state(State.AIR)


func _start_roll() -> void:
	_roll_buffer = 99.0
	var hv := Vector3(velocity.x, 0, velocity.z)
	var wish := _wish_dir()
	if wish.length() > 0.1:
		facing_yaw = atan2(-wish.x, -wish.z)
	elif hv.length() > 0.5:
		facing_yaw = atan2(-hv.x, -hv.z)
	var sp := maxf(hv.dot(facing_dir()), 0.0)
	velocity = facing_dir() * maxf(sp, config.roll_speed) + Vector3.UP * minf(velocity.y, 0.0)
	_set_state(State.ROLL)


func _on_land(impact: float) -> void:
	var cfg := config
	last_impact = impact
	if _roll_buffer <= cfg.roll_land_window and impact < cfg.roll_safe_land_speed:
		_start_roll()
		return
	if impact >= cfg.ragdoll_land_speed:
		enter_ragdoll()
		return
	var wish := _wish_dir()
	if impact >= cfg.stumble_land_speed:
		_set_state(State.STUMBLE)
		rig.muscle = 0.35
		_land_squash = 1.0
	else:
		_land_squash = clampf(impact / cfg.stumble_land_speed, 0.0, 1.0)
		_set_state(_ground_state(wish))


func _push_props() -> void:
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var body := c.get_collider() as RigidBody3D
		if body:
			var push := -c.get_normal()
			push.y = 0.0
			body.apply_impulse(push * minf(horizontal_speed(), 4.0) * 0.15, c.get_position() - body.global_position)


# ---------------------------------------------------------------- crouch capsule

func _set_capsule(crouched: bool) -> void:
	_crouched_shape = crouched
	var h := config.crouch_height if crouched else config.stand_height
	_shape.radius = config.capsule_radius
	_shape.height = h
	_col.position = Vector3(0, h * 0.5, 0)


func _can_stand() -> bool:
	if not _crouched_shape:
		return true
	return not test_move(global_transform, Vector3.UP * (config.stand_height - config.crouch_height))


func _set_state(s: State) -> void:
	if s == state:
		return
	var want_crouch := s in CROUCH_STATES
	if want_crouch and not _crouched_shape:
		_set_capsule(true)
	elif not want_crouch and _crouched_shape and not s in [State.AIR, State.RAGDOLL, State.LEDGE_HANG]:
		if _can_stand():
			_set_capsule(false)
		elif s != State.GET_UP:
			s = State.CROUCH
	if s == state:
		return
	var old := state
	state = s
	state_time = 0.0
	state_changed.emit(old, s)


# ---------------------------------------------------------------- ledges

func _probe_dir(wish: Vector3) -> Vector3:
	return wish.normalized() if wish.length() > 0.3 else facing_dir()


## Looks for a grabbable ledge in `dir` from a capsule standing at `base` (feet).
## Returns {} or {y, height, normal (out of the wall), edge (top of the wall face), stand, can_stand}.
func _find_ledge(dir: Vector3, base: Vector3) -> Dictionary:
	var cfg := config
	var space := get_world_3d().direct_space_state
	var mask := InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS
	var wall := {}
	for h: float in [0.4, 1.0, 1.6]:
		var from := base + Vector3.UP * h
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * cfg.ledge_reach, mask)
		var hit := space.intersect_ray(q)
		if hit and absf((hit.normal as Vector3).y) < 0.3:
			wall = hit
			break
	if wall.is_empty():
		return {}
	var n := Vector3(wall.normal.x, 0.0, wall.normal.z).normalized()
	var wp: Vector3 = wall.position
	var top_from := Vector3(wp.x, base.y + cfg.grab_max_height + 0.3, wp.z) - n * 0.25
	var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(top_from,
		Vector3(top_from.x, base.y + 0.3, top_from.z), mask))
	if down.is_empty() or (down.normal as Vector3).y < 0.7:
		return {}
	var y: float = down.position.y
	var stand := Vector3(wp.x, y, wp.z) - n * (cfg.capsule_radius + 0.15)
	if _capsule_blocked(stand, cfg.crouch_height):
		return {}
	return {
		"y": y,
		"height": y - base.y,
		"normal": n,
		"edge": Vector3(wp.x, y, wp.z),
		"stand": stand,
		"can_stand": not _capsule_blocked(stand, cfg.stand_height),
	}


func _capsule_blocked(feet: Vector3, height: float) -> bool:
	var sh := CapsuleShape3D.new()
	sh.radius = config.capsule_radius
	sh.height = height
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sh
	params.transform = Transform3D(Basis(), feet + Vector3.UP * (height * 0.5 + 0.03))
	params.collision_mask = InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS
	return not get_world_3d().direct_space_state.intersect_shape(params, 1).is_empty()


func _try_air_ledge(wish: Vector3) -> void:
	var cfg := config
	if _grab_cooldown > 0.0 or _in.get("crouch", false) or velocity.y < cfg.grab_min_vy:
		return
	var hv := Vector3(velocity.x, 0, velocity.z)
	var dir := _probe_dir(wish) if wish.length() > 0.3 else (hv.normalized() if hv.length() > 0.5 else facing_dir())
	var ledge := _find_ledge(dir, global_position)
	if ledge.is_empty():
		return
	# Only grab what we are actually heading for.
	var into := -(ledge.normal as Vector3)
	if wish.dot(into) < 0.3 and hv.dot(into) < 1.0:
		return
	var h: float = ledge.height
	if h >= 0.3 and h <= cfg.air_mantle_max_height:
		_start_climb(ledge, false)
	elif h > cfg.air_mantle_max_height and h <= cfg.grab_max_height and velocity.y < 1.5:
		_start_hang(ledge)


func _hang_position(ledge: Dictionary) -> Vector3:
	var e: Vector3 = ledge.edge
	return Vector3(e.x, ledge.y - config.hang_hand_height, e.z) + (ledge.normal as Vector3) * config.hang_wall_gap


func _face_wall(n: Vector3) -> void:
	facing_yaw = atan2(n.x, n.z)  # facing_dir() == -n


func _start_hang(ledge: Dictionary) -> void:
	_ledge = ledge
	_face_wall(ledge.normal)
	_col.disabled = true
	velocity = Vector3.ZERO
	global_position = _hang_position(ledge)
	_shimmy = 0.0
	_set_state(State.LEDGE_HANG)


func _update_hang(dt: float) -> void:
	var cfg := config
	var wish := _wish_dir()
	var n: Vector3 = _ledge.normal
	var fwd := -n
	var right := fwd.cross(Vector3.UP)
	var toward := wish.dot(fwd)
	var side := wish.dot(right)
	_shimmy = 0.0
	velocity = Vector3.ZERO
	rig.muscle = move_toward(rig.muscle, 1.0, dt * 2.0)
	if _in.jump_pressed or (toward > 0.6 and state_time > 0.3):
		_start_climb(_ledge, true)
	elif _in.crouch_pressed or toward < -0.6:
		_col.disabled = false
		_grab_cooldown = cfg.regrab_cooldown
		velocity = n * 1.5
		_set_state(State.AIR)
	elif absf(side) > 0.3:
		var step := right * signf(side) * cfg.shimmy_speed * dt
		# Probe from a little further along so we stop before the ledge ends.
		var probe := _find_ledge(fwd, global_position + step + right * signf(side) * 0.25)
		if not probe.is_empty() and absf(probe.y - _ledge.y) < 0.25 and probe.normal.dot(n) > 0.9:
			var ahead := _find_ledge(fwd, global_position + step)
			if not ahead.is_empty():
				_ledge = ahead
				global_position = _hang_position(ahead)
				velocity = step / dt
				_shimmy = signf(side)


func _start_climb(ledge: Dictionary, from_hang: bool) -> void:
	var cfg := config
	_ledge = ledge
	_climb_from = global_position
	_climb_to = ledge.stand
	_climb_from_hang = from_hang
	var into := -(ledge.normal as Vector3)
	_climb_exit_speed = 0.0 if from_hang else clampf(Vector3(velocity.x, 0, velocity.z).dot(into) * 0.7, 0.0, cfg.run_speed)
	if from_hang:
		_climb_time = cfg.climb_up_time
	else:
		var k := inverse_lerp(cfg.mantle_min_height, cfg.mantle_max_height, ledge.height)
		_climb_time = lerpf(cfg.mantle_time_low, cfg.mantle_time_high, clampf(k, 0.0, 1.0))
	_face_wall(ledge.normal)
	_col.disabled = true
	_set_state(State.CLIMB)


func _update_climb(dt: float) -> void:
	var t := clampf(state_time / _climb_time, 0.0, 1.0)
	# Up first, then over the edge.
	var up := smoothstep(0.0, 0.6, t)
	var over := smoothstep(0.55, 1.0, t)
	var p := Vector3(lerpf(_climb_from.x, _climb_to.x, over),
		lerpf(_climb_from.y, _climb_to.y + 0.02, up),
		lerpf(_climb_from.z, _climb_to.z, over))
	velocity = (p - global_position) / dt
	global_position = p
	rig.muscle = move_toward(rig.muscle, 1.0, dt * 2.0)
	if t >= 1.0:
		_col.disabled = false
		velocity = -(_ledge.normal as Vector3) * _climb_exit_speed
		_coyote = config.coyote_time
		_set_state(_ground_state(_wish_dir()))


# ---------------------------------------------------------------- objects

func carry_speed_factor() -> float:
	if _carried == null:
		return 1.0
	return 1.0 - config.carry_speed_penalty * clampf(_carried.mass / config.lift_max_mass, 0.0, 1.0)


func is_carrying() -> RigidBody3D:
	return _carried


func is_grabbing() -> RigidBody3D:
	return _grabbed


## Closest movable prop in reach in front of the chest, or null.
func find_interactable() -> RigidBody3D:
	var sh := SphereShape3D.new()
	sh.radius = 0.55
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sh
	params.transform = Transform3D(Basis(), global_position + Vector3.UP * 0.8 + facing_dir() * config.interact_range * 0.6)
	params.collision_mask = InputSetup.LAYER_PROPS
	var best: RigidBody3D = null
	var best_d := INF
	for r in get_world_3d().direct_space_state.intersect_shape(params, 8):
		var body := r.collider as RigidBody3D
		if body == null or body.freeze:
			continue
		var d := body.global_position.distance_to(global_position + Vector3.UP * 0.8)
		if d < best_d:
			best_d = d
			best = body
	return best


## What pressing interact would do right now (for the HUD).
func interact_hint() -> String:
	if _carried:
		return "E: drop   F: throw"
	if _grabbed:
		return "W/S: push / pull   E: let go"
	if not state in [State.IDLE, State.WALK, State.RUN, State.CROUCH]:
		return ""
	var b := find_interactable()
	if b == null:
		return ""
	if b.mass <= config.lift_max_mass:
		return "E: lift (%.0f kg)" % b.mass
	if b.mass <= config.push_max_mass:
		return "E: grab to push / pull (%.0f kg)" % b.mass
	return "Too heavy (%.0f kg)" % b.mass


static func object_extents(body: RigidBody3D) -> Vector3:
	for c in body.get_children():
		if c is CollisionShape3D:
			var sh: Shape3D = (c as CollisionShape3D).shape
			if sh is BoxShape3D:
				return (sh as BoxShape3D).size * 0.5
			if sh is SphereShape3D:
				return Vector3.ONE * (sh as SphereShape3D).radius
			if sh is CylinderShape3D:
				var cy := sh as CylinderShape3D
				return Vector3(cy.radius, cy.height * 0.5, cy.radius)
	return Vector3.ONE * 0.25


func _update_objects(dt: float) -> void:
	for i in range(_released.size() - 1, -1, -1):
		var r: Dictionary = _released[i]
		r.t -= dt
		if r.t <= 0.0 or not is_instance_valid(r.body):
			if is_instance_valid(r.body):
				_set_exceptions(r.body, false)
			_released.remove_at(i)
	if state == State.RAGDOLL:
		return
	if _carried and not is_instance_valid(_carried):
		_carried = null
	if _carried:
		if _in.get("throw_pressed", false):
			throw_carried()
		elif _in.get("interact_pressed", false):
			_in["interact_pressed"] = false
			release_objects()
		else:
			_hold_carried(dt)
		return
	if _in.get("interact_pressed", false) and state in [State.IDLE, State.WALK, State.RUN, State.CROUCH]:
		var b := find_interactable()
		if b and b.mass <= config.lift_max_mass:
			_start_carry(b)
		elif b and b.mass <= config.push_max_mass:
			_start_grab(b)


func _set_exceptions(body: RigidBody3D, on: bool) -> void:
	for pb: PuppetBone in rig.bones.values():
		if on:
			body.add_collision_exception_with(pb)
		else:
			body.remove_collision_exception_with(pb)
	if on:
		body.add_collision_exception_with(self)
	else:
		body.remove_collision_exception_with(self)


func _start_carry(body: RigidBody3D) -> void:
	_carried = body
	_set_exceptions(body, true)
	for i in range(_released.size() - 1, -1, -1):
		if _released[i].body == body:
			_released.remove_at(i)


func _hold_target() -> Vector3:
	var ext := object_extents(_carried)
	return global_position + Vector3.UP * config.carry_height + facing_dir() * (config.capsule_radius + 0.12 + ext.z)


func _hold_carried(dt: float) -> void:
	var b := _carried
	var to := _hold_target() - b.global_position
	if to.length() > 1.2:
		release_objects()  # snagged on something
		return
	var want_v := velocity + to * 14.0
	var f := (want_v - b.linear_velocity) * b.mass / dt * 0.5
	f += Vector3.UP * b.mass * float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	b.apply_central_force(f.limit_length(config.lift_strength))
	# Keep it upright and turned with the character.
	var want := Basis(Vector3.UP, facing_yaw).get_rotation_quaternion()
	var q := (want * b.global_basis.get_rotation_quaternion().inverse()).normalized()
	if q.w < 0.0:
		q = -q
	var v := Vector3(q.x, q.y, q.z)
	b.angular_velocity = b.angular_velocity.lerp(v * 2.0 * 8.0, 0.3)


func throw_carried() -> void:
	var b := _carried
	if b == null:
		return
	release_objects()
	var k := clampf(sqrt(config.throw_ref_mass / maxf(b.mass, 0.1)), 0.35, 1.0)
	b.linear_velocity = velocity + (facing_dir() * config.throw_speed + Vector3.UP * 3.0) * k


## Drops / lets go of anything held. Collisions with the body come back shortly after.
func release_objects() -> void:
	if _carried and is_instance_valid(_carried):
		_released.append({"body": _carried, "t": 0.4})
	_carried = null
	rig.hit_ignore = null
	if _grabbed:
		_grabbed = null
		if state == State.GRAB:
			_set_state(_ground_state(_wish_dir()))


func _start_grab(body: RigidBody3D) -> void:
	var ext := object_extents(body)
	var top := body.global_position.y + ext.y
	var h := clampf(top - global_position.y - 0.15, 0.4, 1.15)
	var from := global_position + Vector3.UP * h
	var to := Vector3(body.global_position.x, from.y, body.global_position.z)
	to += (to - from).normalized() * 0.5
	var q := PhysicsRayQueryParameters3D.create(from, to, InputSetup.LAYER_PROPS)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or hit.collider != body:
		return
	var n := Vector3(hit.normal.x, 0.0, hit.normal.z)
	if n.length() < 0.5:
		return
	n = n.normalized()
	_grabbed = body
	rig.hit_ignore = body
	_grab_local = body.to_local(hit.position)
	_grab_normal_local = body.global_basis.inverse() * n
	_face_wall(n)
	_push_amount = 0.0
	_set_state(State.GRAB)


func _update_grab(dt: float) -> void:
	var cfg := config
	var b := _grabbed
	if b == null or not is_instance_valid(b) or _in.interact_pressed or _in.jump_pressed or _in.crouch_pressed:
		_in["interact_pressed"] = false  # consumed: don't re-grab this tick
		release_objects()
		return
	var gp := b.to_global(_grab_local)
	var n := b.global_basis * _grab_normal_local
	n.y = 0.0
	if n.length() < 0.3 or absf(gp.y - global_position.y - 0.8) > 0.9:
		release_objects()  # tipped over / fell away
		return
	n = n.normalized()
	facing_yaw = rotate_toward(facing_yaw, atan2(n.x, n.z), 6.0 * dt)
	var axis := -n
	var amount := clampf(_wish_dir().dot(axis), -1.0, 1.0)
	if absf(amount) < 0.2:
		amount = 0.0
	# Can't pull into a wall.
	if amount < 0.0 and test_move(global_transform, axis * amount * 0.1):
		amount = 0.0
	_push_amount = lerpf(_push_amount, amount, 1.0 - exp(-8.0 * dt))
	var spd := lerpf(cfg.push_speed_light, cfg.push_speed_heavy, clampf(b.mass / cfg.push_max_mass, 0.0, 1.0))
	var bv := b.linear_velocity
	var f := (axis * amount * spd - Vector3(bv.x, 0.0, bv.z)) * b.mass / dt * 0.5
	f.y = 0.0
	# Applied low on the object so friction doesn't tip it over.
	b.apply_force(f.limit_length(cfg.push_strength), b.global_basis * Vector3(0, -object_extents(b).y * 0.6, 0))

	var desired := gp + n * cfg.grab_gap
	var flat := Vector3(desired.x - global_position.x, 0.0, desired.z - global_position.z)
	var vy := 0.0 if is_on_floor() else velocity.y - cfg.gravity * dt
	velocity = (flat / dt).limit_length(5.0) + Vector3.UP * vy
	move_and_slide()
	var err := Vector3(desired.x - global_position.x, 0.0, desired.z - global_position.z).length()
	if err > cfg.grab_break_distance:
		release_objects()
	rig.muscle = move_toward(rig.muscle, 1.0, dt * 2.0)


## Palm targets for the puppet's hand IK, or {} when the hands are free.
func _hand_targets() -> Dictionary:
	var right := facing_dir().cross(Vector3.UP)
	if _carried and is_instance_valid(_carried):
		var ext := object_extents(_carried)
		var c := _carried.global_position
		return {&"l": c - right * (ext.x + 0.03), &"r": c + right * (ext.x + 0.03)}
	if _grabbed and is_instance_valid(_grabbed) and state == State.GRAB:
		var gp := _grabbed.to_global(_grab_local)
		var n := (_grabbed.global_basis * _grab_normal_local).normalized()
		var p := gp + n * 0.02
		return {&"l": p - right * 0.2, &"r": p + right * 0.2}
	return {}


# ---------------------------------------------------------------- combat

func can_attack() -> bool:
	return state in [State.IDLE, State.WALK, State.RUN, State.CROUCH] and _carried == null and _grabbed == null


## Called by CombatComponent when an attack starts.
func begin_attack() -> void:
	_set_state(State.ATTACK)


## Knocked back on our feet: input is ignored until the stagger ends.
func start_stagger(v: Vector3) -> void:
	release_objects()
	velocity = Vector3(v.x, minf(velocity.y, 0.0), v.z)
	rig.muscle = 0.5
	_skidding = false
	_set_state(State.STAGGER)
	state_time = 0.0


## Entry point for melee hits from other characters (see CombatComponent).
func receive_hit(info: Dictionary) -> void:
	last_hit = float(info.strength) * 100.0
	combat.resolve_hit(info)


# ---------------------------------------------------------------- ragdoll

## Hand control to the physical puppet. Optional velocity kick at a point (hazards, combat).
func enter_ragdoll(dv := Vector3.ZERO, point := Vector3.ZERO) -> void:
	if state != State.RAGDOLL:
		release_objects()
		combat.cancel_attack()
		_set_state(State.RAGDOLL)
		_col.disabled = true
		rig.muscle = 0.0
		_settle = 0.0
		_skidding = false
	if dv != Vector3.ZERO:
		rig.add_velocity(dv, point)


## External knock (bumpers, explosions, future combat): always ragdolls.
func apply_hit(dv: Vector3, point: Vector3) -> void:
	last_hit = dv.length() * 60.0
	enter_ragdoll(dv, point)


func _update_ragdoll(dt: float) -> void:
	var p := rig.pelvis()
	global_position = p.global_position - Vector3.UP * 0.95
	velocity = p.linear_velocity
	rig.muscle = 0.0
	if p.linear_velocity.length() < config.ragdoll_settle_speed:
		_settle += dt
	else:
		_settle = 0.0
	if state_time > config.ragdoll_min_time and _settle > config.ragdoll_settle_time:
		_start_get_up()


func _start_get_up() -> void:
	var p := rig.pelvis().global_position
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3, p + Vector3.DOWN * 3.0,
		InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var floor_y: float = hit.position.y if hit else p.y - 0.3
	var head_dir: Vector3 = (rig.bones[&"head"] as Node3D).global_position - p
	head_dir.y = 0.0
	if head_dir.length() > 0.1:
		facing_yaw = atan2(-head_dir.x, -head_dir.z)
	global_position = Vector3(p.x, floor_y + 0.02, p.z)
	velocity = Vector3.ZERO
	_col.disabled = false
	_set_capsule(true)
	_set_state(State.GET_UP)


func _update_get_up(dt: float) -> void:
	var t := state_time / config.get_up_time
	rig.muscle = clampf(t * 1.6, 0.0, 1.0)
	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y = 0.0 if is_on_floor() else velocity.y - config.gravity * dt
	move_and_slide()
	if t >= 1.0:
		rig.muscle = 1.0
		_set_state(_ground_state(_wish_dir()))


# ---------------------------------------------------------------- puppet

func _update_puppet(dt: float) -> void:
	var hs := horizontal_speed()
	var mode := &"ground"
	match state:
		State.CROUCH:
			mode = &"crouch"
		State.SLIDE:
			mode = &"slide"
		State.AIR:
			mode = &"air"
		State.ROLL:
			mode = &"roll"
		State.STUMBLE:
			mode = &"stumble"
		State.RAGDOLL:
			mode = &"ragdoll"
		State.GET_UP:
			mode = &"get_up"
		State.LEDGE_HANG:
			mode = &"hang"
		State.CLIMB:
			mode = &"climb"
		State.GRAB, State.ATTACK:
			mode = &"ground"
		State.STAGGER:
			mode = &"stagger"
	var mv: Vector2 = _in.get("move", Vector2.ZERO)
	var ctx := {
		"mode": mode,
		"speed": hs,
		"run_k": clampf((hs - config.walk_speed) / (config.run_speed - config.walk_speed), 0.0, 1.0),
		"move": minf(mv.length(), 1.0),
		"vy": velocity.y,
		"crouch": 1.0 if state == State.CROUCH else 0.0,
		"roll_t": clampf(state_time / config.roll_duration, 0.0, 1.0),
		"get_up_t": clampf(state_time / config.get_up_time, 0.0, 1.0),
		"lean": _lean,
		"land_squash": _land_squash,
		"skid": _skidding,
		"climb_t": clampf(state_time / _climb_time, 0.0, 1.0),
		"climb_from_hang": _climb_from_hang,
		"shimmy": _shimmy,
		"arm_mode": &"push" if state == State.GRAB else (&"carry" if _carried else &""),
		"push_amount": _push_amount,
	}
	var hands := _hand_targets()
	ctx["hand_targets"] = hands
	ctx.merge(combat.pose_ctx(), true)
	var pose := pose_gen.compute(ctx, dt)
	rig.step(dt, root_transform(), velocity if state != State.RAGDOLL else Vector3.ZERO, pose)

	var hit := rig.consume_hit()
	last_hit = maxf(last_hit * 0.99, hit)
	if hit > config.ragdoll_hit_threshold and state != State.RAGDOLL:
		enter_ragdoll()


# ---------------------------------------------------------------- utility

func reset() -> void:
	teleport(_spawn.origin, atan2(-(_spawn.basis * Vector3.FORWARD).x, -(_spawn.basis * Vector3.FORWARD).z))


func teleport(pos: Vector3, yaw := 0.0) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	facing_yaw = yaw
	_col.disabled = false
	_set_capsule(false)
	_skidding = false
	_land_squash = 0.0
	_last_hv = Vector3.ZERO
	_lean = Vector2.ZERO
	_ledge = {}
	_grab_cooldown = 0.0
	release_objects()
	combat.cancel_attack()
	combat.flinch = {}
	state = State.IDLE
	state_time = 0.0
	rig.muscle = 1.0
	rig.teleport(root_transform())
