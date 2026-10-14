class_name MocapClip
extends Resource
## One mocap clip retargeted onto the puppet (see MocapImporter). Per frame:
## - bone rotations relative to their parent, the pelvis relative to the character root
##   (the same layout PoseGenerator produces: `bones`, `root_rot`, `root_offset`),
## - the root (ground point under the hips, smoothed) position and heading in clip space,
## - each ankle relative to the root, and whether that foot is planted.

const BONES: Array[StringName] = [
	&"spine", &"chest", &"head",
	&"upper_arm_l", &"forearm_l", &"hand_l", &"upper_arm_r", &"forearm_r", &"hand_r",
	&"thigh_l", &"shin_l", &"foot_l", &"thigh_r", &"shin_r", &"foot_r",
]

@export var clip_name := ""
@export var fps := 60.0
@export var frames := 0
@export var loop := false
@export var rot := PackedFloat32Array()        ## frames * BONES.size() * 4 (quat xyzw)
@export var root_rot := PackedFloat32Array()   ## frames * 4: pelvis rotation in the root frame
@export var root_off := PackedVector3Array()   ## pelvis offset from its rest position, root frame
@export var root_pos := PackedVector3Array()   ## root position in clip space (y = 0)
@export var root_yaw := PackedFloat32Array()   ## root heading in clip space (facing -Z = 0)
@export var foot_l := PackedVector3Array()     ## ankle relative to the root, root frame
@export var foot_r := PackedVector3Array()
@export var contact_l := PackedByteArray()   ## foot flat on the ground: lock it here
@export var contact_r := PackedByteArray()
@export var support_l := PackedByteArray()   ## heel or toe on the ground (incl. heel strike, toe-off)
@export var support_r := PackedByteArray()
@export var speed := 0.0                       ## average ground speed (m/s)
@export var turn := 0.0                        ## total heading change over the clip (rad)
@export var touchdown_l := -1                  ## frame of the first left-foot touchdown (cycles)
@export var cycle_frames := 0                  ## frames per gait cycle (a clip may hold several)


func length() -> float:
	return frames / fps


## One gait cycle (left touchdown to the next), which may be shorter than the clip.
func cycle_length() -> float:
	return (cycle_frames if cycle_frames > 0 else frames) / fps


## Seconds from time t until this foot's flat contact ends (0 if it isn't planted).
func contact_left(side: StringName, t: float) -> float:
	var c := contact_l if side == &"l" else contact_r
	# Nearest frame, as sample() picks contacts.
	var f := int(fposmod(round(t * fps), frames)) if loop else clampi(int(round(t * fps)), 0, frames - 1)
	var k := 0
	while k < frames and c[(f + k) % frames if loop else mini(f + k, frames - 1)] == 1:
		k += 1
		if not loop and f + k >= frames:
			break
	return k / fps


## Pose at time t (seconds; wrapped for loops, clamped otherwise), interpolated between frames.
## Returns {bones, root_rot, root_offset, feet: {l, r} (root frame), contact: {l, r},
## velocity (root frame, m/s), turn_rate (rad/s)}.
func sample(t: float) -> Dictionary:
	var f := t * fps
	if loop:
		f = fposmod(f, frames)
	else:
		f = clampf(f, 0.0, frames - 1.001)
	var i0 := int(f)
	var i1 := (i0 + 1) % frames if loop else mini(i0 + 1, frames - 1)
	var u := f - i0
	var bones := {}
	var n := BONES.size()
	for b in n:
		bones[BONES[b]] = _q(rot, (i0 * n + b) * 4).slerp(_q(rot, (i1 * n + b) * 4), u)
	var w0 := i0
	var w1 := i1
	# Root motion between neighbouring frames, in the root frame.
	var dp: Vector3 = root_pos[w1] - root_pos[w0]
	if loop and w1 < w0:
		dp = root_pos[w1] + (root_pos[frames - 1] - root_pos[0]) * (float(frames) / (frames - 1)) - root_pos[w0]
	var yaw := lerp_angle(root_yaw[w0], root_yaw[w1], u)
	var vel := Basis(Vector3.UP, -yaw) * dp * fps
	var dyaw := wrapf(root_yaw[w1] - root_yaw[w0], -PI, PI) * fps
	return {
		"bones": bones,
		"root_rot": _q(root_rot, w0 * 4).slerp(_q(root_rot, w1 * 4), u),
		"root_offset": (root_off[w0] as Vector3).lerp(root_off[w1], u),
		"feet": {&"l": (foot_l[w0] as Vector3).lerp(foot_l[w1], u), &"r": (foot_r[w0] as Vector3).lerp(foot_r[w1], u)},
		"contact": {&"l": (contact_l[w0] if u < 0.5 else contact_l[w1]) == 1, &"r": (contact_r[w0] if u < 0.5 else contact_r[w1]) == 1},
		"velocity": vel,
		"turn_rate": dyaw,
	}


static func _q(a: PackedFloat32Array, o: int) -> Quaternion:
	return Quaternion(a[o], a[o + 1], a[o + 2], a[o + 3])
