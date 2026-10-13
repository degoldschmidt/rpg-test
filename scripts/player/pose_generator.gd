class_name PoseGenerator
extends RefCounted
## Procedural target poses (no animation assets). Produces per-bone local rotations
## relative to the parent, plus a root (pelvis) rotation and offset.
## Conventions: +X pitch swings a hanging limb forward / tilts the torso backward;
## +Z roll tilts the top of a segment to the character's left.

const BONES: Array[StringName] = [
	&"spine", &"chest", &"head",
	&"upper_arm_l", &"forearm_l", &"hand_l", &"upper_arm_r", &"forearm_r", &"hand_r",
	&"thigh_l", &"shin_l", &"foot_l", &"thigh_r", &"shin_r", &"foot_r",
]

var phase := 0.0
var time := 0.0
var _cur: Dictionary = {}
var _root_rot := Quaternion.IDENTITY
var _root_off := Vector3.ZERO
var _ik_w := 0.0


func _init() -> void:
	for b in BONES:
		_cur[b] = Quaternion.IDENTITY


## ctx keys: mode, speed, run_k, move, vy, crouch, roll_t, get_up_t, lean (Vector2 lateral/forward accel),
## land_squash, skid
func compute(c: Dictionary, dt: float) -> Dictionary:
	time += dt
	var e := {}
	for b in BONES:
		e[b] = Vector3.ZERO
	var off := Vector3.ZERO
	var root_e := Vector3.ZERO
	var rate := 14.0
	var raw_root := false
	var mode: StringName = c.get("mode", &"ground")
	var speed: float = c.get("speed", 0.0)
	var run_k: float = c.get("run_k", 0.0)
	var move: float = c.get("move", 0.0)
	var lean: Vector2 = c.get("lean", Vector2.ZERO)

	# Relaxed base: arms slightly out and bent, gentle idle breathing.
	e[&"upper_arm_l"].z = -0.12
	e[&"upper_arm_r"].z = 0.12
	e[&"forearm_l"].x = 0.2
	e[&"forearm_r"].x = 0.2
	e[&"chest"].x = 0.02 * sin(time * 2.2)

	match mode:
		&"ground", &"crouch", &"stumble":
			var cr: float = c.get("crouch", 0.0) + c.get("land_squash", 0.0) * 0.7
			if mode == &"stumble":
				cr = maxf(cr, 0.55)
				e[&"spine"].x -= 0.5
				e[&"upper_arm_l"] += Vector3(1.0, 0, -0.6 + 0.3 * sin(time * 17.0))
				e[&"upper_arm_r"] += Vector3(1.0, 0, 0.6 + 0.3 * sin(time * 13.0))
			_crouch(e, clampf(cr, 0.0, 1.2))
			off += Vector3(0, -0.3, 0.15) * clampf(cr, 0.0, 1.2)
			var amount := clampf(speed / 1.5, 0.0, 1.0) * maxf(move, 0.3 if speed > 0.5 else 0.0)
			off.y += _gait(e, speed, run_k, amount * (0.6 if cr > 0.5 else 1.0), dt)
			if c.get("skid", false):
				e[&"spine"].x += 0.4
				root_e.x += 0.3
				off.y -= 0.12
				e[&"thigh_l"].x += 0.6
				e[&"shin_l"].x -= 0.1
				e[&"thigh_r"].x -= 0.1
				e[&"shin_r"].x -= 0.8
				e[&"upper_arm_l"] += Vector3(0.9, 0, -0.9)
				e[&"upper_arm_r"] += Vector3(0.9, 0, 0.9)
			else:
				# Lean into acceleration and bank into turns.
				e[&"spine"].x -= clampf(lean.y * 0.03, -0.3, 0.3)
				root_e.z -= clampf(lean.x * 0.035, -0.4, 0.4)
		&"slide":
			rate = 10.0
			root_e.x += 0.45
			off += Vector3(0, -0.5, 0.1)
			e[&"thigh_l"].x += 1.4
			e[&"shin_l"].x -= 0.15
			e[&"thigh_r"].x += 0.6
			e[&"shin_r"].x -= 1.9
			e[&"spine"].x -= 0.2
			e[&"chest"].x -= 0.2
			e[&"head"].x -= 0.3
			e[&"upper_arm_l"] += Vector3(0.4, 0, -1.1)
			e[&"upper_arm_r"] += Vector3(0.4, 0, 1.1)
		&"air":
			rate = 10.0
			var vy: float = c.get("vy", 0.0)
			if vy > 0.0:
				e[&"thigh_l"].x += 0.8
				e[&"shin_l"].x -= 1.1
				e[&"thigh_r"].x += 0.1
				e[&"shin_r"].x -= 0.5
				e[&"upper_arm_l"] += Vector3(0.9, 0, -0.4)
				e[&"upper_arm_r"] += Vector3(-0.3, 0, 0.4)
			else:
				var f := clampf(-vy / 18.0, 0.0, 1.0)
				e[&"thigh_l"].x += 0.4 - 0.3 * f
				e[&"shin_l"].x -= 0.5
				e[&"thigh_r"].x += 0.1
				e[&"shin_r"].x -= 0.3
				var flail := sin(time * 14.0) * 0.6 * f
				e[&"upper_arm_l"] += Vector3(0.3 + flail, 0, -(0.5 + 0.9 * f))
				e[&"upper_arm_r"] += Vector3(0.3 - flail, 0, 0.5 + 0.9 * f)
				e[&"spine"].x += 0.15 * f
			e[&"spine"].x -= clampf(speed * 0.02, 0.0, 0.15)
		&"roll":
			rate = 30.0
			raw_root = true
			var t: float = c.get("roll_t", 0.0)
			var tuck := smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.85, 1.0, t))
			root_e.x = -TAU * smoothstep(0.05, 0.95, t)
			off.y -= 0.5 * tuck
			e[&"thigh_l"].x += 2.1 * tuck
			e[&"thigh_r"].x += 2.0 * tuck
			e[&"shin_l"].x -= 2.3 * tuck
			e[&"shin_r"].x -= 2.3 * tuck
			e[&"foot_l"].x += 0.5 * tuck
			e[&"foot_r"].x += 0.5 * tuck
			e[&"spine"].x -= 0.7 * tuck
			e[&"chest"].x -= 0.4 * tuck
			e[&"head"].x -= 0.6 * tuck
			e[&"upper_arm_l"] += Vector3(1.1, 0, 0.1) * tuck
			e[&"upper_arm_r"] += Vector3(1.1, 0, -0.1) * tuck
			e[&"forearm_l"].x += 1.2 * tuck
			e[&"forearm_r"].x += 1.2 * tuck
		&"get_up":
			rate = 6.0
			var t: float = c.get("get_up_t", 0.0)
			var cr := 1.0 - smoothstep(0.45, 1.0, t)
			_crouch(e, cr)
			off += Vector3(0, -0.3, 0.15) * cr
			e[&"spine"].x -= 0.3 * cr
			e[&"upper_arm_l"].x += 0.7 * cr
			e[&"upper_arm_r"].x += 0.7 * cr
		_:
			pass  # ragdoll: targets unused

	# Keep feet roughly level with the ground.
	if mode != &"roll" and mode != &"air":
		e[&"foot_l"].x -= (e[&"thigh_l"].x + e[&"shin_l"].x + root_e.x) * 0.8
		e[&"foot_r"].x -= (e[&"thigh_r"].x + e[&"shin_r"].x + root_e.x) * 0.8

	var k := 1.0 - exp(-rate * dt)
	# Foot IK on whenever the feet are meant to be on the ground.
	var ik_target := 0.0
	match mode:
		&"ground", &"crouch", &"stumble", &"get_up":
			ik_target = 1.0
		&"slide":
			ik_target = 0.6
	_ik_w = lerpf(_ik_w, ik_target, 1.0 - exp(-10.0 * dt))
	for b in BONES:
		_cur[b] = (_cur[b] as Quaternion).slerp(Quaternion.from_euler(e[b]), k)
	var root_q := Quaternion.from_euler(root_e)
	if raw_root:
		_root_rot = root_q
		_root_off = off
	else:
		_root_rot = _root_rot.slerp(root_q, k)
		_root_off = _root_off.lerp(off, k)
	return {"bones": _cur, "root_rot": _root_rot, "root_offset": _root_off, "foot_ik": _ik_w}


