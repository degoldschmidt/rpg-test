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
var hit_ignore: Object = null   ## contacts with this body never count as hits (held / pushed object)

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

## Level of detail (see CharacterLOD). FULL simulates; the reduced tiers park the bodies outside
## the physics server and only animate (KINEMATIC every 2nd tick, PROXY_ONLY every 4th).
var lod: int = CharacterLOD.Tier.FULL
var pose_version := 0            ## bumped every step; the skin skips frames when unchanged
var _def: Dictionary = {}       ## StringName -> BoneDef
var _ik_delta := {&"l": 0.0, &"r": 0.0}
var _ik_normal := {&"l": Vector3.UP, &"r": Vector3.UP}
var _leg_len := 0.0
var _show_anim := {}     ## bone -> how much of the animation the skin shows (see display_transform)
const LEG_BONES: Array[StringName] = [&"thigh_l", &"shin_l", &"foot_l", &"thigh_r", &"shin_r", &"foot_r"]
const ARM_BONES: Array[StringName] = [&"upper_arm_l", &"forearm_l", &"hand_l", &"upper_arm_r", &"forearm_r", &"hand_r"]


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
		b.target = b.global_transform
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
	pose_version += 1
	if lod != CharacterLOD.Tier.FULL:
		# No physics and no IK raycasts: FK of the animation, legs placed on the planned feet.
		var kt := _fk(root, pose, 0.0)
		if pose.has("feet"):
			kt = _leg_ik(kt, root, pose)
		for d in defs:
			(bones[d.name] as PuppetBone).target = kt[d.name]  # bodies are parked; the skin reads targets
		_prev_target = kt
		return
	var targets := compute_targets(root, pose, dt)
	# Stepping legs hold their planted feet harder (the joints chain lags behind fast swings).
	var leg_boost := 1.0 + 0.8 * float((pose.get("feet_w", {}) as Dictionary).get(&"l", 0.0))
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
		b.drive = muscle * d.stiffness * _weak[d.name] * (leg_boost if d.name in LEG_BONES else 1.0)
	_prev_target = targets
	_has_prev = true
	var gw: float = (pose.get("feet_w", {}) as Dictionary).get(&"l", 0.0) * muscle
	for d in defs:
		var calm := smoothstep(0.6, 1.0, _weak[d.name])
		var k := 1.0 if d.name in LEG_BONES or d.name == &"pelvis" else (0.8 if d.name in ARM_BONES else 0.5)
		_show_anim[d.name] = gw * calm * k


## Pose -> world targets: forward kinematics, then foot IK when the pose asks for it.
## dt = 0 snaps the IK smoothing.
func compute_targets(root: Transform3D, pose: Dictionary, dt := 0.0) -> Dictionary:
	var out := _fk(root, pose, 0.0)
	if pose.has("feet"):
		out = _leg_ik(out, root, pose)
	var w: float = pose.get("foot_ik", 0.0)
	var k := 1.0 if dt <= 0.0 else 1.0 - exp(-ik_smoothing * dt)
	if w <= 0.001 or not is_inside_tree():
		for s in _ik_delta:
			_ik_delta[s] = lerpf(_ik_delta[s], 0.0, k)
			_ik_normal[s] = (_ik_normal[s] as Vector3).lerp(Vector3.UP, k).normalized()
	else:
		out = _foot_ik(out, root, pose, w, k)
	_hand_ik(out, root, pose)
	return out


## Legs onto the foot planner's ankle targets (see FootPlanner). The pelvis drops when a foot
## would be out of reach (long strides, stepping down), which also gives the walk its natural
## low point at double support.
func _leg_ik(out: Dictionary, root: Transform3D, pose: Dictionary) -> Dictionary:
	var feet: Dictionary = pose.feet
	var fw: Dictionary = pose.get("feet_w", {})
	if _leg_len <= 0.0:
		_leg_len = (_def[&"shin_l"].pivot - _def[&"thigh_l"].pivot).length() \
			+ (_def[&"foot_l"].pivot - _def[&"shin_l"].pivot).length()
	var reach := _leg_len * 0.985
	var drop := 0.0
	for s: StringName in [&"l", &"r"]:
		var w: float = fw.get(s, 0.0)
		if w <= 0.001 or not feet.has(s):
			continue
		var hip := _pivot(out, StringName("thigh_" + s))
		var ankle: Vector3 = (feet[s] as Transform3D).origin
		var h := Vector2(hip.x - ankle.x, hip.z - ankle.z).length()
		drop = maxf(drop, (hip.y - ankle.y - sqrt(maxf(reach * reach - h * h, 0.0))) * w)
	if drop > 0.001:
		# The whole FK chain hangs from the pelvis, so dropping it is a plain translation.
		var shift := root.basis * Vector3.DOWN * minf(drop, 0.35)
		for n: StringName in out:
			var t: Transform3D = out[n]
			out[n] = Transform3D(t.basis, t.origin + shift)
	for s: StringName in [&"l", &"r"]:
		var w: float = fw.get(s, 0.0)
		if w <= 0.001 or not feet.has(s):
			continue
		var foot := StringName("foot_" + s)
		var want: Transform3D = feet[s]
		var fk_basis: Basis = (out[foot] as Transform3D).basis
		var ankle := _pivot(out, foot).lerp(want.origin, w)
		var b := Basis(fk_basis.get_rotation_quaternion().slerp(want.basis.get_rotation_quaternion(), w))
		_solve_two_bone(out, StringName("thigh_" + s), StringName("shin_" + s), foot,
			ankle, Quaternion(b * fk_basis.inverse()), _knee_dir(root, want.basis, s), false,
			not pose.get("fk_knees", false))   # mocap: keep the clip's own knee bend plane
	return out


