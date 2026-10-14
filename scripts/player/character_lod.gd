class_name CharacterLOD
extends RefCounted
## Simulation level of detail for characters. Distant characters stop simulating their
## active ragdoll: their puppet bodies are parked outside the physics server and the skin is
## driven straight from the animation. KINEMATIC runs the controller and animation every
## `kinematic_stride` ticks, PROXY_ONLY every `pose_stride` ticks. The capsule keeps colliding
## at every tier, and a hit, shove or strike touching it promotes the character back to FULL.

enum Tier { FULL, KINEMATIC, PROXY_ONLY }

const TIER_COLORS := [Color(0.6, 1.0, 0.6), Color(1.0, 0.9, 0.4), Color(1.0, 0.5, 0.5)]

## What every LOD-enabled character measures its distance to (usually the player).
static var focus: Node3D = null
## Debug: tint characters by tier (F3).
static var show_tiers := false


static var _last_assign := -1000000


## Budgeted assignment, run at most once per `lod_update_interval` for all characters:
## nearest first, up to `lod_max_full` FULL (within range) and `lod_max_kinematic` KINEMATIC,
## everyone else PROXY_ONLY. Busy characters stay FULL and count against the FULL budget.
static func assign(tree: SceneTree, cfg: MovementConfig) -> void:
	var now := Engine.get_physics_frames()
	if now - _last_assign < int(cfg.lod_update_interval * Engine.physics_ticks_per_second):
		return
	_last_assign = now
	if focus == null or not is_instance_valid(focus):
		return
	var free: Array = []
	var full := 0
	for n in tree.get_nodes_in_group("characters"):
		var c := n as PlayerController
		if c == null or not c.lod_enabled or c.lod_force >= 0:
			continue
		if c.lod_locked_full():
			c.lod_assigned = Tier.FULL
			full += 1
		else:
			free.append([c.global_position.distance_squared_to(focus.global_position), c])
	free.sort_custom(func(a, b): return a[0] < b[0])
	var kin := 0
	for e in free:
		var d := sqrt(float(e[0]))
		var c: PlayerController = e[1]
		if full < cfg.lod_max_full and d < cfg.lod_full_range:
			c.lod_assigned = Tier.FULL
			full += 1
		elif kin < cfg.lod_max_kinematic and d < cfg.lod_kinematic_range:
			c.lod_assigned = Tier.KINEMATIC
			kin += 1
		else:
			c.lod_assigned = Tier.PROXY_ONLY


static func tier_for_distance(d: float, cfg: MovementConfig) -> Tier:
	if d < cfg.lod_full_range:
		return Tier.FULL
	if d < cfg.lod_kinematic_range:
		return Tier.KINEMATIC
	return Tier.PROXY_ONLY
