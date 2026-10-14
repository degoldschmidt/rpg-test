class_name MocapFixture
extends RefCounted
## Synthetic stand-in for Mixamo FBX exports (CI has no Mixamo files): a Mixamo-named skeleton
## in centimetres under a 0.01-scaled "Armature" node, facing +Z, in a T-pose, with arbitrary
## bone axes (random rest rotations, like real rigs have), and mocap-like clips whose feet are
## really planted (legs solved with IK against planted foot positions).

const BONES := [   # name, parent, rest position (cm, world)
	["Hips", "", Vector3(0, 100, 0)],
	["Spine", "Hips", Vector3(0, 110, 0)],
	["Spine1", "Spine", Vector3(0, 122, 0)],
	["Spine2", "Spine1", Vector3(0, 135, 0)],
	["Neck", "Spine2", Vector3(0, 150, 0)],
	["Head", "Neck", Vector3(0, 158, 0)],
	["HeadTop_End", "Head", Vector3(0, 178, 0)],
	["LeftShoulder", "Spine2", Vector3(5, 145, 0)],
	["LeftArm", "LeftShoulder", Vector3(17, 145, 0)],
	["LeftForeArm", "LeftArm", Vector3(45, 145, 0)],
	["LeftHand", "LeftForeArm", Vector3(70, 145, 0)],
	["LeftHandMiddle1", "LeftHand", Vector3(79, 145, 0)],
	["RightShoulder", "Spine2", Vector3(-5, 145, 0)],
	["RightArm", "RightShoulder", Vector3(-17, 145, 0)],
	["RightForeArm", "RightArm", Vector3(-45, 145, 0)],
	["RightHand", "RightForeArm", Vector3(-70, 145, 0)],
	["RightHandMiddle1", "RightHand", Vector3(-79, 145, 0)],
	["LeftUpLeg", "Hips", Vector3(9, 93, 0)],
	["LeftLeg", "LeftUpLeg", Vector3(9, 50, 0)],
	["LeftFoot", "LeftLeg", Vector3(9, 8, 0)],
	["LeftToeBase", "LeftFoot", Vector3(9, 1, 13)],
	["RightUpLeg", "Hips", Vector3(-9, 93, 0)],
	["RightLeg", "RightUpLeg", Vector3(-9, 50, 0)],
	["RightFoot", "RightLeg", Vector3(-9, 8, 0)],
	["RightToeBase", "RightFoot", Vector3(-9, 1, 13)],
]


## A scene shaped like Godot's import of a Mixamo FBX: Armature (scale 0.01) / Skeleton3D, plus
## an AnimationPlayer with one animation. kind: "walk", "run", "idle".
static func make_scene(kind: String, seed := 1) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var root := Node3D.new()
	root.name = kind
	var arm := Node3D.new()
	arm.name = "Armature"
	arm.scale = Vector3.ONE * 0.01
	root.add_child(arm)
	var sk := Skeleton3D.new()
	sk.name = "Skeleton3D"
	arm.add_child(sk)
	var world_rest := {}   # name -> Basis (random bone axes)
	var idx := {}
	for b in BONES:
		var basis := Basis(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized(), rng.randf_range(-PI, PI))
		world_rest[b[0]] = basis
		var bi := sk.get_bone_count()
		sk.add_bone("mixamorig_" + b[0])
		idx[b[0]] = bi
		if b[1] != "":
			sk.set_bone_parent(bi, idx[b[1]])
	for b in BONES:
		sk.set_bone_rest(idx[b[0]], _local(b, world_rest, Basis(), {}))
	var anim := Animation.new()
	var fps := 60.0
	var spec: Dictionary = {"walk": {"v": 130.0, "T": 1.0, "duty": 0.58, "drop": 9.0, "lift": 9.0},
		"run": {"v": 350.0, "T": 0.68, "duty": 0.36, "drop": 7.0, "lift": 30.0},
		"idle": {"v": 0.0, "T": 3.0, "duty": 1.0, "drop": 1.0, "lift": 0.0}}[kind]
	var T: float = spec.T
	anim.length = T
	anim.loop_mode = Animation.LOOP_LINEAR
	var tracks := {}
	for b in BONES:
		var path := NodePath("Armature/Skeleton3D:mixamorig_" + b[0])
		var tr := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(tr, path)
		tracks[b[0]] = tr
	var hips_pos_tr := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(hips_pos_tr, NodePath("Armature/Skeleton3D:mixamorig_Hips"))
	var nframes := int(round(T * fps))
	for f in nframes + 1:
		var t := f / fps
		var pose := _pose(spec, t)
		var delta: Dictionary = pose.delta
		var world_now := {}
		for b in BONES:
			world_now[b[0]] = (delta.get(b[0], Basis()) as Basis) * (world_rest[b[0]] as Basis)
		for b in BONES:
			var p := b[1] as String
			var lb: Basis = (world_now[p] as Basis).inverse() * (world_now[b[0]] as Basis) if p != "" else world_now[b[0]]
			anim.rotation_track_insert_key(tracks[b[0]], t, lb.get_rotation_quaternion())
		anim.position_track_insert_key(hips_pos_tr, t, pose.hips)
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	var lib := AnimationLibrary.new()
	lib.add_animation("mixamo_com", anim)
	ap.add_animation_library("", lib)
	root.add_child(ap)
	return root


