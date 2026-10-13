class_name PlayerController
extends CharacterBody3D
## Gameplay "proxy": a capsule that owns movement (momentum, jump, crouch, slide, roll)
## and a state machine. It drives a physical puppet (RagdollRig) that follows it with
## muscles, and hands control over to the puppet while ragdolled.

signal state_changed(old_state: State, new_state: State)

enum State { IDLE, WALK, RUN, CROUCH, SLIDE, AIR, ROLL, STUMBLE, RAGDOLL, GET_UP }

const CROUCH_STATES: Array[State] = [State.CROUCH, State.SLIDE, State.ROLL]
const JUMP_STATES: Array[State] = [State.IDLE, State.WALK, State.RUN, State.CROUCH, State.SLIDE]

@export var config: MovementConfig
@export var body_color := Color(0.22, 0.42, 0.82)

var state: State = State.IDLE
var state_time := 0.0
var facing_yaw := 0.0
var camera_yaw := 0.0

## Tests / AI can drive the character instead of the Input singleton.
var use_external_input := false
var external_input := {"move": Vector2.ZERO, "jump": false, "crouch": false, "run": false, "roll": false}

var rig: RagdollRig
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


func _ready() -> void:
	InputSetup.ensure_actions()
	if config == null:
		config = MovementConfig.new()
	collision_layer = InputSetup.LAYER_PROXY
	collision_mask = InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS
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
		_:
			_update_locomotion(dt)
	_update_puppet(dt)


func _read_input() -> Dictionary:
	if use_external_input:
		var d := external_input.duplicate()
		d["jump_pressed"] = d.get("jump", false) and not _prev_ext.get("jump", false)
		d["roll_pressed"] = d.get("roll", false) and not _prev_ext.get("roll", false)
		d["crouch_pressed"] = d.get("crouch", false) and not _prev_ext.get("crouch", false)
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
			elif _in.roll_pressed and _roll_cooldown <= 0.0:
				_start_roll()
			elif _in.crouch_pressed and hs >= cfg.slide_min_speed:
				_set_state(State.SLIDE)
				velocity += Vector3(velocity.x, 0, velocity.z).normalized() * cfg.slide_boost
			else:
				var gs := _ground_state(wish)
				if gs != state:
					_set_state(gs)

	if _jump_buffer > 0.0 and _coyote > 0.0 and state in JUMP_STATES:
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
	var tgt := target_speed * amt
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
	if state == State.ROLL or _skidding:
		return
	var hv := Vector3(velocity.x, 0, velocity.z)
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
	elif not want_crouch and _crouched_shape and s != State.AIR and s != State.RAGDOLL:
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


# ---------------------------------------------------------------- ragdoll

## Hand control to the physical puppet. Optional velocity kick at a point (hazards, combat).
func enter_ragdoll(dv := Vector3.ZERO, point := Vector3.ZERO) -> void:
	if state != State.RAGDOLL:
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
	}
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
	state = State.IDLE
	state_time = 0.0
	rig.muscle = 1.0
	rig.teleport(root_transform())
