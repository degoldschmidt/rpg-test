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

var time := 0.0
## Foot placement for every grounded mode: planted feet, swing arcs, step phase.
var gait := FootPlanner.new()
## Mocap locomotion (Mixamo clips in assets/animations/mixamo) when available; else procedural.
static var use_mocap := true
var loco: LocomotionPlayer
var _clip_w := 0.0       ## 0 procedural .. 1 mocap ground locomotion
var _attack_w := 0.0
var _kick_w := 0.0
var _arms_free := 1.0   ## arm swing and torso twist give way while the arms are busy
var _root := Transform3D()
var _bank := 0.0        ## lean into the current turn (rad, + = to the left)
var _swing_s := 0.0     ## leg scissor: + when the right thigh is ahead of the left
var _cur: Dictionary = {}
var _root_rot := Quaternion.IDENTITY
var _root_off := Vector3.ZERO
var _ik_w := 0.0
var _hand_w := 0.0


func _init() -> void:
	for b in BONES:
		_cur[b] = Quaternion.IDENTITY


## ctx keys: mode, speed, run_k, move, vy, crouch, roll_t, get_up_t, lean (Vector2 lateral/forward accel),
## land_squash, skid; for foot placement also root (Transform3D), facing, vel, grounded, space
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
		&"ground", &"crouch", &"stumble", &"stagger":
			var cr: float = c.get("crouch", 0.0) + c.get("land_squash", 0.0) * 0.7
			if mode == &"stumble":
				cr = maxf(cr, 0.55)
				e[&"spine"].x -= 0.5
				e[&"upper_arm_l"] += Vector3(1.0, 0, -0.6 + 0.3 * sin(time * 17.0))
				e[&"upper_arm_r"] += Vector3(1.0, 0, 0.6 + 0.3 * sin(time * 13.0))
			_crouch(e, clampf(cr, 0.0, 1.2))
			off += Vector3(0, -0.3, 0.15) * clampf(cr, 0.0, 1.2)
			# Legs come from the foot planner (IK); a slight FK knee bend keeps the knees forward.
			for s in ["l", "r"]:
				e[StringName("thigh_" + s)].x += 0.15
				e[StringName("shin_" + s)].x -= 0.35
			if c.get("skid", false):
				# Braking hard: sit back over the braking steps (the feet are placed by the
				# planner), arms come forward for balance.
				e[&"spine"].x += 0.15
				root_e.x += 0.22
				off.y -= 0.06
				e[&"head"].x -= 0.15
				e[&"upper_arm_l"] += Vector3(0.55, 0, -0.35)
				e[&"upper_arm_r"] += Vector3(0.55, 0, 0.35)
			else:
				# Lean into acceleration, back when braking (banking into turns is added with
				# the gait, as a lean of the whole body over the feet).
				root_e.x -= clampf(lean.y * 0.025, -0.25, 0.3)
				e[&"spine"].x -= clampf(lean.y * 0.015, -0.15, 0.2)
				e[&"head"].x += clampf(lean.y * 0.02, -0.2, 0.25)
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
		&"hang":
			rate = 10.0
			_apply(e, _key_hang(), 1.0)
			off += Vector3(0, 0, -0.12)
			var sh: float = c.get("shimmy", 0.0)
			var sway := sin(time * 1.6)
			e[&"thigh_l"].x += 0.12 * sway
			e[&"thigh_r"].x -= 0.12 * sway
			if sh != 0.0:
				# Hand-over-hand: alternate arms reaching sideways.
				var s := sin(time * 9.0)
				e[&"upper_arm_l"].z -= 0.25 * maxf(s, 0.0)
				e[&"upper_arm_r"].z += 0.25 * maxf(-s, 0.0)
				root_e.z -= 0.08 * sh
		&"climb":
			rate = 18.0
			var t: float = c.get("climb_t", 0.0)
			var from_hang: bool = c.get("climb_from_hang", false)
			var k0 := _key_hang() if from_hang else _key_reach()
			var keys := [[0.0, k0], [0.45, _key_pull()], [0.8, _key_crouch()], [1.0, {}]]
			for i in keys.size() - 1:
				var a: Array = keys[i]
				var b: Array = keys[i + 1]
				if t <= b[0] or i == keys.size() - 2:
					var u := clampf((t - a[0]) / (b[0] - a[0]), 0.0, 1.0)
					u = u * u * (3.0 - 2.0 * u)
					_apply(e, a[1], 1.0 - u)
					_apply(e, b[1], u)
					off += (a[1] as Dictionary).get(&"_off", Vector3.ZERO) * (1.0 - u) + (b[1] as Dictionary).get(&"_off", Vector3.ZERO) * u
					root_e += (a[1] as Dictionary).get(&"_root", Vector3.ZERO) * (1.0 - u) + (b[1] as Dictionary).get(&"_root", Vector3.ZERO) * u
					break
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

	# --- combat overlays
	var atk: Dictionary = c.get("attack", {})
	if mode == &"stagger":
		# Knocked back: arms thrown out, torso and head whipped back.
		var fl := sin(time * 15.0) * 0.4
		_lerp_bone(e, &"upper_arm_l", Vector3(0.7 + fl, 0, -1.0), 0.9)
		_lerp_bone(e, &"upper_arm_r", Vector3(0.7 - fl, 0, 1.0), 0.9)
		e[&"spine"].x += 0.35
		e[&"chest"].x += 0.15
		e[&"head"].x += 0.45
	if c.get("guard", false):
		for s in ["l", "r"]:
			var side := -1.0 if s == "l" else 1.0
			_lerp_bone(e, StringName("upper_arm_" + s), Vector3(1.25, 0, -0.45 * side), 1.0)
			_lerp_bone(e, StringName("forearm_" + s), Vector3(2.2, 0, 0), 1.0)
			e[StringName("thigh_" + s)].x += 0.2
			e[StringName("shin_" + s)].x -= 0.3
		e[&"spine"].x -= 0.12
		e[&"head"].x -= 0.1
		off.y -= 0.04
	if not atk.is_empty():
		var t: float = atk.t
		var wu: float = atk.windup
		var act: float = atk.active
		var total: float = atk.total
		var w_wind := smoothstep(0.0, wu * 0.8, t) * (1.0 - smoothstep(wu - 0.02, wu + 0.03, t))
		var w_hit := smoothstep(wu - 0.03, wu + 0.03, t) * (1.0 - smoothstep(wu + act, total, t))
		rate = 30.0
		if atk.kind == &"punch":
			# Right cross: chamber the fist with the chest turned away, then snap it out.
			_lerp_bone(e, &"upper_arm_r", Vector3(0.5, 0, 0.35), w_wind)
			_lerp_bone(e, &"forearm_r", Vector3(2.1, 0, 0), w_wind)
			_lerp_bone(e, &"upper_arm_r", Vector3(1.55, 0, -0.1), w_hit)
			_lerp_bone(e, &"forearm_r", Vector3(0.05, 0, 0), w_hit)
			var g := maxf(w_wind, w_hit)
			_lerp_bone(e, &"upper_arm_l", Vector3(1.15, 0, 0.35), g)
			_lerp_bone(e, &"forearm_l", Vector3(2.0, 0, 0), g)
			e[&"chest"].y += -0.3 * w_wind + 0.35 * w_hit
			e[&"spine"].y += -0.1 * w_wind + 0.15 * w_hit
			e[&"spine"].x -= 0.15 * w_hit
		else:
			# Front kick: chamber the knee leaning back, then extend through the target.
			_lerp_bone(e, &"thigh_r", Vector3(1.6, 0, 0), w_wind)
			_lerp_bone(e, &"shin_r", Vector3(-1.8, 0, 0), w_wind)
			_lerp_bone(e, &"thigh_r", Vector3(1.45, 0, 0), w_hit)
			_lerp_bone(e, &"shin_r", Vector3(-0.1, 0, 0), w_hit)
			var g := maxf(w_wind, w_hit)
			e[&"shin_l"].x -= 0.2 * g
			e[&"spine"].x += 0.15 * w_wind + 0.35 * w_hit
			root_e.x += 0.1 * w_hit
			_lerp_bone(e, &"upper_arm_l", Vector3(0.6, 0, -0.6), g)
			_lerp_bone(e, &"upper_arm_r", Vector3(0.3, 0, 0.5), g)
	var fl_d: Dictionary = c.get("flinch", {})
	if not fl_d.is_empty():
		var k := 1.0 - smoothstep(0.0, 0.35, fl_d.t)
		var side: float = fl_d.side
		match fl_d.region:
			&"head":
				e[&"head"].x += 0.7 * k
				e[&"chest"].x += 0.2 * k
				e[&"head"].y += 0.3 * k * side
			&"torso":
				e[&"spine"].x += 0.35 * k
				e[&"chest"].x += 0.2 * k
				e[&"chest"].y += 0.4 * k * side
			&"arm_l":
				e[&"upper_arm_l"] += Vector3(-0.4, 0, -0.8) * k
			&"arm_r":
				e[&"upper_arm_r"] += Vector3(-0.4, 0, 0.8) * k
			&"leg":
				e[&"spine"].x -= 0.25 * k
				e[&"thigh_l"].x -= 0.3 * k
			&"guard":
				e[&"upper_arm_l"].x -= 0.35 * k
				e[&"upper_arm_r"].x -= 0.35 * k
				e[&"spine"].x += 0.15 * k

	# Arm overlays for carrying / pushing (hand IK then places the palms exactly).
	var arm_mode: StringName = c.get("arm_mode", &"")
	if arm_mode == &"carry":
		for s in ["l", "r"]:
			var side := -1.0 if s == "l" else 1.0
			e[StringName("upper_arm_" + s)] = Vector3(0.9, 0, 0.25 * side)
			e[StringName("forearm_" + s)] = Vector3(1.1, 0, 0)
		e[&"spine"].x += 0.1
	elif arm_mode == &"push":
		var push: float = c.get("push_amount", 0.0)
		for s in ["l", "r"]:
			var side := -1.0 if s == "l" else 1.0
			e[StringName("upper_arm_" + s)] = Vector3(1.35, 0, 0.15 * side)
			e[StringName("forearm_" + s)] = Vector3(0.5, 0, 0)
		# Lean into a push, lean back into a pull.
		e[&"spine"].x -= 0.3 * maxf(push, 0.0) - 0.25 * maxf(-push, 0.0)
		root_e.x -= 0.2 * maxf(push, 0.0) - 0.15 * maxf(-push, 0.0)
	var hand_targets: Dictionary = c.get("hand_targets", {})
	_hand_w = lerpf(_hand_w, 1.0 if not hand_targets.is_empty() else 0.0, 1.0 - exp(-12.0 * dt))

	# Keep feet roughly level with the ground.
	if not mode in [&"roll", &"air", &"hang", &"climb"]:
		e[&"foot_l"].x -= (e[&"thigh_l"].x + e[&"shin_l"].x + root_e.x) * 0.8
		e[&"foot_r"].x -= (e[&"thigh_r"].x + e[&"shin_r"].x + root_e.x) * 0.8

	var k := 1.0 - exp(-rate * dt)
	# Foot placement on whenever the feet are meant to be on the ground; terrain foot IK for
	# the other grounded poses (getting up, sliding).
	var stepping := mode in [&"ground", &"crouch", &"stumble", &"stagger"] and c.has("root")
	var braking: float = 1.0 if c.get("skid", false) else clampf(-lean.y / 10.0, 0.0, 1.0)
	_root = c.get("root", Transform3D())
	var v_now: Vector3 = c.get("vel", Vector3.ZERO)
	# Bank into turns like a runner: lean = atan(v * turn rate / g), whole body over the feet.
	# (Only for real turning at speed: reversing through a standstill flips the velocity's heading.)
	var hv := Vector2(v_now.x, v_now.z).length()
	# Mocap ground locomotion: plain ground mode only (crouch, stumble etc. stay procedural).
	if use_mocap and loco == null:
		loco = LocomotionPlayer.new()
	var clip_pose := {}
	var clip_ok := use_mocap and loco.has_clips() and stepping
	if clip_ok:
		clip_pose = loco.update({"grounded": c.get("grounded", true) and mode == &"ground", "root": c.get("root", Transform3D()),
			"facing": c.get("facing", 0.0), "vel": v_now, "space": c.get("space"), "wish": c.get("wish", Vector3.ZERO),
			"run": c.get("run", false), "target_speed": c.get("target_speed", -1.0), "skid": c.get("skid", false), "settle": atk.is_empty() and _attack_w < 0.01}, dt)
	_clip_w = move_toward(_clip_w, 1.0 if not clip_pose.is_empty() else 0.0, dt * 6.0)
	if clip_pose.is_empty() and _clip_w > 0.0:
		_clip_w = 0.0   # left the ground: hand straight back to the procedural pose
	# The procedural stepping only runs while it's (partly) in use; it restarts from the current
	# stance when it's needed again.
	if _clip_w < 1.0:
		gait.update({"grounded": stepping and c.get("grounded", true), "root": c.get("root", Transform3D()),
			"facing": c.get("facing", 0.0), "vel": c.get("vel", Vector3.ZERO), "space": c.get("space"),
			"crouch": c.get("crouch", 0.0), "brake": braking}, dt)
	else:
		gait.reset()
	var turn_now := loco.turn_rate if _clip_w > 0.5 else gait.turn_rate
	var bank_t := clampf(atan(hv * clampf(turn_now, -3.5, 3.5) / 9.8), -0.35, 0.35) * smoothstep(2.0, 4.0, hv)
	_bank = lerpf(_bank, bank_t if stepping else 0.0, 1.0 - exp(-6.0 * dt))
	var gw := gait.weight
	_kick_w = move_toward(_kick_w, 1.0 if atk.get("kind", &"") == &"kick" else 0.0, dt * 8.0)
	_attack_w = move_toward(_attack_w, 0.0 if atk.is_empty() else 1.0, dt * 12.0)
	var busy: bool = not atk.is_empty() or c.get("guard", false) or arm_mode != &"" or not hand_targets.is_empty() \
		or mode == &"stagger"
	_arms_free = move_toward(_arms_free, 0.0 if busy else 1.0, dt * (12.0 if busy else 3.0))
	var ik_target := 0.0
	match mode:
		&"ground", &"crouch", &"stumble", &"get_up", &"stagger":
			ik_target = 0.0 if atk.get("kind", &"") == &"kick" else 1.0
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
	var out := {"bones": _cur, "root_rot": _root_rot, "root_offset": _root_off, "foot_ik": _ik_w * (1.0 - gw),
		"hand_ik": _hand_w if not hand_targets.is_empty() else 0.0, "hand_targets": hand_targets}
	if _clip_w > 0.001 and not clip_pose.is_empty():
		_apply_clip(out, clip_pose, _clip_w)
		out["feet"] = gait.feet if _clip_w < 0.5 else loco.feet
		out["feet_w"] = {&"l": loco.weight, &"r": loco.weight * (1.0 - _kick_w)}
		out["foot_ik"] = 0.0
		out["fk_knees"] = _clip_w >= 0.5
		return out
	if gw > 0.001:
		_add_gait_motion(out, gw, dt)
		out["feet"] = gait.feet
		out["feet_w"] = {&"l": gw, &"r": gw * (1.0 - _kick_w)}
	return out


