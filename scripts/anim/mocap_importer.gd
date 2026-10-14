class_name MocapImporter
extends RefCounted
## Turns Mixamo-style mocap (an FBX imported by Godot, or any scene with a Skeleton3D and an
## Animation using Mixamo bone names) into MocapClips for the puppet.
##
## Retargeting works on world-space bone directions, so it doesn't depend on the source rig's
## bone axes or rest pose (Mixamo's T-pose vs the puppet's arms-down rest):
##   P_puppet(t) = D(t) * Align,  D(t) = W_src(t) * W_src_rest^-1
## where Align turns the puppet segment's rest frame onto the source bone's rest frame (both
## built from the bone direction and a reference axis). Positions scale by leg length.

const PROFILE := {   # puppet bone -> [source bone, source child for its direction, reference axis]
	&"pelvis": ["Hips", "Spine", "fwd"],
	&"spine": ["Spine1", "Spine2", "fwd"],
	&"chest": ["Spine2", "Neck", "fwd"],
	&"head": ["Head", "HeadTop_End", "fwd"],
	&"upper_arm_l": ["LeftArm", "LeftForeArm", "fwd"],
	&"forearm_l": ["LeftForeArm", "LeftHand", "fwd"],
	&"hand_l": ["LeftHand", "LeftHandMiddle1", "fwd"],
	&"upper_arm_r": ["RightArm", "RightForeArm", "fwd"],
	&"forearm_r": ["RightForeArm", "RightHand", "fwd"],
	&"hand_r": ["RightHand", "RightHandMiddle1", "fwd"],
	&"thigh_l": ["LeftUpLeg", "LeftLeg", "fwd"],
	&"shin_l": ["LeftLeg", "LeftFoot", "fwd"],
	&"foot_l": ["LeftFoot", "LeftToeBase", "right"],
	&"thigh_r": ["RightUpLeg", "RightLeg", "fwd"],
	&"shin_r": ["RightLeg", "RightFoot", "fwd"],
	&"foot_r": ["RightFoot", "RightToeBase", "right"],
}
const PARENT := {
	&"spine": &"pelvis", &"chest": &"spine", &"head": &"chest",
	&"upper_arm_l": &"chest", &"forearm_l": &"upper_arm_l", &"hand_l": &"forearm_l",
	&"upper_arm_r": &"chest", &"forearm_r": &"upper_arm_r", &"hand_r": &"forearm_r",
	&"thigh_l": &"pelvis", &"shin_l": &"thigh_l", &"foot_l": &"shin_l",
	&"thigh_r": &"pelvis", &"shin_r": &"thigh_r", &"foot_r": &"shin_r",
}
## Mixamo characters face +Z with their left at +X; the puppet faces -Z with its left at -X.
const SRC_TO_RIG := Basis(Vector3.UP, PI)
const FPS := 60.0
const CACHE_DIR := "user://mocap_cache"
const LOOP_HINTS := ["idle", "walk", "jog", "run", "sprint"]
const ONE_SHOT_HINTS := ["start", "stop", "turn", "to ", "stairs", "wall", "climb", "jump"]


## "mixamorig:LeftArm", "mixamorig_LeftArm", "mixamorig1:LeftArm" -> "LeftArm".
static func bone_key(n: String) -> String:
	var i := n.rfind(":")
	if i >= 0:
		return n.substr(i + 1)
	var lower := n.to_lower()
	if lower.begins_with("mixamorig"):
		var j := n.find("_")
		if j >= 0:
			return n.substr(j + 1)
	return n


static func is_loop_name(clip_name: String) -> bool:
	var n := clip_name.to_lower()
	for h: String in ONE_SHOT_HINTS:
		if h in n:
			return false
	for h: String in LOOP_HINTS:
		if h in n:
			return true
	return false


