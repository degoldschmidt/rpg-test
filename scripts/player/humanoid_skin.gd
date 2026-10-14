class_name HumanoidSkin
extends Node3D
## Drives a skinned humanoid (Rigify-style bone names) from the physical puppet.
## Mapped bones take their world rotation from a puppet body; positions are rebuilt down
## the hierarchy from the hips, so the mesh keeps its own proportions and never stretches.
## Limb bones are re-aimed once at setup from the model's A-pose to the puppet's rest pose.

## skeleton bone -> puppet body
const MAP := {
	"spine": &"pelvis", "spine.001": &"spine", "spine.002": &"chest", "spine.003": &"chest",
	"spine.004": &"head", "spine.005": &"head",
	"upper_arm.L": &"upper_arm_l", "forearm.L": &"forearm_l", "hand.L": &"hand_l",
	"upper_arm.R": &"upper_arm_r", "forearm.R": &"forearm_r", "hand.R": &"hand_r",
	"thigh.L": &"thigh_l", "shin.L": &"shin_l", "foot.L": &"foot_l",
	"thigh.R": &"thigh_r", "shin.R": &"shin_r", "foot.R": &"foot_r",
}
## Bones whose rest direction is aligned to their puppet segment (arms are A-posed in the model).
const ALIGN := ["upper_arm", "forearm", "hand", "thigh", "shin"]
## Limb bones whose head sits exactly on the puppet joint pivot, so hands and feet are where the
## physics contacts are (puppet proportions match the model, so this barely stretches the mesh).
const PIN_TO_PIVOT := ["upper_arm", "forearm", "hand", "thigh", "shin", "foot", "spine.004"]
## The model faces +Z with its left side at +X; the puppet faces -Z with its left at -X.
const MODEL_TO_RIG := Basis(Vector3.UP, PI)

@export var model_scene: PackedScene = preload("res://assets/characters/male_base_mesh.glb")
@export var height := 1.8
@export var skin_color := Color(0.62, 0.5, 0.42)

var skeleton: Skeleton3D
var model: Node3D
var _scale := 1.0
var _order: Array[int] = []
var _parent: Array[int] = []
var _rest_local: Array[Transform3D] = []
var _body: Dictionary = {}       ## bone idx -> PuppetBone
var _aligned: Dictionary = {}    ## bone idx -> rig-space rest basis of the bone, aligned to its body
var _pinned: Dictionary = {}     ## bone idx -> pivot offset in the body frame
var _root_offset := Vector3.ZERO ## hips position in the pelvis body frame
var _root_bone := -1
var _world: Array[Transform3D] = []
var _sk: Array[Transform3D] = []   ## skeleton-space globals, reused by children
var _active: Array[int] = []       ## mapped bones + their unmapped ancestors, parents first
var _rig: RagdollRig
var _seen_version := -1
var _material: StandardMaterial3D


func setup(rig: RagdollRig) -> void:
	_rig = rig
	model = model_scene.instantiate()
	add_child(model)
	skeleton = model.find_children("*", "Skeleton3D", true, false)[0]
	var mesh_aabb := AABB()
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mesh_aabb = mi.get_aabb()
		var mat := StandardMaterial3D.new()
		mat.albedo_color = skin_color
		mat.roughness = 0.6
		mi.material_override = mat
		_material = mat
		mi.extra_cull_margin = 2.0
	_scale = height / mesh_aabb.size.y

	var n := skeleton.get_bone_count()
	_parent.resize(n)
	_rest_local.resize(n)
	_world.resize(n)
	var depth := []
	for b in n:
		_parent[b] = skeleton.get_bone_parent(b)
		_rest_local[b] = skeleton.get_bone_rest(b)
		var d := 0
		var p := _parent[b]
		while p >= 0:
			d += 1
			p = skeleton.get_bone_parent(p)
		depth.append(d)
	for b in n:
		_order.append(b)
	_order.sort_custom(func(a, c): return depth[a] < depth[c])

	for b in n:
		var bone_name := skeleton.get_bone_name(b)
		if not MAP.has(bone_name):
			continue
		var body: PuppetBone = rig.bones[MAP[bone_name]]
		_body[b] = body
		var g := skeleton.get_bone_global_rest(b)
		var rest_rig := MODEL_TO_RIG * g.basis.orthonormalized()
		for prefix: String in ALIGN:
			if bone_name.begins_with(prefix):
				var seg := (body.def.center - body.def.pivot).normalized()
				var dir := (rest_rig * Vector3.UP).normalized()
				rest_rig = Basis(Quaternion(dir, seg)) * rest_rig
				break
		_aligned[b] = rest_rig
		for prefix: String in PIN_TO_PIVOT:
			if bone_name.begins_with(prefix):
				_pinned[b] = body.def.pivot - body.def.center
				break
		if _parent[b] < 0:
			_root_bone = b
			_root_offset = MODEL_TO_RIG * (g.origin * _scale) - body.def.center

	# Only mapped bones move; fingers, toes etc. keep their rest pose relative to their parent,
	# so per frame we rebuild just the mapped bones and the ancestors they hang from.
	var needed := {}
	for b in _body:
		var p: int = b
		while p >= 0:
			needed[p] = true
			p = _parent[p]
	for b in _order:
		if needed.has(b):
			_active.append(b)
	_sk.resize(n)


