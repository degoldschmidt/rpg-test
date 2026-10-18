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
const LEG := {&"l": [&"thigh_l", &"shin_l", &"foot_l"], &"r": [&"thigh_r", &"shin_r", &"foot_r"]}
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
## How deep a transition clip may crouch (pelvis below rest, m) before it's eased off: some
## clips (Mixamo's running turn) drop the hips far lower than the puppet's legs carry well.
const DIP_SOFT := 0.12
const DIP_KEEP := 0.2
## Fastest walking pace (m/s) that starts with the walk-start clip.
const START_WALK_MAX := 2.2
## Re-plant a locked foot once it's this far from the clip's foot (during transitions: the clip
## and the capsule disagree more there, so sooner).
const REPLANT := 0.45
const REPLANT_TRANSITION := 0.3

## Transition clips (optional; found by name): stopping, walk and sprint starts, turning round
## at speed, turning on the spot.
var stop_walk: MocapClip
var stop_run: MocapClip
var start_walk: MocapClip
var start_run: MocapClip
var turn_run: MocapClip
var turns_stand: Array[MocapClip] = []   ## turning on the spot (left and right, any angle)
var transition := &""     ## current transition: &"stop", &"start", &"turn", &"turn_stand" or none
var _tr: MocapClip
var _tr_t := 0.0
var _tr_w := 0.0
var _tr_end := false
var _tr_v0 := 0.0
var _tr_face0 := 0.0
var _tr_start_t := 0.0
var _tr_scale := 1.0      ## standing turns: requested angle / the clip's turn
var _prev_facing := 0.0
var _tr_speed := PackedFloat32Array()   ## the transition clip's root speed per frame
var _yaw_off := 0.0       ## turn transitions: the clip's turn so far minus the body's
var _prev_v := 0.0
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
var _settle := {}         ## side -> {from: Transform3D, t: 0..1}: a small step to the idle stance
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
	stop_walk = _find(lib, ["stop", "walk"])
	stop_run = _find(lib, ["run", "stop"])
	start_walk = _find(lib, ["start", "walk"])
	start_run = _find(lib, ["idle to sprint"]) if _find(lib, ["idle to sprint"]) else _find(lib, ["run", "start"])
	turn_run = _find(lib, ["running turn 180"])
	# Turning on the spot: one-shot turns that barely travel (not the running or crouching ones).
	turns_stand.clear()
	for c: MocapClip in _find_all(lib, ["turn"]):
		var n := c.clip_name.to_lower()
		if c.speed < 0.6 and absf(c.turn) > 0.8 and not ("run" in n or "crouch" in n):
			turns_stand.append(c)


static func _find(lib: Dictionary, words: Array) -> MocapClip:
	var all := _find_all(lib, words)
	return all[0] if not all.is_empty() else null


## One-shot clips whose name holds all of the words (sorted by name, so the choice is stable).
static func _find_all(lib: Dictionary, words: Array) -> Array[MocapClip]:
	var out: Array[MocapClip] = []
	var keys := lib.keys()
	keys.sort()
	for k: String in keys:
		var n := k.to_lower()
		var ok := true
		for w: String in words:
			ok = ok and w in n
		if ok and not (lib[k] as MocapClip).loop:
			out.append(lib[k])
	return out


