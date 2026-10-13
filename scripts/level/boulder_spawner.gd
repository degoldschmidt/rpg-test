class_name BoulderSpawner
extends Node3D
## Periodically drops heavy boulders that roll down whatever is below.

@export var interval := 5.0
@export var radius := 0.9
@export var mass := 150.0
@export var lifetime := 20.0

var _t := 2.0


func _physics_process(dt: float) -> void:
	_t += dt
	if _t >= interval:
		_t = 0.0
		_spawn()


func _spawn() -> void:
	var b := RigidBody3D.new()
	b.mass = mass
	b.collision_layer = InputSetup.LAYER_PROPS
	b.collision_mask = InputSetup.LAYER_WORLD | InputSetup.LAYER_PUPPET | InputSetup.LAYER_PROPS | InputSetup.LAYER_HAZARDS | InputSetup.LAYER_DETAIL
	b.angular_damp = 0.1
	var mat := PhysicsMaterial.new()
	mat.friction = 0.9
	mat.rough = true
	b.physics_material_override = mat
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = radius
	cs.shape = sh
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 10
	m.rings = 6
	mi.mesh = m
	mi.material_override = LevelUtil.mat(Color(0.5, 0.48, 0.45))
	b.add_child(mi)
	add_child(b)
	b.global_position = global_position
	get_tree().create_timer(lifetime, false, true).timeout.connect(b.queue_free)
