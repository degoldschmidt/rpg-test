class_name DummyBrain
extends Node
## Drives a PlayerController through its external-input path, like a player would.
## PASSIVE stands still, GUARD holds guard facing the target, SPARRING closes in and
## alternates punch and kick on a fixed rhythm, guarding when the target winds up.

enum Mode { PASSIVE, GUARD, SPARRING, WANDER }

@export var mode: Mode = Mode.PASSIVE
@export var engage_range := 6.0
@export var attack_range := 1.5
@export var attack_interval := 1.6
@export var turn_to_target := true

var target: PlayerController
var body: PlayerController
var _t := 0.0
var _next_kick := false
var _rng := RandomNumberGenerator.new()
var _wander_dir := Vector2.ZERO
var _wander_t := 0.0
var _home := Vector3.ZERO
var _wander_acc := 0.0
@export var wander_seed := 0
@export var wander_radius := 6.0


func _ready() -> void:
	process_physics_priority = -1  # decide before the body reads its input
	body = get_parent() as PlayerController


func _physics_process(dt: float) -> void:
	if body == null:
		return
	if mode == Mode.WANDER:
		# Think only when the body acts this tick (reduced LOD tiers skip ticks).
		_wander_acc += dt
		if not body.ticks_this_frame():
			return
		var inp := {}
		_wander(_wander_acc, inp)
		_wander_acc = 0.0
		body.external_input = inp
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


## Continue a stroll handed over from the crowd layer (direction as stick input, time to the
## next decision).
func start_wander(home: Vector3, seed: int, dir: Vector2, time_left: float) -> void:
	_rng.seed = seed
	_home = home
	_wander_dir = dir
	_wander_t = time_left
	_wander_acc = 0.0


func wander_dir() -> Vector2:
	return _wander_dir


func wander_time_left() -> float:
	return _wander_t


## Stroll in random directions around the spawn point, with pauses. Seeded, so runs repeat.
func _wander(dt: float, inp: Dictionary) -> void:
	if _wander_t == 0.0 and _home == Vector3.ZERO:
		_rng.seed = wander_seed
		_home = body.global_position
		_wander_t = _rng.randf_range(0.0, 2.0)
	_wander_t -= dt
	if _wander_t <= 0.0:
		_wander_t = _rng.randf_range(1.5, 4.0)
		if _rng.randf() < 0.4:
			_wander_dir = Vector2.ZERO
		else:
			var to_home := _home - body.global_position
			var a := _rng.randf_range(0.0, TAU)
			var d := Vector2(cos(a), sin(a))
			if Vector2(to_home.x, to_home.z).length() > wander_radius:
				d = Vector2(to_home.x, to_home.z).normalized()
			_wander_dir = d * 0.45
	# Out of the home radius and still walking away: turn back now (as the crowd layer does).
	var th := _home - body.global_position
	var h2 := Vector2(th.x, th.z)
	if _wander_dir != Vector2.ZERO and h2.length() > wander_radius and _wander_dir.dot(h2) < 0.0:
		_wander_dir = h2.normalized() * 0.45
	inp["move"] = _wander_dir