## Places the hands on world targets (holding / pushing objects), elbows bending down and out.
func _hand_ik(out: Dictionary, root: Transform3D, pose: Dictionary) -> void:
	var w: float = pose.get("hand_ik", 0.0)
	var targets: Dictionary = pose.get("hand_targets", {})
	if w <= 0.001 or targets.is_empty():
		return
	for s: StringName in [&"l", &"r"]:
		if not targets.has(s):
			continue
		var hand := StringName("hand_" + s)
		var fk_wrist := _pivot(out, hand)
		# Targets are palm contact points; the wrist sits a hand-length back toward the shoulder.
		var shoulder := _pivot(out, StringName("upper_arm_" + s))
		var palm: Vector3 = targets[s]
		var wrist := palm + (shoulder - palm).normalized() * 0.07
		var side := -1.0 if s == &"l" else 1.0
		var pole := root.basis * Vector3(side * 0.6, -1.0, 0.2)
		_solve_two_bone(out, StringName("upper_arm_" + s), StringName("forearm_" + s), hand,
			fk_wrist.lerp(wrist, w), Quaternion.IDENTITY, pole, true)


## Flat FK tables built once (hot path: runs for every character every animation tick).
var _fk_names: Array[StringName] = []
var _fk_parent := PackedInt32Array()
var _fk_to_pivot := PackedVector3Array()   ## parent center -> this pivot, in parent frame
var _fk_to_center := PackedVector3Array()  ## this pivot -> this center
var _fk_root_center := Vector3.ZERO


func _build_fk_tables() -> void:
	var index := {}
	for i in defs.size():
		var d := defs[i]
		index[d.name] = i
		_fk_names.append(d.name)
		if d.parent == &"":
			_fk_parent.append(-1)
			_fk_to_pivot.append(Vector3.ZERO)
			_fk_root_center = d.center
		else:
			_fk_parent.append(index[d.parent])
			_fk_to_pivot.append(d.pivot - (_def[d.parent] as BoneDef).center)
		_fk_to_center.append(d.center - d.pivot)


func _fk(root: Transform3D, pose: Dictionary, pelvis_drop: float) -> Dictionary:
	if _fk_names.is_empty():
		_build_fk_tables()
	var rots: Dictionary = pose.get("bones", {})
	var root_rot: Quaternion = pose.get("root_rot", Quaternion.IDENTITY)
	var root_off: Vector3 = pose.get("root_offset", Vector3.ZERO) + Vector3.UP * pelvis_drop
	var out := {}
	var xf: Array[Transform3D] = []
	xf.resize(_fk_names.size())
	for i in _fk_names.size():
		var p := _fk_parent[i]
		var t: Transform3D
		if p < 0:
			t = Transform3D(root.basis * Basis(root_rot), root * (_fk_root_center + root_off))
		else:
			var pt := xf[p]
			var basis := pt.basis * Basis(rots.get(_fk_names[i], Quaternion.IDENTITY) as Quaternion)
			t = Transform3D(basis, pt.origin + pt.basis * _fk_to_pivot[i] + basis * _fk_to_center[i])
		xf[i] = t
		out[_fk_names[i]] = t
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
		_solve_two_bone(out, StringName("thigh_" + s), StringName("shin_" + s), StringName("foot_" + s),
			target, tilt, _knee_dir(root, (out[StringName("foot_" + s)] as Transform3D).basis, s), false, true)
	return out


## Knees bend forward, between where the foot points (toes -Z) and where the body faces (so a
## foot that is still turned from the last heading can't twist the knee), turned slightly out,
## never backwards.
func _knee_dir(root: Transform3D, foot_basis: Basis, s: StringName) -> Vector3:
	var body := root.basis * Vector3.FORWARD
	var fwd := -foot_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() + body if fwd.length_squared() > 0.01 else body
	if fwd.length_squared() < 0.01:
		fwd = body
	var side := -1.0 if s == &"l" else 1.0
	return (fwd.normalized() + (root.basis * Vector3.RIGHT) * side * 0.12).normalized()


