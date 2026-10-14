class_name CharacterLOD
extends RefCounted
## Simulation level of detail for characters. Distant characters stop simulating their
## active ragdoll: KINEMATIC snaps frozen puppet bodies to the animation (still hittable),
## PROXY_ONLY also drops their collision and animates every `pose_stride` ticks.
## Only the capsule proxy keeps full gameplay physics at every tier.

enum Tier { FULL, KINEMATIC, PROXY_ONLY }

const TIER_COLORS := [Color(0.6, 1.0, 0.6), Color(1.0, 0.9, 0.4), Color(1.0, 0.5, 0.5)]

## What every LOD-enabled character measures its distance to (usually the player).
static var focus: Node3D = null
## Debug: tint characters by tier (F3).
static var show_tiers := false


static func tier_for_distance(d: float, cfg: MovementConfig) -> Tier:
	if d < cfg.lod_full_range:
		return Tier.FULL
	if d < cfg.lod_kinematic_range:
		return Tier.KINEMATIC
	return Tier.PROXY_ONLY
