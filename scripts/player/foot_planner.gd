class_name FootPlanner
extends RefCounted
## Procedural stepping for the legs. Each foot is either planted (locked to a world position, so
## it never slides) or swinging along an arc to a landing spot predicted from the body's velocity
## and turn rate, so that the foot is under the hips at mid-stance. Cadence, stride, duty factor
## (walk: double support, run: a flight phase) and swing height follow the speed. Feet roll
## heel-to-toe: heel strike when walking, then the heel peels off and the foot pivots on the toe.
## Standing still, feet stay planted; turning on the spot or drifting makes the character step to
## re-centre them.
##
## Outputs world-space ankle targets (`feet`) for leg IK, and the gait phase / run blend that the
## pose generator uses for the pelvis, torso and arms.

const SIDES: Array[StringName] = [&"l", &"r"]
const ANKLE_H := 0.08                    ## ankle pivot above the sole
const HIP_X := 0.1                       ## half the stance width when standing
const TOE := Vector3(0, -0.08, -0.17)    ## sole contact points, relative to the ankle (foot frame)
const HEEL := Vector3(0, -0.08, 0.07)
const PROBE_UP := 0.6
const PROBE_DOWN := 0.5

var phase := 0.0          ## gait cycle 0..1: left foot touches down at 0, right at 0.5
var weight := 0.0         ## blend of the planned feet over the animated legs
var run_k := 0.0          ## 0 walking gait .. 1 running gait
var sprint_k := 0.0       ## 0 jog .. 1 sprint
var duty := 0.6           ## fraction of the cycle each foot is on the ground
var cadence := 0.0        ## steps per second
var swing_height := 0.1
var active := false
var stance := {&"l": 0.0, &"r": 0.0}   ## progress through the current stance 0..1 (-1 while swinging)
var swing := {&"l": -1.0, &"r": -1.0}  ## progress through the current swing 0..1 (-1 while planted)
var feet := {}            ## side -> Transform3D ankle target (world)
var moving_k := 0.0       ## 0 standing .. 1 travelling (smoothed), scales the upper-body motion

var _plant := {}          ## side -> flat-foot ankle position while planted
var _yaw := {}            ## side -> foot heading
var _normal := {}         ## side -> ground normal under the foot
var _lift := {}           ## side -> ankle position at lift-off
var _lift_yaw := {}
var _lift_pitch := {}
var _target := {}         ## side -> predicted landing ankle position
var _target_yaw := {}
var _target_normal := {}
var _swinging := {&"l": false, &"r": false}
var _prev_facing := 0.0
var _yaw_rate := 0.0


func reset() -> void:
	active = false


