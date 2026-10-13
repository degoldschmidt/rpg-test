class_name RagdollRig
extends Node3D
## Active-ragdoll puppet built from BoneDefs: RigidBody3D segments + Generic6DOFJoint3D.
## Each tick the controller passes a root transform and a pose; the rig computes target
## transforms via forward kinematics and each bone drives itself toward its target,
## scaled by the global `muscle` and a per-bone `weakness` that drops on impacts.

## Drive tuning ("mostly tight").
var pos_gain := 18.0
var rot_gain := 22.0
var lin_blend := 0.3
var ang_blend := 0.45

var muscle := 1.0
var limb_hit_threshold := 60.0
var weakness_recovery := 1.6   ## per second back to full strength

var defs: Array[BoneDef] = []
var bones: Dictionary = {}      ## StringName -> PuppetBone
var _weak: Dictionary = {}      ## StringName -> 0..1 (1 = full strength)
var _prev_target: Dictionary = {}
var _hit_accum := 0.0
var _has_prev := false


func build(root: Transform3D, body_color: Color) -> void:
	defs = BoneDef.default_humanoid(body_color)
	var by_name := {}
	for d in defs:
		by_name[d.name] = d
		var b := PuppetBone.new()
		b.name = String(d.name)
		b.rig = self
		b.def = d
		b.mass = d.mass
		b.collision_layer = InputSetup.LAYER_PUPPET
		b.collision_mask = InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS | InputSetup.LAYER_HAZARDS
		b.contact_monitor = true
		b.max_contacts_reported = 4
		b.linear_damp = 0.05
		b.angular_damp = 0.8
		b.can_sleep = false
		var mat := PhysicsMaterial.new()
		mat.friction = 0.9
		mat.bounce = 0.05
		b.physics_material_override = mat
		var cs := CollisionShape3D.new()
		var mi := MeshInstance3D.new()
		var vis := StandardMaterial3D.new()
		vis.albedo_color = d.color
		vis.roughness = 0.7
		match d.shape:
			BoneDef.Shape.CAPSULE:
				var sh := CapsuleShape3D.new()
				sh.radius = d.size.x
				sh.height = d.size.y
				cs.shape = sh
				var m := CapsuleMesh.new()
				m.radius = d.size.x
				m.height = d.size.y
				mi.mesh = m
			BoneDef.Shape.BOX:
				var sh := BoxShape3D.new()
				sh.size = d.size
				cs.shape = sh
				var m := BoxMesh.new()
				m.size = d.size
				mi.mesh = m
			BoneDef.Shape.SPHERE:
				var sh := SphereShape3D.new()
				sh.radius = d.size.x
				cs.shape = sh
				var m := SphereMesh.new()
				m.radius = d.size.x
				m.height = d.size.x * 2.0
				mi.mesh = m
		mi.material_override = vis
		b.add_child(cs)
		b.add_child(mi)
		if d.name == &"head":
			_add_face(b, d.size.x)
		add_child(b)
		b.global_transform = root * Transform3D(Basis(), d.center)
		bones[d.name] = b
		_weak[d.name] = 1.0

	for d in defs:
		if d.parent == &"":
			continue
		var j := Generic6DOFJoint3D.new()
		j.name = "joint_" + String(d.name)
		add_child(j)
		j.global_transform = root * Transform3D(Basis(), d.pivot)
		# Generic6DOFJoint3D measures angles with the opposite sign to the pose
		# convention (body B relative to A), so the limits are mirrored here.
		for axis in 3:
			_set_angular(j, axis, -d.limit_max[axis], -d.limit_min[axis])
		j.node_a = j.get_path_to(bones[d.parent])
		j.node_b = j.get_path_to(bones[d.name])
	_has_prev = false


func _set_angular(j: Generic6DOFJoint3D, axis: int, lo: float, hi: float) -> void:
	match axis:
		0:
			j.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
			j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)
		1:
			j.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
			j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)
		2:
			j.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
			j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)