## Every clip in `dir` (FBX / glTF / scenes), keyed by file base name. Cached per file.
static func load_library(dir: String) -> Dictionary:
	var out := {}
	var d := DirAccess.open(dir)
	if d == null:
		return out
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	for f in d.get_files():
		var ext := f.get_extension().to_lower()
		if not ext in ["fbx", "glb", "gltf", "tscn", "scn"]:
			continue
		var path := dir.path_join(f)
		var key := f.get_basename()
		var cache := CACHE_DIR.path_join("%s_%d.res" % [key.validate_filename(), FileAccess.get_modified_time(path)])
		var clip: MocapClip = null
		if FileAccess.file_exists(cache):
			clip = load(cache) as MocapClip
		if clip == null:
			var ps := load(path) as PackedScene
			if ps == null:
				push_warning("MocapImporter: can't load %s (run the editor import once: godot --headless --import)" % path)
				continue
			var inst := ps.instantiate()
			clip = import_scene(inst, key, is_loop_name(key))
			inst.free()
			if clip:
				ResourceSaver.save(clip, cache)
		if clip:
			out[key] = clip
	return out


## Retargets the first animation found in `scene` (not in the tree) onto the puppet.
static func import_scene(scene: Node, clip_name: String, loop: bool) -> MocapClip:
	var sk: Skeleton3D = scene if scene is Skeleton3D else null
	if sk == null:
		var found := scene.find_children("*", "Skeleton3D", true, false)
		if found.is_empty():
			push_warning("MocapImporter: no Skeleton3D in " + clip_name)
			return null
		sk = found[0]
	var ap: AnimationPlayer = null
	var aps := scene.find_children("*", "AnimationPlayer", true, false)
	if not aps.is_empty():
		ap = aps[0]
	if ap == null or ap.get_animation_list().is_empty():
		push_warning("MocapImporter: no animation in " + clip_name)
		return null
	var anim := ap.get_animation(ap.get_animation_list()[0])
	return import_animation(sk, anim, _node_to_scene(sk, scene), clip_name, loop)


static func _node_to_scene(n: Node, scene: Node) -> Transform3D:
	var t := Transform3D()
	var cur := n
	while cur != null and cur != scene:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