## Mocap pose under the procedural overlays: the clip owns the body except where an action does
## (arms while attacking / guarding / carrying, the kicking leg), and the turn bank goes on top.
func _apply_clip(out: Dictionary, clip: Dictionary, w: float) -> void:
	var proc: Dictionary = out.bones
	var cb: Dictionary = clip.bones
	var bones := {}
	var arms_proc := 1.0 - _arms_free
	var attacking := _attack_w
	for b in BONES:
		var own := 0.0
		if String(b).begins_with("upper_arm") or String(b).begins_with("forearm") or String(b).begins_with("hand"):
			own = arms_proc
		elif b == &"chest" or b == &"spine" or b == &"head":
			own = maxf(arms_proc * 0.6, attacking)   # strikes are thrown from the torso
		elif b in [&"thigh_r", &"shin_r", &"foot_r"]:
			own = _kick_w
		var t := maxf(1.0 - w, own)
		bones[b] = cb[b] if t <= 0.0 else (cb[b] as Quaternion).slerp(proc[b], t)
	out.bones = bones
	# A strike also owns the hips (it is thrown from the stance, not from the idle sway).
	var root_proc := maxf(1.0 - w, _attack_w)
	out.root_rot = (clip.root_rot as Quaternion).slerp(out.root_rot, root_proc) * Quaternion.from_euler(Vector3(0, 0, _bank * w))
	out.root_offset = (clip.root_offset as Vector3).lerp(out.root_offset, root_proc) + Vector3(-sin(_bank * w) * 0.95, 0, 0)