## ctx: root (Transform3D, capsule bottom), facing (yaw), vel (Vector3), grounded (bool),
## space (PhysicsDirectSpaceState3D or null for no ground probes), crouch (0..1)
func update(c: Dictionary, dt: float) -> void:
	if not c.get("grounded", false):
		active = false
		weight = move_toward(weight, 0.0, dt * 10.0)
		return
	var root: Transform3D = c.root
	var facing: float = c.facing
	var space: PhysicsDirectSpaceState3D = c.get("space")
	if not active:
		_reset_feet(root, facing, space)
		_prev_facing = facing
		_yaw_rate = 0.0
		active = true
	if dt <= 0.0:
		return
	weight = move_toward(weight, 1.0, dt * 6.0)
	_yaw_rate = lerpf(_yaw_rate, wrapf(facing - _prev_facing, -PI, PI) / dt, 1.0 - exp(-12.0 * dt))
	_prev_facing = facing

	var vel: Vector3 = c.vel
	vel.y = 0.0
	var v := vel.length()
	var crouch: float = c.get("crouch", 0.0)
	# Walk / run with hysteresis, so the gait doesn't flicker around the transition speed.
	var want_run := v > (1.9 if run_k > 0.5 else 2.2)
	run_k = move_toward(run_k, 1.0 if want_run and crouch < 0.5 else 0.0, dt * 3.0)
	sprint_k = move_toward(sprint_k, clampf((v - 3.6) / 3.6, 0.0, 1.0), dt * 3.0)
	var moving := v > 0.2
	moving_k = move_toward(moving_k, clampf(v / 1.0, 0.0, 1.0), dt * 4.0)

	# Cadence grows with speed; walking steps stay within what the legs can span (faster walking
	# takes quicker steps), in a run the stride does most of the work.
	var walk_fs := maxf(1.45 + 0.35 * v, v / 0.72)
	var run_fs := 2.6 + 0.12 * v
	cadence = lerpf(walk_fs, run_fs, run_k) * lerpf(1.0, 0.8, crouch)
	if not moving:
		cadence = 1.9   # corrective steps when standing
	var cycle := 2.0 / cadence
	# Duty: a walk always has a foot down (double support); a run is limited by how much ground
	# one leg can cover while planted, which leaves a flight phase.
	var run_contact := lerpf(0.7, 0.92, sprint_k)
	var run_duty := clampf(run_contact / maxf(v * cycle, 0.01), 0.2, 0.48)
	var walk_duty := clampf(0.75 / maxf(v * cycle, 0.01), 0.53, 0.62)
	duty = lerpf(walk_duty, run_duty, run_k)
	swing_height = lerpf(0.08 + 0.02 * v, lerpf(0.2, 0.42, sprint_k), run_k) * lerpf(1.0, 0.6, crouch)

	if moving or not _settled(root, facing):
		phase = fmod(phase + dt / cycle, 1.0)
	_recover_overreach(root, facing)

	var swing_t := (1.0 - duty) * cycle
	var stance_t := duty * cycle
	for s in SIDES:
		var ph := phase if s == &"l" else fmod(phase + 0.5, 1.0)
		var in_swing := ph >= duty
		if in_swing and not _swinging[s]:
			_swinging[s] = true
			_lift[s] = _planted_pose(s, 1.0).origin   # from the heel-up push-off pose
			_lift_yaw[s] = _yaw[s]
			_lift_pitch[s] = _stance_pitch(1.0)
		elif not in_swing and _swinging[s]:
			_swinging[s] = false
			_plant[s] = _target[s]
			_yaw[s] = _target_yaw[s]
			_normal[s] = _target_normal[s]
		if _swinging[s]:
			var u := clampf((ph - duty) / (1.0 - duty), 0.0, 1.0)
			_predict_landing(s, root, facing, vel, (1.0 - u) * swing_t, stance_t, space)
			swing[s] = u
			stance[s] = -1.0
			feet[s] = _swing_pose(s, u)
		else:
			var st := ph / duty
			stance[s] = st
			swing[s] = -1.0
			feet[s] = _planted_pose(s, st)


## Where the foot should land: under the hips half-way through its next stance, following the
## predicted body position and heading at touchdown.
func _predict_landing(s: StringName, root: Transform3D, facing: float, vel: Vector3, t_rem: float,
		stance_t: float, space: PhysicsDirectSpaceState3D) -> void:
	var turn := clampf(_yaw_rate * t_rem, -1.2, 1.2)
	var vel_land := vel.rotated(Vector3.UP, turn)
	var body := root.origin + (vel + vel_land) * 0.5 * t_rem
	var yaw_land := facing + turn
	var side := -1.0 if s == &"l" else 1.0
	var width := lerpf(HIP_X, 0.06, run_k)
	# Walking the foot lands as far ahead as it pushes off behind; running it lands closer in and
	# pushes off further back (long rear-leg extension).
	var ahead := lerpf(0.45, 0.4, run_k)
	var p := body + vel_land * (stance_t * ahead) + Basis(Vector3.UP, yaw_land) * Vector3(side * width, 0, 0)
	var g := _ground(space, p, root.origin.y)
	_target[s] = Vector3(p.x, g.y + ANKLE_H, p.z)
	_target_normal[s] = g.normal
	# Feet point where the body will be heading, splayed out slightly.
	_target_yaw[s] = yaw_land - side * 0.08


func _swing_pose(s: StringName, u: float) -> Transform3D:
	var a: Vector3 = _lift[s]
	var b: Vector3 = _target[s]
	# The swing foot keeps up with the body (it travels two step lengths while the body travels
	# one); walking it eases in and out, running the heel stays back a little while it tucks up.
	var ease := smoothstep(0.0, 1.0, u)
	var fwd := lerpf(ease, u + 0.6 * (ease - u), run_k)
	var p := a.lerp(b, fwd)
	var arc_u := pow(u, lerpf(1.0, 0.6, run_k))
	p.y = lerpf(a.y, b.y, smoothstep(0.0, 1.0, u)) + maxf(b.y - a.y, 0.0) * sin(PI * u) * 0.5 \
		+ swing_height * sin(PI * arc_u)
	var yaw := lerp_angle(_lift_yaw[s], _target_yaw[s], smoothstep(0.1, 0.8, u))
	# Toe points down after push-off, levels out, then the toe comes up for the heel strike.
	var land_pitch := _stance_pitch(0.0)
	var pitch := lerpf(_lift_pitch[s], -0.25 * run_k, smoothstep(0.0, 0.45, u))
	pitch = lerpf(pitch, land_pitch, smoothstep(0.6, 1.0, u))
	var n: Vector3 = (_normal[s] as Vector3).slerp(_target_normal[s], u)
	return Transform3D(_foot_basis(yaw, n) * Basis(Vector3.RIGHT, pitch), p)


