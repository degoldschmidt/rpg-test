class_name LocomotionPlayer
extends RefCounted
## Plays retargeted mocap (MocapClip) as the puppet's ground locomotion.
##
## - Cycles (idle, walk, jog, run, sprint: looping clips sorted by speed) are blended by the
##   capsule's speed. The two cycles around the current speed play at the same normalized phase,
##   aligned on their left-foot touchdown, so feet land together while blending.
## - Playback speed follows the capsule (the clips' root motion only sets the rate; gameplay
##   movement stays in PlayerController).
## - Feet: while the clip says a foot is planted it is locked where it touched down (on the
##   ground under it), so it can't slide; at lift-off it blends back onto the clip's path.
##   The rig's leg IK places the legs on these targets (same interface as FootPlanner).

const MOCAP_DIR := "res://assets/animations/mixamo"
const PROBE_UP := 0.6
const PROBE_DOWN := 0.5

## Clip library shared by all characters. Tests can replace it (set to a Dictionary of clips).
static var library_override = null
## Debug: lock planted feet (off = play the clip's feet as they are).
static var lock_feet := true
static var _library: Dictionary = {}
static var _loaded := false

var idle: MocapClip
var cycles: Array[MocapClip] = []   ## moving loops, slowest first
var phase := 0.0          ## cycle phase 0..1, 0 = left touchdown
var idle_t := 0.0
var weight := 0.0         ## blend of the mocap feet over the animated legs (FootPlanner-compatible)
var moving_k := 0.0
var run_k := 0.0
var turn_rate := 0.0
var feet := {}            ## side -> Transform3D ankle target (world)
var stance := {&"l": 0.0, &"r": 0.0}
var swing := {&"l": -1.0, &"r": -1.0}
var _lock := {}           ## side -> locked ankle position (world) while planted
var _lock_t := {&"l": 0.0, &"r": 0.0}
var _lock_dur := {&"l": 0.3, &"r": 0.3}
var _lock_basis := {}     ## side -> foot orientation held while planted
var lock_err := {&"l": Vector3.ZERO, &"r": Vector3.ZERO}   ## debug: locked foot minus the clip's foot
var _release := {&"l": 1.0, &"r": 1.0}   ## 0..1 blend from the released lock back to the clip
var _release_from := {}   ## side -> lock offset from the clip foot at lift-off
var _prev_contact := {&"l": true, &"r": true}
var _prev_vel_yaw := 0.0
var active := false


static func shared_library() -> Dictionary:
	if library_override != null:
		return library_override
	if not _loaded:
		_loaded = true
		_library = MocapImporter.load_library(MOCAP_DIR)
	return _library


func _init() -> void:
	set_library(shared_library())


func set_library(lib: Dictionary) -> void:
	idle = null
	cycles.clear()
	for c: MocapClip in lib.values():
		if not c.loop:
			continue
		if c.speed < 0.3:
			if idle == null:
				idle = c
		elif c.touchdown_l >= 0:
			cycles.append(c)
	cycles.sort_custom(func(a, b): return a.speed < b.speed)
	# One clip per gait and speed band: of near-duplicates (within 0.4 m/s, both walking or both
	# running), keep the faster; walking and running gaits are kept apart.
	var kept: Array[MocapClip] = []
	for c: MocapClip in cycles:
		if not kept.is_empty() and c.speed - kept[-1].speed < 0.4 and is_running(c) == is_running(kept[-1]):
			kept[-1] = c
		else:
			kept.append(c)
	cycles = kept


## A running gait has a flight phase (both feet off the ground for part of the cycle).
static func is_running(c: MocapClip) -> bool:
	var air := 0
	for f in c.frames:
		if c.support_l[f] == 0 and c.support_r[f] == 0:
			air += 1
	return air > c.frames * 0.08


func has_clips() -> bool:
	return not cycles.is_empty()


func reset() -> void:
	active = false


