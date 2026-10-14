class_name CombatComponent
extends Node
## Melee for one character: attacks (punch / kick) with windup-active-recovery phases and
## hit queries at the striking limb, guarding, and hit reactions on the receiving end:
## BLOCKED, FLINCH (struck limb recoils, movement continues), STAGGER, KNOCKDOWN (ragdoll).

signal reacted(kind: StringName, strength: float)

const ATTACKS := {
	&"punch": {"windup": 0.12, "active": 0.10, "recovery": 0.22, "limb": &"hand_r",
		"strength": 1.0, "lunge": 1.2, "up": 0.1, "prop_impulse": 12.0},
	&"kick": {"windup": 0.22, "active": 0.12, "recovery": 0.35, "limb": &"foot_r",
		"strength": 2.2, "lunge": 1.5, "up": 0.25, "prop_impulse": 30.0},
}
const HIT_RADIUS := 0.25

var body: PlayerController
var attack: StringName = &""     ## current attack, &"" when none
var attack_time := 0.0
var guarding := false
var guard_broken := 0.0          ## guard unavailable while > 0
var last_reaction: StringName = &""
var last_strength := 0.0
var flinch := {}                 ## {region, side, t} for the pose overlay
var _hit_targets: Array = []
var _chain := 0
var _chain_t := 99.0
var _exclude: Array[RID] = []
var _entry_speed := 0.0          ## run-up speed along facing when the attack started


func setup(owner_body: PlayerController) -> void:
	body = owner_body
	for b: PuppetBone in body.rig.bones.values():
		_exclude.append(b.get_rid())


static func attack_total(kind: StringName) -> float:
	var d: Dictionary = ATTACKS[kind]
	return d.windup + d.active + d.recovery


func attack_phase() -> StringName:
	if attack == &"":
		return &""
	var d: Dictionary = ATTACKS[attack]
	if attack_time < d.windup:
		return &"windup"
	if attack_time < d.windup + d.active:
		return &"active"
	return &"recovery"


func is_winding_up() -> bool:
	return attack_phase() == &"windup"


func cancel_attack() -> void:
	attack = &""
	attack_time = 0.0


## Called by the controller every physics tick after its state update.
func physics_update(dt: float, input: Dictionary) -> void:
	guard_broken -= dt
	_chain_t += dt
	if not flinch.is_empty():
		flinch.t += dt
		if flinch.t > 0.4:
			flinch = {}

	guarding = input.get("guard", false) and guard_broken <= 0.0 and attack == &"" \
		and body.state in [PlayerController.State.IDLE, PlayerController.State.WALK,
			PlayerController.State.RUN, PlayerController.State.CROUCH] \
		and body.is_carrying() == null and body.is_grabbing() == null

	if attack == &"" and body.can_attack():
		if input.get("punch_pressed", false):
			_start(&"punch")
		elif input.get("kick_pressed", false):
			_start(&"kick")
	if attack == &"":
		return
	if body.state != PlayerController.State.ATTACK:
		cancel_attack()  # interrupted (stagger, knockdown, fell off something ...)
		return
	attack_time += dt
	if attack_phase() == &"active":
		_query_hits()
	if attack_time >= attack_total(attack):
		cancel_attack()


func _start(kind: StringName) -> void:
	attack = kind
	attack_time = 0.0
	_hit_targets.clear()
	# Soft lock-on: turn toward the nearest other character in front.
	var best: PlayerController = null
	var best_d := body.config.lock_on_range
	for n in body.get_tree().get_nodes_in_group("characters"):
		var other := n as PlayerController
		if other == null or other == body or other.state == PlayerController.State.RAGDOLL:
			continue
		var to := other.global_position - body.global_position
		to.y = 0.0
		var d := to.length()
		if d < best_d and d > 0.01 and body.facing_dir().angle_to(to) < deg_to_rad(75.0):
			best_d = d
			best = other
	if best:
		var to := best.global_position - body.global_position
		body.facing_yaw = atan2(-to.x, -to.z)
	_entry_speed = maxf(Vector3(body.velocity.x, 0, body.velocity.z).dot(body.facing_dir()), 0.0)
	body.begin_attack()


