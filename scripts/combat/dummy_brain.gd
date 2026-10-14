class_name DummyBrain
extends Node
## Drives a PlayerController through its external-input path, like a player would.
## PASSIVE stands still, GUARD holds guard facing the target, SPARRING closes in and
## alternates punch and kick on a fixed rhythm, guarding when the target winds up.

enum Mode { PASSIVE, GUARD, SPARRING }

@export var mode: Mode = Mode.PASSIVE
@export var engage_range := 6.0
@export var attack_range := 1.5
@export var attack_interval := 1.6
@export var turn_to_target := true

var target: PlayerController
var body: PlayerController
var _t := 0.0
var _next_kick := false


func _ready() -> void:
	process_physics_priority = -1  # decide before the body reads its input
	body = get_parent() as PlayerController


func _physics_process(dt: float) -> void:
	if body == null:
		return
	var inp := {}
	body.face_target = null
	if target and mode != Mode.PASSIVE:
		var to := target.global_position - body.global_position
		to.y = 0.0
		var dist := to.length()
		if mode == Mode.GUARD:
			inp["guard"] = true
			if turn_to_target:
				body.face_target = target
		elif dist < engage_range and target.state != PlayerController.State.RAGDOLL:
			body.face_target = target
			_t += dt
			if dist > attack_range * 0.85:
				var dir := to.normalized()
				inp["move"] = Vector2(dir.x, dir.z) * 0.7
			if target.combat.is_winding_up() and dist < 2.5 and body.combat.attack == &"":
				inp["guard"] = true
			elif dist <= attack_range and _t >= attack_interval:
				_t = 0.0
				inp["kick" if _next_kick else "punch"] = true
				_next_kick = not _next_kick
		else:
			_t = attack_interval * 0.5
	body.external_input = inp
