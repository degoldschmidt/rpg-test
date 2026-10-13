class_name SwingingLog
extends Node3D
## Pendulum log hazard. Kinematic, so it never loses energy and hits hard.

@export var rope_length := 5.5
@export var amplitude := 1.0     ## radians
@export var period := 3.2
@export var log_length := 4.0
@export var log_radius := 0.45

var body: AnimatableBody3D
var _t := 0.0


func _ready() -> void:
	body = AnimatableBody3D.new()
	body.sync_to_physics = true
	body.collision_layer = InputSetup.LAYER_HAZARDS
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = log_radius
	sh.height = log_length
	cs.shape = sh
	cs.rotation = Vector3(0, 0, PI * 0.5)
	cs.position = Vector3(0, -rope_length, 0)
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = log_radius
	m.bottom_radius = log_radius
	m.height = log_length
	mi.mesh = m
	mi.rotation = cs.rotation
	mi.position = cs.position
	mi.material_override = LevelUtil.mat(Color(0.45, 0.28, 0.14))
	body.add_child(mi)
	for x in [-log_length * 0.4, log_length * 0.4]:
		var rope := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(0.05, rope_length, 0.05)
		rope.mesh = rm
		rope.position = Vector3(x, -rope_length * 0.5, 0)
		rope.material_override = LevelUtil.mat(Color(0.8, 0.75, 0.6))
		body.add_child(rope)
	add_child(body)


func _physics_process(dt: float) -> void:
	_t += dt
	body.transform = Transform3D(Basis(Vector3.RIGHT, amplitude * sin(TAU * _t / period)), Vector3.ZERO)
