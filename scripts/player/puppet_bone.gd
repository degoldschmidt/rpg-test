class_name PuppetBone
extends RigidBody3D
## One puppet segment. Drives itself toward its animated target ("muscles")
## and reports impacts from props/hazards back to the rig.

const KINEMATIC_HIT_MASS := 150.0

var rig: RagdollRig
var def: BoneDef
var target := Transform3D()
var target_velocity := Vector3.ZERO
var drive := 1.0   ## 0 = limp ragdoll, 1 = fully follows target


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_scan_contacts(state)
	if drive <= 0.001:
		return
	var lin_k := clampf(drive * rig.lin_blend, 0.0, 1.0)
	var ang_k := clampf(drive * rig.ang_blend, 0.0, 1.0)

	var pos_err := target.origin - state.transform.origin
	var want_lv := target_velocity + pos_err * rig.pos_gain
	state.linear_velocity = state.linear_velocity.lerp(want_lv, lin_k)

	var q_cur := state.transform.basis.get_rotation_quaternion()
	var q_err := (target.basis.get_rotation_quaternion() * q_cur.inverse()).normalized()
	if q_err.w < 0.0:
		q_err = -q_err
	var v := Vector3(q_err.x, q_err.y, q_err.z)
	var s := v.length()
	var rot_err := v * 2.0 if s < 1e-6 else v / s * (2.0 * atan2(s, q_err.w))
	state.angular_velocity = state.angular_velocity.lerp(rot_err * rig.rot_gain, ang_k)


func _scan_contacts(state: PhysicsDirectBodyState3D) -> void:
	for i in state.get_contact_count():
		var other := state.get_contact_collider_object(i)
		var other_mass := 0.0
		if other is RigidBody3D and not other is PuppetBone:
			other_mass = (other as RigidBody3D).mass
		elif other is AnimatableBody3D:
			other_mass = KINEMATIC_HIT_MASS
		else:
			continue  # static world / own body: landings are judged by the controller
		var n := state.get_contact_local_normal(i)
		var rel := state.get_contact_collider_velocity_at_position(i) - state.get_contact_local_velocity_at_position(i)
		var strength := absf(rel.dot(n)) * minf(other_mass, KINEMATIC_HIT_MASS)
		if strength > 1.0:
			rig.report_hit(self, strength, other)