func _crouch(e: Dictionary, cr: float) -> void:
	e[&"thigh_l"].x += 1.2 * cr
	e[&"thigh_r"].x += 1.2 * cr
	e[&"shin_l"].x -= 1.6 * cr
	e[&"shin_r"].x -= 1.6 * cr
	e[&"spine"].x -= 0.35 * cr
	e[&"chest"].x -= 0.2 * cr
	e[&"head"].x += 0.4 * cr
	e[&"upper_arm_l"].x += 0.3 * cr
	e[&"upper_arm_r"].x += 0.3 * cr


## Adds a walk/run cycle, returns the vertical pelvis bob.
func _gait(e: Dictionary, speed: float, run_k: float, amount: float, dt: float) -> float:
	if amount <= 0.001:
		return 0.0
	var stride := lerpf(0.7, 1.25, run_k)
	phase = fmod(phase + TAU * speed / (2.0 * stride) * dt, TAU)
	var s := sin(phase)
	var co := cos(phase)
	var swing := lerpf(0.4, 0.8, run_k) * amount
	e[&"thigh_l"].x += swing * s
	e[&"thigh_r"].x -= swing * s
	var knee := lerpf(0.6, 1.6, run_k) * amount
	e[&"shin_l"].x -= 0.1 * amount + knee * maxf(0.0, co)
	e[&"shin_r"].x -= 0.1 * amount + knee * maxf(0.0, -co)
	var arm := lerpf(0.35, 0.9, run_k) * amount
	e[&"upper_arm_l"].x -= arm * s
	e[&"upper_arm_r"].x += arm * s
	e[&"forearm_l"].x += lerpf(0.1, 1.3, run_k) * amount
	e[&"forearm_r"].x += lerpf(0.1, 1.3, run_k) * amount
	e[&"spine"].x -= lerpf(0.04, 0.25, run_k) * amount
	e[&"chest"].y += 0.18 * s * amount
	e[&"spine"].y -= 0.1 * s * amount
	return -(0.02 + 0.05 * run_k) * absf(co) * amount