## The standing turn closest to turning by `angle` (rad, + = left), and the angle it should
## cover (the same turn written the other way round when that fits the clip better).
func _pick_turn(angle: float) -> Array:
	var best: MocapClip = null
	var best_target := angle
	var best_err := INF
	for c: MocapClip in turns_stand:
		for target in [angle, angle - signf(angle) * TAU]:
			if signf(target) != signf(c.turn) or absf(target) > 3.6:
				continue
			var err := absf(log(absf(target) / absf(c.turn)))   # ratio: 80 vs 100 degrees is close
			if err < best_err:
				best_err = err
				best = c
				best_target = target
	return [best, best_target]


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
		_settle.clear()
		_prev_facing = float(c.get("facing", 0.0))
		transition = &""
		_tr = null
		_yaw_off = 0.0
		_prev_contact = {&"l": true, &"r": true}
		_prev_vel_yaw = atan2(-vel.x, -vel.z) if v > 0.5 else float(c.get("facing", 0.0))
	var vel_yaw := atan2(-vel.x, -vel.z) if v > 0.5 else float(c.get("facing", 0.0))
	var dturn := wrapf(vel_yaw - _prev_vel_yaw, -PI, PI) / maxf(dt, 1e-4)
	_prev_vel_yaw = vel_yaw
	turn_rate = lerpf(turn_rate, clampf(dturn if absf(dturn) < 10.0 else 0.0, -6.0, 6.0), 1.0 - exp(-10.0 * dt))
	moving_k = move_toward(moving_k, clampf(v / 1.0, 0.0, 1.0), dt * 4.0)

	# Which two cycles, and how far between them.
	var br := _bracket(v)
	var a: MocapClip = br[0]
	var b: MocapClip = br[1]
	var w: float = br[2]
	var cyc_len := lerpf(a.cycle_length(), b.cycle_length(), w)
	var rate := _rate(v, a, b, w)
	var idle_w := 1.0 - smoothstep(0.15, maxf(cycles[0].speed * 0.6, 0.3), v) if idle else 0.0
	if v < 0.15 and idle:
		rate = 0.0   # standing: the cycle holds (feet stay planted), idle takes over
	phase = fposmod(phase + dt * rate / cyc_len, 1.0)
	idle_t += dt
	run_k = clampf((v - 2.0) / 1.5, 0.0, 1.0)

	# Only the clips that show: standing is the idle alone, a speed at a clip's is that clip.
	var pose: Dictionary
	if idle_w < 0.999:
		if b == a or w <= 0.001:
			pose = a.sample(_cycle_time(a))
		elif w >= 0.999:
			pose = b.sample(_cycle_time(b))
		else:
			pose = _blend(a.sample(_cycle_time(a)), b.sample(_cycle_time(b)), w)
	if idle_w > 0.001:
		var pi := idle.sample(idle_t)
		pose = pi if idle_w >= 0.999 else _blend(pose, pi, idle_w)
		# Standing: both feet down.
		if idle_w > 0.5:
			pose.contact = {&"l": true, &"r": true}

	pose = _transitions(c, pose, v, dt)
	_prev_v = v
	if absf(_yaw_off) > 0.001:
		# Turning round: the body follows the clip's turn, ahead of (or behind) the capsule's facing.
		var q := Quaternion(Vector3.UP, _yaw_off)
		pose.root_rot = q * (pose.root_rot as Quaternion)
		pose.root_offset = Basis(q) * (pose.root_offset as Vector3)
		var fr: Dictionary = pose.feet
		pose.feet = {&"l": Basis(q) * (fr[&"l"] as Vector3), &"r": Basis(q) * (fr[&"r"] as Vector3)}

	# Feet: clip path relative to the moving root, locked while planted.
	var pel := root.basis * Basis(pose.root_rot as Quaternion)
	var bones: Dictionary = pose.bones
	for s: StringName in [&"l", &"r"]:
		var rel: Vector3 = (pose.feet as Dictionary)[s]
		var clip_pos := root * rel
		var g := _ground(space, clip_pos, root.origin.y)
		clip_pos.y = g.y + rel.y
		var leg: Array = LEG[s]
		var fb := pel * Basis((bones[leg[0]] as Quaternion) * (bones[leg[1]] as Quaternion) * (bones[leg[2]] as Quaternion))
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
		if planted and _lock.has(s) and (_lock[s] as Vector3).distance_to(clip_pos) > (REPLANT if transition == &"" else REPLANT_TRANSITION):
			_lock[s] = clip_pos   # far off the clip (turned round, pushed): re-plant
			_lock_basis[s] = fb
		var clip_fb := fb
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
		# Standing still with a foot left out of place (after a stop, a turn on the spot): step it
		# back under the body, one foot at a time.
		var standing: bool = idle_w > 0.9 and transition == &"" and planted and _lock.has(s) and c.get("settle", true)
		if standing and not _settle.has(s) and not _settle.has(_other(s)):
			var off := Vector2((_lock[s] as Vector3).x - clip_pos.x, (_lock[s] as Vector3).z - clip_pos.z).length()
			var twist := absf(wrapf(_yaw_of(clip_fb) - _yaw_of(_lock_basis[s]), -PI, PI))
			var other_off := _lock_off(_other(s), root, pose)
			if (off > 0.12 or twist > 0.4) and off >= other_off:
				_settle[s] = {"from": Transform3D(_lock_basis[s], _lock[s]), "t": 0.0}
		if _settle.has(s):
			var st: Dictionary = _settle[s]
			st.t = minf(float(st.t) + dt / 0.35, 1.0)
			var u: float = st.t
			var from: Transform3D = st.from
			var e := smoothstep(0.0, 1.0, u)
			var sp := from.origin.lerp(clip_pos, e) + Vector3.UP * 0.07 * sin(PI * u)
			var sb := Basis(Quaternion(from.basis.orthonormalized()).slerp(Quaternion(clip_fb.orthonormalized()), e))
			if u >= 1.0 or not standing:
				_settle.erase(s)
				if planted:
					# Done (or cut short by moving off): plant where the foot got to.
					_lock[s] = Vector3(sp.x, clip_pos.y, sp.z)
					_lock_basis[s] = sb
					_lock_t[s] = 0.0
			else:
				_prev_contact[s] = planted
				lock_err[s] = Vector3.ZERO
				stance[s] = -1.0
				swing[s] = u
				feet[s] = Transform3D(sb, sp)
				continue
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