## ctx: root (Transform3D at the capsule bottom), facing, vel, grounded, space.
## Returns the pose {bones, root_rot, root_offset} or {} when not grounded.
func update(c: Dictionary, dt: float) -> Dictionary:
	var grounded: bool = c.get("grounded", false)
	weight = move_toward(weight, 1.0 if grounded else 0.0, dt * (6.0 if grounded else 10.0))
	if not grounded:
		active = false
		return {}
	var root: Transform3D = c.root
	var vel: Vector3 = c.vel
	vel.y = 0.0
	var v := vel.length()
	var space: PhysicsDirectSpaceState3D = c.get("space")
	if not active:
		active = true
		_lock.clear()
		_prev_contact = {&"l": true, &"r": true}
		_prev_vel_yaw = atan2(-vel.x, -vel.z) if v > 0.5 else float(c.get("facing", 0.0))
	var vel_yaw := atan2(-vel.x, -vel.z) if v > 0.5 else float(c.get("facing", 0.0))
	var dturn := wrapf(vel_yaw - _prev_vel_yaw, -PI, PI) / maxf(dt, 1e-4)
	_prev_vel_yaw = vel_yaw
	turn_rate = lerpf(turn_rate, clampf(dturn if absf(dturn) < 10.0 else 0.0, -6.0, 6.0), 1.0 - exp(-10.0 * dt))
	moving_k = move_toward(moving_k, clampf(v / 1.0, 0.0, 1.0), dt * 4.0)

	# Which two cycles, and how far between them.
	var a: MocapClip = cycles[0]
	var b: MocapClip = cycles[0]
	var w := 0.0
	if v >= cycles[-1].speed:
		a = cycles[-1]
		b = a
	else:
		for i in range(cycles.size() - 1):
			if v < cycles[i + 1].speed:
				a = cycles[i]
				b = cycles[i + 1]
				w = clampf((v - a.speed) / (b.speed - a.speed), 0.0, 1.0)
				break
	var cyc_len := lerpf(a.cycle_length(), b.cycle_length(), w)
	var cyc_speed := lerpf(a.speed, b.speed, w)
	# Faster than the fastest clip: quicker steps (cadence), the clip's stride stays.
	var rate := clampf(v / maxf(cyc_speed, 0.01), 0.45, 2.2)
	var idle_w := 1.0 - smoothstep(0.15, maxf(cycles[0].speed * 0.6, 0.3), v) if idle else 0.0
	if v < 0.15 and idle:
		rate = 0.0   # standing: the cycle holds (feet stay planted), idle takes over
	phase = fposmod(phase + dt * rate / cyc_len, 1.0)
	idle_t += dt
	run_k = clampf((v - 2.0) / 1.5, 0.0, 1.0)

	var pa := a.sample(_cycle_time(a))
	var pose := pa
	if b != a and w > 0.001:
		pose = _blend(pa, b.sample(_cycle_time(b)), w)
	if idle_w > 0.001:
		var pi := idle.sample(idle_t)
		pose = _blend(pose, pi, idle_w)
		# Standing: both feet down.
		if idle_w > 0.5:
			pose.contact = {&"l": true, &"r": true}

	# Feet: clip path relative to the moving root, locked while planted.
	var pel := root.basis * Basis(pose.root_rot as Quaternion)
	var bones: Dictionary = pose.bones
	for s: StringName in [&"l", &"r"]:
		var rel: Vector3 = (pose.feet as Dictionary)[s]
		var clip_pos := root * rel
		var g := _ground(space, clip_pos, root.origin.y)
		clip_pos.y = g.y + rel.y
		var fb := pel * Basis(bones[StringName("thigh_" + s)] as Quaternion) * Basis(bones[StringName("shin_" + s)] as Quaternion) \
			* Basis(bones[StringName("foot_" + s)] as Quaternion)
		# On a slope, a foot near the ground tilts with it.
		var n: Vector3 = g.normal
		var low := 1.0 - smoothstep(0.1, 0.2, rel.y)
		if low > 0.0 and not n.is_equal_approx(Vector3.UP):
			fb = Basis(Quaternion(Vector3.UP, n).slerp(Quaternion.IDENTITY, 1.0 - low)) * fb
		var planted: bool = (pose.contact as Dictionary)[s] and lock_feet
		if planted:
			# A planted foot sits flat on the ground (on a slope, tilted with it).
			fb = Basis(Quaternion(fb.y.normalized(), n)) * fb
		if planted and (not _prev_contact[s] or not _lock.has(s)):
			_lock_basis[s] = fb
			_lock[s] = clip_pos
			_lock_t[s] = 0.0
			var dom := a if w < 0.5 else b
			_lock_dur[s] = maxf(dom.contact_left(s, _cycle_time(dom)) / maxf(rate, 0.1), 0.05)
		if planted and _lock.has(s) and (_lock[s] as Vector3).distance_to(clip_pos) > 0.45:
			_lock[s] = clip_pos   # far off the clip (turned round, pushed): re-plant
			_lock_basis[s] = fb
		if planted and _lock_basis.has(s):
			# A planted foot keeps its orientation, except turning with the body (pivot on the spot).
			var lb: Basis = _lock_basis[s]
			var turn := wrapf(_yaw_of(fb) - _yaw_of(lb), -PI, PI)
			if absf(turn) > 0.6:
				lb = Basis(Vector3.UP, turn - signf(turn) * 0.6) * lb
				_lock_basis[s] = lb
			fb = lb
		if not planted and _prev_contact[s] and _lock.has(s):
			# Lift-off: fade out the lock's (small) offset from the clip's foot, so the foot follows
			# the clip's swing right away instead of being dragged from where it stood.
			_release_from[s] = (_lock[s] as Vector3) - clip_pos
			_release[s] = 0.0
			_lock.erase(s)
		_prev_contact[s] = planted
		var p := clip_pos
		lock_err[s] = (_lock[s] as Vector3) - clip_pos if _lock.has(s) else Vector3.ZERO
		if planted and _lock.has(s):
			p = _lock[s]
			_lock_t[s] += dt
			stance[s] = clampf(_lock_t[s] / float(_lock_dur.get(s, 0.3)), 0.0, 1.0)
			swing[s] = -1.0
		else:
			_release[s] = minf(float(_release[s]) + dt / 0.15, 1.0)
			if _release_from.has(s) and float(_release[s]) < 1.0:
				p = clip_pos + (_release_from[s] as Vector3) * (1.0 - smoothstep(0.0, 1.0, _release[s]))
			stance[s] = -1.0
			swing[s] = 0.5
		feet[s] = Transform3D(fb.orthonormalized(), p)
	return {"bones": pose.bones, "root_rot": pose.root_rot, "root_offset": pose.root_offset}