static func _local(b: Array, world_rest: Dictionary, _d: Basis, _x: Dictionary) -> Transform3D:
	var wb: Basis = world_rest[b[0]]
	if b[1] == "":
		return Transform3D(wb, b[2])
	var parent: Array = []
	for c in BONES:
		if c[0] == b[1]:
			parent = c
	var pb: Basis = world_rest[b[1]]
	return Transform3D(pb.inverse() * wb, pb.inverse() * ((b[2] as Vector3) - (parent[2] as Vector3)))


## Source-frame pose at time t: hips position (cm) and per-bone world rotation deltas from rest.
static func _pose(sp: Dictionary, t: float) -> Dictionary:
	var v: float = sp.v
	var T: float = sp.T
	var duty: float = sp.duty
	var ph := fposmod(t / T, 1.0)
	var hips := Vector3(0, 100.0 - float(sp.drop) + 1.5 * cos(TAU * 2.0 * ph), v * t)
	var delta := {}
	var stride := v * T
	for side in [["Left", 0.0, 1.0], ["Right", 0.5, -1.0]]:
		var sph := fposmod(ph - float(side[1]), 1.0)   # 0 = touchdown
		var x: float = 9.0 * float(side[2])
		# Touchdown time of the current/last step and where that foot is planted.
		var cyc := floorf((t / T) - float(side[1]))
		var td := (cyc + float(side[1])) * T
		var land_z := v * td + v * duty * T * 0.5   # under the hips at mid-stance
		var ankle: Vector3
		if sph < duty:
			ankle = Vector3(x, 8.0, land_z)
		else:
			var u := (sph - duty) / (1.0 - duty)
			var e := u * u * (3.0 - 2.0 * u)
			ankle = Vector3(x, 8.0 + float(sp.lift) * sin(PI * u), lerpf(land_z, land_z + stride, e))
		var hip := hips + Vector3(x, -7.0, 0)
		var dirs := _leg_ik(hip, ankle, 43.0, 42.0)
		delta[side[0] + "UpLeg"] = _arc(Vector3.DOWN, dirs[0])
		delta[side[0] + "Leg"] = _arc(Vector3.DOWN, dirs[1])
		# Arms down from the T-pose, swinging against the legs.
		# At this foot's touchdown its leg is forward, so this arm is back (contralateral).
		var arm_fwd := -cos(TAU * sph) * (0.35 if v < 200.0 else 0.7) * (0.0 if v == 0.0 else 1.0)
		var a := Vector3(0.12 * float(side[2]), -1.0, arm_fwd).normalized()
		var fa := (a + Vector3(0, 0, 0.25 if v < 200.0 else 1.0)).normalized()
		var rest_dir := Vector3(float(side[2]), 0, 0)
		delta[side[0] + "Arm"] = _arc(rest_dir, a)
		delta[side[0] + "ForeArm"] = _arc(rest_dir, fa)
		delta[side[0] + "Hand"] = _arc(rest_dir, fa)
	return {"hips": hips, "delta": delta}


## Hip -> knee and knee -> ankle directions for a leg reaching `ankle`, knee bending forward (+Z).
static func _leg_ik(hip: Vector3, ankle: Vector3, l1: float, l2: float) -> Array:
	var d := ankle - hip
	var dist := clampf(d.length(), 1.0, l1 + l2 - 0.01)
	var dir := d.normalized()
	var a := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var pole := Vector3(0, 0, 1) - dir * dir.z
	pole = pole.normalized()
	var knee := hip + dir * a + pole * h
	var tip := hip + dir * dist
	return [(knee - hip).normalized(), (tip - knee).normalized()]


static func _arc(from: Vector3, to: Vector3) -> Basis:
	return Basis(Quaternion(from.normalized(), to.normalized()))