static func _other(s: StringName) -> StringName:
	return &"r" if s == &"l" else &"l"


## How far a locked foot sits from where the pose puts it (0 if it isn't locked).
func _lock_off(s: StringName, root: Transform3D, pose: Dictionary) -> float:
	if not _lock.has(s):
		return 0.0
	var cp := root * ((pose.feet as Dictionary)[s] as Vector3)
	var lp: Vector3 = _lock[s]
	return Vector2(lp.x - cp.x, lp.z - cp.z).length()


## The two cycles around speed v and how far between them: [slower, faster, weight].
func _bracket(v: float) -> Array:
	if v >= cycles[-1].speed:
		return [cycles[-1], cycles[-1], 0.0]
	for i in range(cycles.size() - 1):
		if v < cycles[i + 1].speed:
			var a := cycles[i]
			var b := cycles[i + 1]
			return [a, b, clampf((v - a.speed) / (b.speed - a.speed), 0.0, 1.0)]
	return [cycles[0], cycles[0], 0.0]


## Cycle playback rate at speed v. Faster than the fastest clip: quicker steps (cadence), the
## clip's stride stays.
static func _rate(v: float, a: MocapClip, b: MocapClip, w: float) -> float:
	return clampf(v / maxf(lerpf(a.speed, b.speed, w), 0.01), 0.45, 2.2)


## Seconds per gait cycle (two steps) when moving at v (e.g. to bake a looping crowd stroll).
func cycle_period(v: float) -> float:
	var br := _bracket(v)
	return lerpf((br[0] as MocapClip).cycle_length(), (br[1] as MocapClip).cycle_length(), br[2]) / _rate(v, br[0], br[1], br[2])


static func _yaw_of(b: Basis) -> float:
	var f := -b.z
	return atan2(-f.x, -f.z)


## Stops, starts, turning round at speed and turning on the spot play their transition clip
## over the cycles. Clip time follows what the capsule actually does: stops along the clip's
## deceleration (by the fraction of speed lost), starts along its acceleration, turns in real
## time with the body following the clip's heading (standing turns scaled to the angle asked).
func _transitions(c: Dictionary, pose: Dictionary, v: float, dt: float) -> Dictionary:
	var wish: Vector3 = c.get("wish", Vector3.ZERO)
	var wl := wish.length()
	var facing: float = c.get("facing", 0.0)
	var face_before := _prev_facing
	_prev_facing = facing
	if transition == &"":
		var turn_to := wrapf(atan2(-wish.x, -wish.z) - face_before, -PI, PI) if wl > 0.3 else 0.0
		if wl < 0.1 and v > 1.2 and v < _prev_v and (stop_walk or stop_run):
			_begin(&"stop", stop_run if v > 3.0 and stop_run else (stop_walk if stop_walk else stop_run), v, facing)
		elif c.get("skid", false) and v > 3.0 and turn_run:
			_begin(&"turn", turn_run, v, facing)
		elif _prev_v < 0.6 and absf(turn_to) > 0.8 and not turns_stand.is_empty() and not c.get("run", false):
			# Stepping round to face a new direction from a standstill.
			var pick := _pick_turn(turn_to)
			if pick[0]:
				_begin(&"turn_stand", pick[0], v, face_before)
				_tr_scale = clampf(float(pick[1]) / (pick[0] as MocapClip).turn, 0.6, 1.6)
		elif _prev_v < 0.4 and wl > 0.3:
			# Sprint start when running; the walk start only for walking pace (it tops out near
			# 1 m/s, a jog gets going faster than it does).
			var target: float = c.get("target_speed", -1.0)
			var clip: MocapClip = null
			if c.get("run", false):
				clip = start_run
			elif target < START_WALK_MAX:
				clip = start_walk
			if clip:
				_begin(&"start", clip, v, facing)
	if transition == &"":
		return pose
	var len := _tr.length()
	match transition:
		&"stop":
			if wl > 0.3:
				_tr_end = true   # moving again: back to the cycles
			var r := clampf(v / maxf(_tr_v0, 0.01), 0.0, 1.0)
			var tt := _time_at_speed(r, true)
			_tr_t = clampf(tt, _tr_t + dt * 0.4, _tr_t + dt * 2.0) if v > 0.05 else _tr_t + dt
		&"start":
			if wl < 0.1:
				_tr_end = true
			# Clip time runs at the capsule's speed over the clip's (its strides cover the ground
			# the capsule does); once the clip's as fast as the capsule, or at its peak, the
			# cycles take over.
			var peak := _peak_frame()
			var f := clampi(int(_tr_t * _tr.fps), 0, _tr.frames - 1)
			var cs := _tr_speed[f]
			_tr_t += dt * clampf(v / maxf(cs, 0.25), 0.8, 2.5)
			if _tr_t >= peak / _tr.fps or (cs >= v * 0.9 and _tr_t > _tr_start_t + 0.25):
				_tr_end = true
		&"turn", &"turn_stand":
			var body_turn := wrapf(facing - _tr_face0, -PI, PI)
			if transition == &"turn_stand":
				# Walking off: step round quicker, then let the cycles take over.
				_tr_t += dt * (1.15 + v)
				if v > 1.2:
					_tr_end = true
			else:
				_tr_t += dt
			var f := mini(int(_tr_t * _tr.fps), _tr.frames - 1)
			var clip_turn := wrapf(_tr.root_yaw[f] - _tr.root_yaw[0], -PI, PI)
			if transition == &"turn_stand":
				clip_turn *= _tr_scale
			_yaw_off = wrapf(clip_turn - body_turn, -PI, PI) * _tr_w
	if _tr_t >= len - 0.02:
		_tr_end = true
	var was_end := _tr_end and _tr_w >= 1.0
	_tr_w = move_toward(_tr_w, 0.0 if _tr_end else 1.0, dt * (4.0 if _tr_end else 8.0))
	if _tr_end:
		_yaw_off = move_toward(_yaw_off, 0.0, dt * 6.0)
		if was_end and transition in [&"start", &"turn"]:
			_match_phase(_tr.sample(minf(_tr_t, len - 0.001)))
	elif not transition in [&"turn", &"turn_stand"]:
		_yaw_off = 0.0
	if _tr_end and _tr_w <= 0.0:
		transition = &""
		_tr = null
		_yaw_off = 0.0
		return pose
	var tp := _tr.sample(minf(_tr_t, len - 0.001))
	# Ease off very deep crouches (soft limit on how far the hips drop below the clip's rest).
	var ro: Vector3 = tp.root_offset
	if ro.y < -DIP_SOFT:
		ro.y = -DIP_SOFT - (-ro.y - DIP_SOFT) * DIP_KEEP
		tp.root_offset = ro
	return _blend(pose, tp, _tr_w)