## Analytic two-bone IK: upper + lower reach `target` with the end bone's pivot, keeping
## the FK bend plane (or always bending toward `pole_hint` with `force_pole`; legs use it so a
## knee can never fold backwards when the foot is placed ahead of the hip). The end bone either keeps
## its FK world rotation tilted by `end_tilt` (feet) or follows the lower bone (hands).
func _solve_two_bone(out: Dictionary, upper: StringName, lower: StringName, end: StringName,
		target: Vector3, end_tilt: Quaternion, pole_hint: Vector3, end_follows: bool, force_pole := false) -> void:
	var du: BoneDef = _def[upper]
	var dl: BoneDef = _def[lower]
	var de: BoneDef = _def[end]
	var root_p := _pivot(out, upper)
	var mid := _pivot(out, lower)
	var tip := _pivot(out, end)
	var l1 := (dl.pivot - du.pivot).length()
	var l2 := (de.pivot - dl.pivot).length()

	var to_t := target - root_p
	var dist := clampf(to_t.length(), 0.05, (l1 + l2) * 0.999)
	var dir := to_t.normalized()
	var pole := (mid - root_p) - dir * (mid - root_p).dot(dir)
	if force_pole or pole.length() < 0.01:
		pole = pole_hint - dir * pole_hint.dot(dir)
		if pole.length() < 0.05:   # limb pointing along the hint: bend up instead
			pole = Vector3.UP - dir * dir.y
	pole = pole.normalized()
	var a := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var new_mid := root_p + dir * a + pole * h
	var new_tip := root_p + dir * dist

	var tu: Transform3D = out[upper]
	var tl: Transform3D = out[lower]
	var te: Transform3D = out[end]
	var q1 := Quaternion((mid - root_p).normalized(), (new_mid - root_p).normalized())
	var b_u := Basis(q1) * tu.basis
	var lower_fk_dir := (Basis(q1) * (tip - mid)).normalized()
	var q2 := Quaternion(lower_fk_dir, (new_tip - new_mid).normalized())
	var b_l := Basis(q2) * Basis(q1) * tl.basis
	var b_e := Basis(q2) * Basis(q1) * te.basis if end_follows else Basis(end_tilt) * te.basis
	out[upper] = Transform3D(b_u, root_p + b_u * (du.center - du.pivot))
	out[lower] = Transform3D(b_l, new_mid + b_l * (dl.center - dl.pivot))
	out[end] = Transform3D(b_e, new_tip + b_e * (de.center - de.pivot))


## Show the physics capsules (debug) instead of / in addition to the skinned mesh.
func set_bodies_visible(v: bool) -> void:
	for b: PuppetBone in bones.values():
		for c in b.get_children():
			if c is MeshInstance3D:
				(c as MeshInstance3D).visible = v
			for cc in c.get_children():
				if cc is MeshInstance3D:
					(cc as MeshInstance3D).visible = v


func report_hit(bone: PuppetBone, strength: float, other: Object = null) -> void:
	if other != null and other == hit_ignore:
		return
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


## Where a bone is shown: its body, or its animation target while bodies are parked (reduced tiers).
## Fully simulated, a calm character shows its animation for the legs and pelvis (planted feet
## stay planted; the physics chain lags fast steps by a few cm) and half of it for the upper
## body; a weakened (hit) limb shows pure physics, so impacts still wobble.
func display_transform(b: PuppetBone) -> Transform3D:
	if lod != CharacterLOD.Tier.FULL:
		return b.target
	var w: float = _show_anim.get(b.def.name, 0.0)
	if w <= 0.001:
		return b.global_transform
	var p := b.global_transform
	return Transform3D(p.basis.orthonormalized().slerp(b.target.basis.orthonormalized(), w), p.origin.lerp(b.target.origin, w))


func pelvis() -> PuppetBone:
	return bones[&"pelvis"]


func add_velocity(dv: Vector3, point: Vector3, falloff := 1.5) -> void:
	for b: PuppetBone in bones.values():
		var k := 1.0 / (1.0 + b.global_position.distance_to(point) * falloff)
		b.linear_velocity += dv * (0.5 + 0.5 * k)


## Snap the whole puppet to its rest pose at `root` with zero velocity.
## Switch simulation tier. Promotion to FULL hands the bodies back to physics moving with
## `velocity`, so the drive picks up smoothly from the current pose.
func set_lod(tier: int, velocity := Vector3.ZERO) -> void:
	if tier == lod:
		return
	lod = tier
	for b: PuppetBone in bones.values():
		# Proxy-only bodies are taken out of the physics server entirely (no callbacks, no
		# broadphase); contacts are only reported where hits can happen.
		b.process_mode = Node.PROCESS_MODE_INHERIT if tier == CharacterLOD.Tier.FULL else Node.PROCESS_MODE_DISABLED
		b.contact_monitor = tier == CharacterLOD.Tier.FULL
		if tier == CharacterLOD.Tier.FULL:
			b.global_transform = b.target  # bodies were parked while in a reduced tier
		match tier:
			CharacterLOD.Tier.FULL:
				b.collision_layer = InputSetup.LAYER_PUPPET
				b.collision_mask = InputSetup.LAYER_WORLD | InputSetup.LAYER_PROPS | InputSetup.LAYER_HAZARDS | InputSetup.LAYER_DETAIL
				b.freeze = false
				b.linear_velocity = velocity
				b.angular_velocity = Vector3.ZERO
			_:
				b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				b.freeze = true
				b.collision_layer = 0
				b.collision_mask = 0
	_has_prev = false


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