func _query_hits() -> void:
	var d: Dictionary = ATTACKS[attack]
	var limb: PuppetBone = body.rig.bones[d.limb]
	# The striking limb and the segment behind it (forearm / shin), so a target that is
	# too close for the fist or foot still gets hit by the forearm or knee.
	var results := _sphere_hits(limb.global_position)
	results.append_array(_sphere_hits((body.rig.bones[limb.def.parent] as PuppetBone).global_position))
	for r in results:
		var col: Object = r.collider
		if col is PuppetBone:
			var target := (col as PuppetBone).rig.get_parent() as PlayerController
			if target == null or target == body or target in _hit_targets:
				continue
			_hit_targets.append(target)
			var dir := target.global_position - body.global_position
			dir.y = 0.0
			dir = dir.normalized() if dir.length() > 0.01 else body.facing_dir()
			# A run-up counts even if bodies have already bumped and slowed us down.
			var closing := maxf(maxf(body.velocity.dot(dir), 0.0), _entry_speed * 0.85)
			target.receive_hit({
				"dir": dir, "strength": d.strength * (1.0 + 0.15 * closing),
				"point": limb.global_position, "bone": (col as PuppetBone).def.name,
				"attacker": body, "kind": attack, "up": d.up,
			})
		elif col is RigidBody3D and not col in _hit_targets:
			_hit_targets.append(col)
			var rb := col as RigidBody3D
			var dir := (rb.global_position - body.global_position).normalized()
			rb.apply_impulse((dir + Vector3.UP * d.up) * d.prop_impulse, limb.global_position - rb.global_position)


func _sphere_hits(at: Vector3) -> Array:
	var sh := SphereShape3D.new()
	sh.radius = HIT_RADIUS
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sh
	params.transform = Transform3D(Basis(), at)
	params.collision_mask = InputSetup.LAYER_PUPPET | InputSetup.LAYER_PROPS
	params.exclude = _exclude
	return body.get_world_3d().direct_space_state.intersect_shape(params, 16)


## Resolves an incoming hit into a reaction tier.
func resolve_hit(info: Dictionary) -> void:
	var cfg := body.config
	var dir: Vector3 = info.dir
	var s: float = info.strength
	var point: Vector3 = info.point
	var bone: StringName = info.bone
	_chain = _chain + 1 if _chain_t < cfg.combo_window else 1
	_chain_t = 0.0

	if body.state == PlayerController.State.RAGDOLL:
		body.rig.add_velocity(dir * 1.5 * s, point)
		_react(&"ragdoll_hit", s)
		return

	var from_front := body.facing_dir().dot(-dir) > 0.2
	if guarding and from_front:
		if s < cfg.guard_break_strength:
			body.velocity += dir * cfg.block_pushback
			_set_flinch(&"guard", 0.0)
			_react(&"blocked", s)
			return
		guard_broken = cfg.guard_break_time
		guarding = false
		_stagger(dir, s)
		_react(&"guard_break", s)
		return

	var vulnerable := body.state in [PlayerController.State.STAGGER, PlayerController.State.AIR,
		PlayerController.State.LEDGE_HANG, PlayerController.State.CLIMB, PlayerController.State.GET_UP]
	if s >= cfg.knockdown_strength or (vulnerable and s >= cfg.stagger_strength):
		cancel_attack()
		var up: float = info.get("up", 0.2)
		var dv := (dir + Vector3.UP * (0.25 + up)).normalized() * cfg.knockdown_speed * clampf(s / cfg.knockdown_strength, 1.0, 1.8)
		body.enter_ragdoll(dv, point)
		_react(&"knockdown", s)
	elif s >= cfg.stagger_strength or _chain >= 3:
		_stagger(dir, s)
		_react(&"stagger", s)
	else:
		# Flinch: the struck part goes limp for a moment and is knocked along the hit.
		var b: PuppetBone = body.rig.bones[bone]
		body.rig.weaken(bone, 0.15)
		if b.def.parent != &"":
			body.rig.weaken(b.def.parent, 0.4)
			(body.rig.bones[b.def.parent] as PuppetBone).linear_velocity += dir * cfg.flinch_speed * s * 0.4
		b.linear_velocity += dir * cfg.flinch_speed * s + Vector3.UP * 0.5
		var right := body.facing_dir().cross(Vector3.UP)
		_set_flinch(_region(bone), signf(dir.dot(right)))
		_react(&"flinch", s)


func _stagger(dir: Vector3, s: float) -> void:
	cancel_attack()
	body.start_stagger(dir * body.config.stagger_speed * clampf(s / 2.0, 0.8, 1.6))


func _set_flinch(region: StringName, side: float) -> void:
	flinch = {"region": region, "side": side, "t": 0.0}


static func _region(bone: StringName) -> StringName:
	var n := String(bone)
	if n == "head":
		return &"head"
	if n.begins_with("upper_arm") or n.begins_with("forearm") or n.begins_with("hand"):
		return &"arm_l" if n.ends_with("_l") else &"arm_r"
	if n.begins_with("thigh") or n.begins_with("shin") or n.begins_with("foot"):
		return &"leg"
	return &"torso"


func _react(kind: StringName, s: float) -> void:
	last_reaction = kind
	last_strength = s
	reacted.emit(kind, s)


## Pose-generator context for the attack / guard / flinch overlays.
func pose_ctx() -> Dictionary:
	var out := {"guard": guarding, "flinch": flinch}
	if attack != &"":
		var d: Dictionary = ATTACKS[attack]
		out["attack"] = {"kind": attack, "t": attack_time, "windup": d.windup, "active": d.active,
			"total": attack_total(attack)}
	return out