func _planted_pose(s: StringName, st: float) -> Transform3D:
	var flat := _foot_basis(_yaw[s], _normal[s])
	var pitch := _stance_pitch(st)
	if absf(pitch) < 0.001:
		return Transform3D(flat, _plant[s])
	# Roll about the heel (toe up) or the toe (heel up), keeping that contact point fixed.
	var pivot := HEEL if pitch > 0.0 else TOE
	var rolled := flat * Basis(Vector3.RIGHT, pitch)
	var contact: Vector3 = _plant[s] + flat * pivot
	return Transform3D(rolled, contact - rolled * pivot)


## Foot pitch through the stance (+ toe up, - heel up): heel strike settling flat, then heel-off.
func _stance_pitch(st: float) -> float:
	var strike := lerpf(0.22, -0.05, run_k) * (1.0 - smoothstep(0.0, 0.18, st))
	var heel_off := -lerpf(0.5, 0.75, run_k) * smoothstep(lerpf(0.55, 0.4, run_k), 1.0, st)
	return (strike + heel_off) * moving_k


func _foot_basis(yaw: float, n: Vector3) -> Basis:
	var b := Basis(Vector3.UP, yaw)
	if n.is_equal_approx(Vector3.UP):
		return b
	return Basis(Quaternion(Vector3.UP, n.normalized())) * b


## A planted foot left far from its hip (reversing, a sudden shove, turning around) steps right
## away instead of stretching the legs into a lunge: the gait phase jumps to its lift-off. Only
## in the walking gait, where the other foot then stays planted.
func _recover_overreach(root: Transform3D, facing: float) -> void:
	if duty <= 0.52 or _swinging[&"l"] or _swinging[&"r"]:
		return
	var reach := lerpf(0.5, 0.6, run_k)
	for s in SIDES:
		var side := -1.0 if s == &"l" else 1.0
		var hip := root.origin + Basis(Vector3.UP, facing) * Vector3(side * HIP_X, 0, 0)
		var p: Vector3 = _plant[s]
		if Vector2(p.x - hip.x, p.z - hip.z).length() > reach:
			phase = fmod(duty + (0.0 if s == &"l" else 0.5) + 0.001, 1.0)
			return


## Standing still with both feet down near where they belong: no need to step.
func _settled(root: Transform3D, facing: float) -> bool:
	for s in SIDES:
		if _swinging[s]:
			return false
		var ph := phase if s == &"l" else fmod(phase + 0.5, 1.0)
		if ph >= duty - 0.02:
			return false   # stop only in double support, never with a foot about to lift
		var side := -1.0 if s == &"l" else 1.0
		var home := root.origin + Basis(Vector3.UP, facing) * Vector3(side * HIP_X, 0, 0)
		var p: Vector3 = _plant[s]
		if Vector2(p.x - home.x, p.z - home.z).length() > 0.14:
			return false
		if absf(wrapf(_yaw[s] - facing, -PI, PI)) > 0.45:
			return false
	return true


func _reset_feet(root: Transform3D, facing: float, space: PhysicsDirectSpaceState3D) -> void:
	phase = 0.05
	moving_k = 0.0
	for s in SIDES:
		var side := -1.0 if s == &"l" else 1.0
		var p := root.origin + Basis(Vector3.UP, facing) * Vector3(side * HIP_X, 0, 0)
		var g := _ground(space, p, root.origin.y)
		_plant[s] = Vector3(p.x, g.y + ANKLE_H, p.z)
		_yaw[s] = facing
		_normal[s] = g.normal
		_target[s] = _plant[s]
		_target_yaw[s] = facing
		_target_normal[s] = g.normal
		_swinging[s] = false
		feet[s] = Transform3D(_foot_basis(facing, g.normal), _plant[s])


## Ground height and normal under p (no space: flat ground at the root's height).
func _ground(space: PhysicsDirectSpaceState3D, p: Vector3, ref_y: float) -> Dictionary:
	if space:
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, ref_y + PROBE_UP, p.z),
			Vector3(p.x, ref_y - PROBE_DOWN, p.z), RagdollRig.IK_MASK)
		var hit := space.intersect_ray(q)
		if hit and (hit.normal as Vector3).y > 0.6:
			return {"y": (hit.position as Vector3).y, "normal": hit.normal}
	return {"y": ref_y, "normal": Vector3.UP}