func _process(_dt: float) -> void:
	if skeleton == null:
		return
	# Physics bodies move every tick in FULL; reduced tiers only when the rig stepped.
	if _rig.lod != CharacterLOD.Tier.FULL and _rig.pose_version == _seen_version:
		return
	_seen_version = _rig.pose_version
	var t0 := Time.get_ticks_usec() if PlayerController.profile else 0
	update_pose()
	if PlayerController.profile:
		PlayerController.prof_add("skin", Time.get_ticks_usec() - t0)


func set_skin_color(c: Color) -> void:
	skin_color = c
	if _material:
		_material.albedo_color = c


## Debug tint (F3 shows LOD tiers); Color.WHITE clears it.
func set_tint(c: Color) -> void:
	if _material:
		_material.albedo_color = skin_color * c


## Rebuilds every bone from the current puppet body transforms.
func update_pose() -> void:
	var pelvis: PuppetBone = _body[_root_bone]
	var xs := Transform3D((MODEL_TO_RIG * Basis.from_scale(Vector3.ONE * _scale)), _rig.display_transform(pelvis).origin)
	skeleton.global_transform = xs
	var xs_inv := xs.affine_inverse()
	var rot_inv := MODEL_TO_RIG.inverse()
	for b in _active:
		var p := _parent[b]
		var w := Transform3D()
		if _body.has(b):
			var body: PuppetBone = _body[b]
			var bt := _rig.display_transform(body)
			var bb := bt.basis.orthonormalized()
			w.basis = bb * (_aligned[b] as Basis)
			if p < 0:
				w.origin = bt.origin + bb * _root_offset
			elif _pinned.has(b):
				w.origin = bt * (_pinned[b] as Vector3)
			else:
				w.origin = _world[p].origin + _world[p].basis * (_rest_local[b].origin * _scale)
		elif p >= 0:
			w.basis = _world[p].basis * _rest_local[b].basis
			w.origin = _world[p].origin + _world[p].basis * (_rest_local[b].origin * _scale)
		else:
			w = Transform3D(MODEL_TO_RIG * _rest_local[b].basis, xs * _rest_local[b].origin)
		_world[b] = w
		# Back to skeleton space (unit rotation, origins in model units) as a local pose.
		var sk := Transform3D(rot_inv * w.basis, xs_inv * w.origin)
		_sk[b] = sk
		if not _body.has(b):
			continue  # unmapped ancestor: its pose stays at rest
		var local := sk if p < 0 else _sk[p].affine_inverse() * sk
		skeleton.set_bone_pose_position(b, local.origin)
		skeleton.set_bone_pose_rotation(b, local.basis.get_rotation_quaternion())


## World direction a skeleton bone points (its +Y axis).
func bone_world_direction(bone_name: String) -> Vector3:
	var b := skeleton.find_bone(bone_name)
	return _world[b].basis.y.normalized() if b >= 0 else Vector3.UP


## World position of a skeleton bone head (for tests / attachments).
func bone_world_position(bone_name: String) -> Vector3:
	var b := skeleton.find_bone(bone_name)
	return _world[b].origin if b >= 0 else Vector3.ZERO