static func _yaw_of(b: Basis) -> float:
	var f := -b.z
	return atan2(-f.x, -f.z)


## Time in the clip for the shared phase (phase 0 = that clip's left touchdown).
func _cycle_time(c: MocapClip) -> float:
	return fposmod(float(c.touchdown_l) / c.fps + phase * c.cycle_length(), c.length())


static func _blend(a: Dictionary, b: Dictionary, w: float) -> Dictionary:
	var bones := {}
	for k in a.bones:
		bones[k] = (a.bones[k] as Quaternion).slerp(b.bones[k], w)
	var fa: Dictionary = a.feet
	var fb: Dictionary = b.feet
	return {
		"bones": bones,
		"root_rot": (a.root_rot as Quaternion).slerp(b.root_rot, w),
		"root_offset": (a.root_offset as Vector3).lerp(b.root_offset, w),
		"feet": {&"l": (fa[&"l"] as Vector3).lerp(fb[&"l"], w), &"r": (fa[&"r"] as Vector3).lerp(fb[&"r"], w)},
		"contact": a.contact if w < 0.5 else b.contact,
	}


## Ground height and normal under p (no space: flat ground at the root's height).
func _ground(space: PhysicsDirectSpaceState3D, p: Vector3, ref_y: float) -> Dictionary:
	if space:
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, ref_y + PROBE_UP, p.z),
			Vector3(p.x, ref_y - PROBE_DOWN, p.z), RagdollRig.IK_MASK)
		var hit := space.intersect_ray(q)
		if hit and (hit.normal as Vector3).y > 0.6:
			return {"y": (hit.position as Vector3).y, "normal": hit.normal}
	return {"y": ref_y, "normal": Vector3.UP}