## Core retarget: `skel_xf` places the skeleton in the source scene (FBX unit scale etc.).
static func import_animation(sk: Skeleton3D, anim: Animation, skel_xf: Transform3D, clip_name: String,
		loop: bool) -> MocapClip:
	var nb := sk.get_bone_count()
	var key_to_bone := {}
	for b in nb:
		key_to_bone[bone_key(sk.get_bone_name(b))] = b
	for pb: StringName in PROFILE:
		if not key_to_bone.has(PROFILE[pb][0]):
			push_warning("MocapImporter: %s has no bone %s" % [clip_name, PROFILE[pb][0]])
			return null
	# Tracks per bone.
	var rot_track := {}
	var pos_track := {}
	for tr in anim.get_track_count():
		var path := anim.track_get_path(tr)
		if path.get_subname_count() == 0:
			continue
		var key := bone_key(String(path.get_subname(0)))
		if not key_to_bone.has(key):
			continue
		var b: int = key_to_bone[key]
		match anim.track_get_type(tr):
			Animation.TYPE_ROTATION_3D:
				rot_track[b] = tr
			Animation.TYPE_POSITION_3D:
				pos_track[b] = tr

	var to_rig := Transform3D(SRC_TO_RIG, Vector3.ZERO) * skel_xf
	var rig_rot := SRC_TO_RIG * skel_xf.basis.orthonormalized()
	# Rest pose (world, rig frame).
	var rest_local: Array[Transform3D] = []
	for b in nb:
		rest_local.append(sk.get_bone_rest(b))
	var rest_g := _globals(sk, rest_local)
	var rest_pos := func(k: String) -> Vector3:
		return to_rig * rest_g[key_to_bone[k]].origin
	# Scale source positions to the puppet by leg length.
	var defs := {}
	for d in BoneDef.default_humanoid(Color.WHITE):
		defs[d.name] = d
	var pup_leg: float = (defs[&"shin_l"].pivot - defs[&"thigh_l"].pivot).length() + (defs[&"foot_l"].pivot - defs[&"shin_l"].pivot).length()
	var src_leg: float = (rest_pos.call("LeftLeg") - rest_pos.call("LeftUpLeg")).length() + (rest_pos.call("LeftFoot") - rest_pos.call("LeftLeg")).length()
	var s := pup_leg / maxf(src_leg, 1e-4)
	var hips_rest: Vector3 = rest_pos.call("Hips") * s

	# Align: puppet rest segment frame -> source rest bone frame.
	var align := {}
	var src_bone := {}
	for pb: StringName in PROFILE:
		var spec: Array = PROFILE[pb]
		var b: int = key_to_bone[spec[0]]
		src_bone[pb] = b
		var ref := Vector3.FORWARD if spec[2] == "fwd" else Vector3.RIGHT
		var child_key: String = spec[1]
		var sdir: Vector3
		if key_to_bone.has(child_key):
			sdir = rest_pos.call(child_key) - rest_pos.call(spec[0])
		else:
			sdir = rig_rot * rest_g[b].basis * Vector3.UP
		align[pb] = _frame(sdir, ref) * _frame(_puppet_dir(defs, pb), ref).inverse()

	var length := anim.length
	var n := maxi(int(round(length * FPS)), 2)
	if loop:
		n -= 1   # cycles repeat their first pose at the end
	var world_rot: Array = []   # per frame: Dictionary puppet bone -> Basis (rig frame)
	var hips: PackedVector3Array = []
	var pose_local: Array[Transform3D] = rest_local.duplicate()
	for f in n:
		var t := minf(f / FPS, length)
		for b in nb:
			var lt := rest_local[b]
			var q := lt.basis.get_rotation_quaternion()
			var o := lt.origin
			if rot_track.has(b):
				q = anim.rotation_track_interpolate(rot_track[b], t)
			if pos_track.has(b):
				o = anim.position_track_interpolate(pos_track[b], t)
			pose_local[b] = Transform3D(Basis(q), o)
		var g := _globals(sk, pose_local)
		var wr := {}
		for pb: StringName in PROFILE:
			var b: int = src_bone[pb]
			var d := (rig_rot * g[b].basis.orthonormalized()) * (rig_rot * rest_g[b].basis.orthonormalized()).inverse()
			wr[pb] = d * (align[pb] as Basis)
		world_rot.append(wr)
		hips.append(to_rig * g[key_to_bone["Hips"]].origin * s)

	# Root: hips on the ground, smoothed over ~0.4 s; heading from the hips' forward direction.
	var win := int(0.2 * FPS)
	var progress := hips[n - 1] - hips[0] if loop else Vector3.ZERO
	if loop:
		progress *= float(n) / (n - 1)
	var root_pos := PackedVector3Array()
	var fwd_raw: Array[Vector3] = []
	for f in n:
		var fw: Vector3 = (world_rot[f][&"pelvis"] as Basis) * (align[&"pelvis"] as Basis).inverse() * Vector3.FORWARD
		fw.y = 0.0
		fwd_raw.append(fw.normalized() if fw.length() > 0.01 else Vector3.FORWARD)
	var root_yaw := PackedFloat32Array()
	for f in n:
		var acc := Vector3.ZERO
		var fa := Vector3.ZERO
		var cnt := 0
		for k in range(f - win, f + win + 1):
			var idx := k
			var shift := Vector3.ZERO
			if loop:
				idx = posmod(k, n)
				shift = progress * floorf(float(k) / n)
			else:
				idx = clampi(k, 0, n - 1)
			acc += hips[idx] + shift
			fa += fwd_raw[idx]
			cnt += 1
		acc /= cnt
		root_pos.append(Vector3(acc.x, 0.0, acc.z))
		root_yaw.append(atan2(-fa.x, -fa.z))

	var clip := MocapClip.new()
	clip.clip_name = clip_name
	clip.fps = FPS
	clip.frames = n
	clip.loop = loop
	clip.root_pos = root_pos
	clip.root_yaw = root_yaw
	var nbones := MocapClip.BONES.size()
	clip.rot.resize(n * nbones * 4)
	clip.root_rot.resize(n * 4)
	var ankles := {&"l": PackedVector3Array(), &"r": PackedVector3Array()}
	var soles := {&"l": [], &"r": []}   # per frame [heel, toe] in clip space
	for f in n:
		var wr: Dictionary = world_rot[f]
		var yb := Basis(Vector3.UP, root_yaw[f])
		var pel_q := (yb.inverse() * (wr[&"pelvis"] as Basis)).get_rotation_quaternion()
		_put(clip.root_rot, f * 4, pel_q)
		for i in nbones:
			var pb: StringName = MocapClip.BONES[i]
			var rel := ((wr[PARENT[pb]] as Basis).inverse() * (wr[pb] as Basis)).get_rotation_quaternion()
			_put(clip.rot, (f * nbones + i) * 4, rel)
		var off := yb.inverse() * (hips[f] - root_pos[f]) - Vector3(0, hips_rest.y, 0)
		clip.root_off.append(off)
		# Puppet FK for the ankles (the puppet's own leg proportions).
		var pel_xf := Transform3D(wr[&"pelvis"], root_pos[f] + yb * ((defs[&"pelvis"] as BoneDef).center + off))
		for sd: StringName in [&"l", &"r"]:
			var ank := _ankle(defs, wr, pel_xf, sd)
			ankles[sd].append(ank)
			var fb: Basis = wr[StringName("foot_" + sd)]
			soles[sd].append([ank + fb * FootPlanner.HEEL, ank + fb * FootPlanner.TOE])
	# Feet relative to the root, and contacts. Support: the heel or the toe is on the ground (low)
	# and nearly still in clip space (heel strike and toe-off count). Contact (where the foot gets
	# locked): the ankle itself is down and still, i.e. the foot is flat; around heel strike and
	# toe-off the clip's own heel/toe roll plays unlocked.
	for sd: StringName in [&"l", &"r"]:
		var a: PackedVector3Array = ankles[sd]
		var so: Array = soles[sd]
		var lo := INF
		var alo := INF
		for hs: Array in so:
			lo = minf(lo, minf((hs[0] as Vector3).y, (hs[1] as Vector3).y))
		for p in a:
			alo = minf(alo, p.y)
		var flat := PackedByteArray()
		flat.resize(n)
		var c := PackedByteArray()
		c.resize(n)
		for f in n:
			var nf2 := (f + 1) % n if loop else mini(f + 1, n - 1)
			var pf2 := (f - 1 + n) % n if loop else maxi(f - 1, 0)
			var span2 := 2 if loop or (f > 0 and f < n - 1) else 1
			var da := a[nf2] - a[pf2]
			var still := (loop and (f == 0 or f == n - 1)) or Vector2(da.x, da.z).length() * FPS / span2 < 0.35
			flat[f] = 1 if a[f].y < alo + 0.03 and still else 0
		for f in n:
			var nf := (f + 1) % n if loop else mini(f + 1, n - 1)
			var pf := (f - 1 + n) % n if loop else maxi(f - 1, 0)
			var span := 2 if loop or (f > 0 and f < n - 1) else 1
			var wraps := loop and (f == 0 or f == n - 1)   # across the wrap the root jumps a cycle
			var on := false
			for k in 2:
				var p: Vector3 = so[f][k]
				if p.y > lo + 0.035:
					continue
				var d: Vector3 = (so[nf][k] as Vector3) - (so[pf][k] as Vector3)
				if wraps or Vector2(d.x, d.z).length() * FPS / span < 0.5:
					on = true
			c[f] = 1 if on else 0
		c = _clean(c, loop)
		flat = _clean(flat, loop)
		for f in n:   # flat only within support
			if c[f] == 0:
				flat[f] = 0
		var rel := PackedVector3Array()
		for f in n:
			rel.append(Basis(Vector3.UP, -root_yaw[f]) * (a[f] - root_pos[f]))
		if sd == &"l":
			clip.foot_l = rel
			clip.contact_l = flat
			clip.support_l = c
		else:
			clip.foot_r = rel
			clip.contact_r = flat
			clip.support_r = c
	var dist := 0.0
	for f in range(1, n):
		dist += (root_pos[f] - root_pos[f - 1]).length()
	clip.speed = dist / maxf((n - 1) / FPS, 1e-3)
	clip.turn = 0.0
	for f in range(1, n):
		clip.turn += wrapf(root_yaw[f] - root_yaw[f - 1], -PI, PI)
	# Left touchdowns (support starting): the first one anchors the cycle phase, their spacing is
	# the cycle length (cycles may hold several strides).
	var tds: Array[int] = []
	for f in n:
		var pf := (f - 1 + n) % n if loop else f - 1
		if clip.support_l[f] == 1 and (pf < 0 or clip.support_l[pf] == 0):
			tds.append(f)
	if not tds.is_empty():
		clip.touchdown_l = tds[0]
	clip.cycle_frames = n
	if tds.size() >= 2:
		var gaps: Array[int] = []
		for i in range(1, tds.size()):
			gaps.append(tds[i] - tds[i - 1])
		gaps.sort()
		clip.cycle_frames = gaps[gaps.size() / 2]
	return clip