## Leaving a transition into the cycles: pick the cycle phase whose feet match the transition
## clip's, so the cycles carry on with the same foot forward instead of jumping a step.
func _match_phase(tp: Dictionary) -> void:
	var c := cycles[0]
	for cy in cycles:
		if absf(cy.speed - _prev_v) < absf(c.speed - _prev_v):
			c = cy
	var fl: Vector3 = (tp.feet as Dictionary)[&"l"]
	var fr: Vector3 = (tp.feet as Dictionary)[&"r"]
	var best := phase
	var best_d := INF
	var keep := phase
	for i in 32:
		phase = i / 32.0
		var cp := c.sample(_cycle_time(c))
		var d: float = ((cp.feet as Dictionary)[&"l"] as Vector3).distance_squared_to(fl) \
			+ ((cp.feet as Dictionary)[&"r"] as Vector3).distance_squared_to(fr)
		if d < best_d:
			best_d = d
			best = phase
	phase = best if best_d < INF else keep


func _begin(kind: StringName, clip: MocapClip, v: float, facing: float) -> void:
	transition = kind
	_tr = clip
	_tr_end = false
	_tr_w = 0.0
	_tr_v0 = v
	_tr_face0 = facing
	_tr_scale = 1.0
	_yaw_off = 0.0
	_tr_speed = PackedFloat32Array()
	_tr_speed.resize(clip.frames)
	for f in clip.frames:
		var a := maxi(f - 3, 0)
		var b := mini(f + 3, clip.frames - 1)
		_tr_speed[f] = (clip.root_pos[b] - clip.root_pos[a]).length() * clip.fps / maxf(b - a, 1)
	_tr_t = 0.0
	if kind == &"stop":
		_tr_t = _peak_frame() / clip.fps   # from full speed on
	elif kind == &"start":
		_tr_t = _time_at_speed(0.12, false)   # skip the clip's standing lead-in
	_tr_start_t = _tr_t


func _peak_frame() -> int:
	var best := 0
	var half := _tr.frames / 2 if transition == &"stop" else _tr.frames
	for f in half:
		if _tr_speed[f] > _tr_speed[best]:
			best = f
	return best


## Clip time where its speed (relative to its peak) passes r: after the peak going down
## (stops), before it going up (starts).
func _time_at_speed(r: float, falling: bool) -> float:
	var peak := _peak_frame()
	var top := maxf(_tr_speed[peak], 0.01)
	if falling:
		for f in range(peak, _tr.frames):
			if _tr_speed[f] / top <= r:
				return f / _tr.fps
		return _tr.length()
	for f in range(0, peak + 1):
		if _tr_speed[f] / top >= r:
			return f / _tr.fps
	return peak / _tr.fps


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