func _add_face(head: Node3D, r: float) -> void:
	# A nose and visor so the facing direction reads at a glance.
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.1, 0.1, 0.12)
	var visor := MeshInstance3D.new()
	var vm := BoxMesh.new()
	vm.size = Vector3(r * 1.5, r * 0.35, r * 0.4)
	visor.mesh = vm
	visor.material_override = dark
	visor.position = Vector3(0, r * 0.15, -r * 0.85)
	head.add_child(visor)
	var nose := MeshInstance3D.new()
	var nm := BoxMesh.new()
	nm.size = Vector3(r * 0.25, r * 0.35, r * 0.4)
	nose.mesh = nm
	nose.material_override = visor.material_override
	nose.position = Vector3(0, -r * 0.25, -r * 0.95)
	head.add_child(nose)


## Called every physics tick by the controller.
func step(dt: float, root: Transform3D, root_velocity: Vector3, pose: Dictionary) -> void:
	var targets := compute_targets(root, pose)
	for d in defs:
		var b: PuppetBone = bones[d.name]
		var t: Transform3D = targets[d.name]
		var tv := root_velocity
		if _has_prev:
			var anim_v: Vector3 = (t.origin - (_prev_target[d.name] as Transform3D).origin) / dt
			tv = anim_v.limit_length(root_velocity.length() + 12.0)
		b.target = t
		b.target_velocity = tv
		_weak[d.name] = minf(1.0, _weak[d.name] + weakness_recovery * dt)
		b.drive = muscle * d.stiffness * _weak[d.name]
	_prev_target = targets
	_has_prev = true


func compute_targets(root: Transform3D, pose: Dictionary) -> Dictionary:
	var rots: Dictionary = pose.get("bones", {})
	var root_rot: Quaternion = pose.get("root_rot", Quaternion.IDENTITY)
	var root_off: Vector3 = pose.get("root_offset", Vector3.ZERO)
	var out := {}
	var by_name := {}
	for d in defs:
		by_name[d.name] = d
		if d.parent == &"":
			out[d.name] = Transform3D(root.basis * Basis(root_rot), root * (d.center + root_off))
			continue
		var pd: BoneDef = by_name[d.parent]
		var pt: Transform3D = out[d.parent]
		var pivot_w := pt.origin + pt.basis * (d.pivot - pd.center)
		var basis := pt.basis * Basis(rots.get(d.name, Quaternion.IDENTITY) as Quaternion)
		out[d.name] = Transform3D(basis, pivot_w + basis * (d.center - d.pivot))
	return out


func report_hit(bone: PuppetBone, strength: float) -> void:
	_hit_accum += strength
	if strength > limb_hit_threshold:
		# Partial ragdoll: the struck limb (and its parent a little) goes limp briefly.
		_weak[bone.def.name] = 0.05
		if bone.def.parent != &"":
			_weak[bone.def.parent] = minf(_weak[bone.def.parent], 0.4)


## Returns the summed hit strength since the last call.
func consume_hit() -> float:
	var h := _hit_accum
	_hit_accum = 0.0
	return h


func weaken(bone_name: StringName, amount: float) -> void:
	if _weak.has(bone_name):
		_weak[bone_name] = clampf(amount, 0.0, 1.0)


func pelvis() -> PuppetBone:
	return bones[&"pelvis"]


func add_velocity(dv: Vector3, point: Vector3, falloff := 1.5) -> void:
	for b: PuppetBone in bones.values():
		var k := 1.0 / (1.0 + b.global_position.distance_to(point) * falloff)
		b.linear_velocity += dv * (0.5 + 0.5 * k)


## Snap the whole puppet to its rest pose at `root` with zero velocity.
func teleport(root: Transform3D) -> void:
	for d in defs:
		var b: PuppetBone = bones[d.name]
		b.global_transform = root * Transform3D(Basis(), d.center)
		b.linear_velocity = Vector3.ZERO
		b.angular_velocity = Vector3.ZERO
		_weak[d.name] = 1.0
	_has_prev = false
	_hit_accum = 0.0


func has_invalid_state() -> bool:
	for b: PuppetBone in bones.values():
		var o := b.global_position
		if is_nan(o.x) or is_nan(o.y) or is_nan(o.z) or o.length() > 100000.0:
			return true
	return false