## Pelvis, torso and arm motion that goes with the steps, layered on top of the smoothed pose
## (it follows the legs exactly, so it isn't smoothed).
func _add_gait_motion(out: Dictionary, w: float, dt: float) -> void:
	var g := gait
	var amt := g.moving_k * w
	var off := Vector3.ZERO
	var re := Vector3.ZERO
	# Bank: the whole body leans into the turn about the feet, so the hips shift to the inside
	# while the feet stay on the path.
	re.z += _bank * w
	off.x -= sin(_bank * w) * 0.95
	if amt <= 0.001:
		out.root_rot = (out.root_rot as Quaternion) * Quaternion.from_euler(re)
		out.root_offset = (out.root_offset as Vector3) + off
		return
	var r := g.run_k
	var sp := g.sprint_k
	var ph := g.phase * TAU
	var mid := g.duty * PI          # left foot mid-stance
	# Walking: weight shifts over the stance foot and the swing-side hip drops.
	var sway := -cos(ph - mid)
	off.x += 0.03 * sway * (1.0 - r) * amt
	re.z += 0.06 * sway * (1.0 - r) * amt
	# Running: lower, bouncing (lowest at mid-stance), leaning into the run.
	var psi := fmod(g.phase * 2.0, 1.0)
	off.y -= ((0.02 + 0.015 * sp) * cos(TAU * (psi - g.duty)) + 0.045 + 0.03 * sp) * r * amt
	var run_lean := (0.13 * r + 0.12 * sp) * amt
	re.x -= run_lean
	# Arms and twist follow the legs themselves (not the gait phase): the thighs' forward swing,
	# from the planned feet, so the arms are always contralateral whatever the gait or turn.
	var span := lerpf(0.55, lerpf(1.0, 1.3, sp), r)
	var scissor := clampf((_thigh_pitch(&"r") - _thigh_pitch(&"l")) / span, -1.0, 1.0)
	_swing_s = lerpf(_swing_s, scissor, 1.0 - exp(-18.0 * dt))   # arms trail the legs slightly
	# Hips turn with the forward leg (left leg ahead: left hip forward), shoulders counter-rotate.
	# Busy arms (attacking, guarding, carrying) keep the shoulders square instead.
	var twist := _swing_s * lerpf(0.12, 0.2, r)
	var arms := amt * _arms_free
	re.y += twist * amt
	var bones: Dictionary = (out.bones as Dictionary).duplicate()
	_rot(bones, &"spine", Vector3(0, -0.6 * twist * arms, 0))
	_rot(bones, &"chest", Vector3(0, -twist * (amt - 0.3 * arms), 0))
	# Keep the eyes level against the lean.
	_rot(bones, &"head", Vector3((0.1 * r + 0.09 * sp) * amt, 0, 0))
	# Shoulder swing (+ forward) and elbow bend at the front and back of the swing. Running,
	# the hands drive back past the hip with the elbow opening, and come forward to about chest
	# height with the elbow closing; walking, the arms swing loosely with a slight bend.
	var fwd_a := lerpf(0.3, lerpf(0.32, 0.42, sp), r)
	var back_a := lerpf(-0.3, lerpf(-0.6, -0.8, sp), r)
	var elbow_f := lerpf(0.25, lerpf(1.25, 1.35, sp), r)
	var elbow_b := lerpf(0.05, lerpf(0.85, 0.95, sp), r)
	# Arms are posed relative to the chest: give back the run lean so they still hang from the
	# shoulders instead of tilting back with the torso.
	var comp := run_lean * _arms_free
	# Left arm forward when the right leg is forward, and vice versa.
	for s in [["l", _swing_s, -1.0], ["r", -_swing_s, 1.0]]:
		var k: float = (float(s[1]) + 1.0) * 0.5   # 0 = arm fully back, 1 = fully forward
		_rot(bones, StringName("upper_arm_" + s[0]), Vector3(lerpf(back_a, fwd_a, k) * arms + comp, 0, 0.1 * float(s[2]) * r * arms))
		_rot(bones, StringName("forearm_" + s[0]), Vector3(lerpf(elbow_b, elbow_f, k) * arms, 0, 0))
	out.bones = bones
	out.root_rot = (out.root_rot as Quaternion) * Quaternion.from_euler(re)
	out.root_offset = (out.root_offset as Vector3) + off