## Removes contact blips shorter than 4 frames (both ways).
static func _clean(c: PackedByteArray, loop: bool) -> PackedByteArray:
	var n := c.size()
	var out := c.duplicate()
	for pass_v in [1, 0]:
		var f := 0
		while f < n:
			if out[f] != pass_v:
				f += 1
				continue
			var e := f
			while e < n and out[e] == pass_v:
				e += 1
			var touches_end := loop and (f == 0 or e == n)
			if e - f < 4 and not touches_end:
				for k in range(f, e):
					out[k] = 1 - pass_v
			f = e
	return out


static func _ankle(defs: Dictionary, wr: Dictionary, pel_xf: Transform3D, sd: StringName) -> Vector3:
	var pel: BoneDef = defs[&"pelvis"]
	var th: BoneDef = defs[StringName("thigh_" + sd)]
	var sh: BoneDef = defs[StringName("shin_" + sd)]
	var ft: BoneDef = defs[StringName("foot_" + sd)]
	var hip := pel_xf.origin + pel_xf.basis * (th.pivot - pel.center)
	var knee := hip + (wr[StringName("thigh_" + sd)] as Basis) * (sh.pivot - th.pivot)
	return knee + (wr[StringName("shin_" + sd)] as Basis) * (ft.pivot - sh.pivot)


