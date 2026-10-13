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

## Foot IK: feet are placed on the ground under them, the pelvis drops for the lower foot.
const IK_MASK := InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS | InputSetup.LAYER_DETAIL
var ik_probe_up := 0.6      ## highest step a foot will reach up to
var ik_max_drop := 0.4      ## deepest a foot / the pelvis will reach down
var ik_smoothing := 18.0    ## 1/s, hides pops at step edges

var defs: Array[BoneDef] = []
var bones: Dictionary = {}      ## StringName -> PuppetBone
var _weak: Dictionary = {}      ## StringName -> 0..1 (1 = full strength)
var _prev_target: Dictionary = {}
var _hit_accum := 0.0
var _has_prev := false
var _def: Dictionary = {}       ## StringName -> BoneDef
var _ik_delta := {&"l": 0.0, &"r": 0.0}
var _ik_normal := {&"l": Vector3.UP, &"r": Vector3.UP}


func build(root: Transform3D, body_color: Color) -> void:
	defs = BoneDef.default_humanoid(body_color)
	var by_name := {}
	for d in defs:
		by_name[d.name] = d
		_def[d.name] = d
		var b := PuppetBone.new()
		b.name = String(d.name)
		b.rig = self
		b.def = d
		b.mass = d.mass
		b.collision_layer = InputSetup.LAYER_PUPPET
		b.collision_mask = InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS | InputSetup.LAYER_HAZARDS | InputSetup.LAYER_DETAIL
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
	var targets := compute_targets(root, pose, dt)
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


## Pose -> world targets: forward kinematics, then foot IK when the pose asks for it.
## dt = 0 snaps the IK smoothing.
func compute_targets(root: Transform3D, pose: Dictionary, dt := 0.0) -> Dictionary:
	var out := _fk(root, pose, 0.0)
	var w: float = pose.get("foot_ik", 0.0)
	var k := 1.0 if dt <= 0.0 else 1.0 - exp(-ik_smoothing * dt)
	if w <= 0.001 or not is_inside_tree():
		for s in _ik_delta:
			_ik_delta[s] = lerpf(_ik_delta[s], 0.0, k)
			_ik_normal[s] = (_ik_normal[s] as Vector3).lerp(Vector3.UP, k).normalized()
		return out
	return _foot_ik(out, root, pose, w, k)


func _fk(root: Transform3D, pose: Dictionary, pelvis_drop: float) -> Dictionary:
	var rots: Dictionary = pose.get("bones", {})
	var root_rot: Quaternion = pose.get("root_rot", Quaternion.IDENTITY)
	var root_off: Vector3 = pose.get("root_offset", Vector3.ZERO) + Vector3.UP * pelvis_drop
	var out := {}
	for d in defs:
		if d.parent == &"":
			out[d.name] = Transform3D(root.basis * Basis(root_rot), root * (d.center + root_off))
			continue
		var pd: BoneDef = _def[d.parent]
		var pt: Transform3D = out[d.parent]
		var pivot_w := pt.origin + pt.basis * (d.pivot - pd.center)
		var basis := pt.basis * Basis(rots.get(d.name, Quaternion.IDENTITY) as Quaternion)
		out[d.name] = Transform3D(basis, pivot_w + basis * (d.center - d.pivot))
	return out


## World position of a bone's joint pivot within a target set.
func _pivot(out: Dictionary, bone: StringName) -> Vector3:
	var d: BoneDef = _def[bone]
	var t: Transform3D = out[bone]
	return t.origin + t.basis * (d.pivot - d.center)


func _foot_ik(out: Dictionary, root: Transform3D, pose: Dictionary, w: float, k: float) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var floor_y := root.origin.y
	var ankles := {}
	for s: StringName in [&"l", &"r"]:
		var ankle := _pivot(out, StringName("foot_" + s))
		ankles[s] = ankle
		var q := PhysicsRayQueryParameters3D.create(Vector3(ankle.x, floor_y + ik_probe_up, ankle.z),
			Vector3(ankle.x, floor_y - ik_max_drop, ankle.z), IK_MASK)
		var hit := space.intersect_ray(q)
		var d := 0.0
		var n := Vector3.UP
		if hit and (hit.normal as Vector3).y > 0.5:
			d = (hit.position as Vector3).y - floor_y
			n = hit.normal
		_ik_delta[s] = lerpf(_ik_delta[s], d, k)
		_ik_normal[s] = (_ik_normal[s] as Vector3).lerp(n, k).normalized()

	var drop := minf(0.0, minf(_ik_delta[&"l"], _ik_delta[&"r"])) * w
	if drop < -0.001:
		out = _fk(root, pose, drop)
	for s: StringName in [&"l", &"r"]:
		var target: Vector3 = ankles[s] + Vector3.UP * (_ik_delta[s] as float) * w
		var tilt := Quaternion.IDENTITY.slerp(Quaternion(Vector3.UP, _ik_normal[s]), w)
		_solve_leg(out, s, target, tilt, root.basis * Vector3.FORWARD)
	return out


## Analytic two-bone IK: thigh + shin reach `target` (ankle), keeping the knee's bend plane.
func _solve_leg(out: Dictionary, side: StringName, target: Vector3, foot_tilt: Quaternion, fwd: Vector3) -> void:
	var thigh := StringName("thigh_" + side)
	var shin := StringName("shin_" + side)
	var foot := StringName("foot_" + side)
	var dth: BoneDef = _def[thigh]
	var dsh: BoneDef = _def[shin]
	var dft: BoneDef = _def[foot]
	var hip := _pivot(out, thigh)
	var knee := _pivot(out, shin)
	var ankle := _pivot(out, foot)
	var l1 := (dsh.pivot - dth.pivot).length()
	var l2 := (dft.pivot - dsh.pivot).length()

	var to_t := target - hip
	var dist := clampf(to_t.length(), 0.05, (l1 + l2) * 0.999)
	var dir := to_t.normalized()
	var pole := (knee - hip) - dir * (knee - hip).dot(dir)
	if pole.length() < 0.01:
		pole = fwd - dir * fwd.dot(dir)  # straight leg: knees bend forward
	pole = pole.normalized()
	var a := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var new_knee := hip + dir * a + pole * h
	var new_ankle := hip + dir * dist

	var th: Transform3D = out[thigh]
	var sh: Transform3D = out[shin]
	var ft: Transform3D = out[foot]
	var b_th := Basis(Quaternion((knee - hip).normalized(), (new_knee - hip).normalized())) * th.basis
	var b_sh := Basis(Quaternion((ankle - knee).normalized(), (new_ankle - new_knee).normalized())) * sh.basis
	var b_ft := Basis(foot_tilt) * ft.basis
	out[thigh] = Transform3D(b_th, hip + b_th * (dth.center - dth.pivot))
	out[shin] = Transform3D(b_sh, new_knee + b_sh * (dsh.center - dsh.pivot))
	out[foot] = Transform3D(b_ft, new_ankle + b_ft * (dft.center - dft.pivot))


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
	for side in _ik_delta:
		_ik_delta[side] = 0.0
		_ik_normal[side] = Vector3.UP


func has_invalid_state() -> bool:
	for b: PuppetBone in bones.values():
		var o := b.global_position
		if is_nan(o.x) or is_nan(o.y) or is_nan(o.z) or o.length() > 100000.0:
			return true
	return false