## Forward swing of a thigh (rad, + = knee ahead of the hip) for the planned foot: the leg's
## two-bone solve in the body's forward plane, knee bending forward (as RagdollRig._leg_ik does).
const THIGH := 0.365
const SHIN := 0.465
func _thigh_pitch(s: StringName) -> float:
	if not gait.feet.has(s):
		return 0.0
	var side := -1.0 if s == &"l" else 1.0
	var hip := _root * Vector3(side * FootPlanner.HIP_X, 0.88, 0)
	var d: Vector3 = (gait.feet[s] as Transform3D).origin - hip
	var fwd := _root.basis * Vector3.FORWARD
	var f := d.dot(fwd)
	var h := -d.y
	var dist := clampf(sqrt(f * f + h * h), 0.05, THIGH + SHIN - 0.001)
	var bend := acos(clampf((THIGH * THIGH + dist * dist - SHIN * SHIN) / (2.0 * THIGH * dist), -1.0, 1.0))
	return atan2(f, h) + bend


func _rot(bones: Dictionary, b: StringName, euler: Vector3) -> void:
	bones[b] = (bones[b] as Quaternion) * Quaternion.from_euler(euler)


func _lerp_bone(e: Dictionary, bone: StringName, target: Vector3, w: float) -> void:
	if w > 0.0:
		e[bone] = (e[bone] as Vector3).lerp(target, clampf(w, 0.0, 1.0))