static func _puppet_dir(defs: Dictionary, pb: StringName) -> Vector3:
	var d: BoneDef = defs[pb]
	var child := {
		&"pelvis": &"spine", &"spine": &"chest", &"chest": &"head",
		&"upper_arm_l": &"forearm_l", &"forearm_l": &"hand_l", &"upper_arm_r": &"forearm_r", &"forearm_r": &"hand_r",
		&"thigh_l": &"shin_l", &"shin_l": &"foot_l", &"thigh_r": &"shin_r", &"shin_r": &"foot_r",
	}
	if child.has(pb):
		return (defs[child[pb]] as BoneDef).pivot - d.pivot
	return d.center - d.pivot


## Orthonormal frame with +Y along `dir` and +Z as close as possible to `ref`.
static func _frame(dir: Vector3, ref: Vector3) -> Basis:
	var y := dir.normalized()
	var z := ref - y * ref.dot(y)
	if z.length() < 0.1:
		z = Vector3.UP - y * y.dot(Vector3.UP)
	z = z.normalized()
	var x := y.cross(z)
	return Basis(x, y, z)


static func _globals(sk: Skeleton3D, local: Array[Transform3D]) -> Array[Transform3D]:
	var n := sk.get_bone_count()
	var g: Array[Transform3D] = []
	g.resize(n)
	var done := PackedByteArray()
	done.resize(n)
	for b in n:
		_global_of(sk, local, g, done, b)
	return g


static func _global_of(sk: Skeleton3D, local: Array[Transform3D], g: Array[Transform3D], done: PackedByteArray, b: int) -> Transform3D:
	if done[b]:
		return g[b]
	var p := sk.get_bone_parent(b)
	g[b] = local[b] if p < 0 else _global_of(sk, local, g, done, p) * local[b]
	done[b] = 1
	return g[b]


static func _put(a: PackedFloat32Array, o: int, q: Quaternion) -> void:
	a[o] = q.x
	a[o + 1] = q.y
	a[o + 2] = q.z
	a[o + 3] = q.w