## Key poses are {bone: euler offset, &"_off": root offset, &"_root": root euler}.
func _apply(e: Dictionary, key: Dictionary, w: float) -> void:
	if w <= 0.0:
		return
	for b in key:
		if e.has(b):
			e[b] += (key[b] as Vector3) * w


## Arms overhead on the ledge, legs dangling.
func _key_hang() -> Dictionary:
	return {
		&"upper_arm_l": Vector3(2.75, 0, 0.27), &"upper_arm_r": Vector3(2.75, 0, -0.27),
		&"forearm_l": Vector3(-0.1, 0, 0), &"forearm_r": Vector3(-0.1, 0, 0),
		&"head": Vector3(0.25, 0, 0),
		&"thigh_l": Vector3(0.15, 0, 0), &"thigh_r": Vector3(0.05, 0, 0),
		&"shin_l": Vector3(-0.35, 0, 0), &"shin_r": Vector3(-0.2, 0, 0),
		&"foot_l": Vector3(0.4, 0, 0), &"foot_r": Vector3(0.3, 0, 0),
		&"_off": Vector3(0, 0, -0.12),
	}


## Hands reaching for a chest-high ledge, one knee lifting.
func _key_reach() -> Dictionary:
	return {
		&"upper_arm_l": Vector3(1.7, 0, 0.1), &"upper_arm_r": Vector3(1.7, 0, -0.1),
		&"forearm_l": Vector3(0.2, 0, 0), &"forearm_r": Vector3(0.2, 0, 0),
		&"spine": Vector3(-0.3, 0, 0),
		&"thigh_l": Vector3(0.9, 0, 0), &"shin_l": Vector3(-1.2, 0, 0),
	}


## Hips over the edge: arms pushing down, lead knee on the ledge.
func _key_pull() -> Dictionary:
	return {
		&"upper_arm_l": Vector3(-0.3, 0, -0.35), &"upper_arm_r": Vector3(-0.3, 0, 0.35),
		&"forearm_l": Vector3(0.9, 0, 0), &"forearm_r": Vector3(0.9, 0, 0),
		&"spine": Vector3(-0.6, 0, 0), &"chest": Vector3(-0.3, 0, 0), &"head": Vector3(0.4, 0, 0),
		&"thigh_l": Vector3(1.8, 0, 0), &"shin_l": Vector3(-2.2, 0, 0), &"foot_l": Vector3(0.4, 0, 0),
		&"thigh_r": Vector3(0.5, 0, 0), &"shin_r": Vector3(-1.0, 0, 0),
		&"_off": Vector3(0, -0.2, 0.05),
	}


func _key_crouch() -> Dictionary:
	var e := {}
	for b in BONES:
		e[b] = Vector3.ZERO
	_crouch(e, 1.0)
	e[&"_off"] = Vector3(0, -0.3, 0.15)
	return e


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
