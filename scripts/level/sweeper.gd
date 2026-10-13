class_name Sweeper
extends Node3D
## Rotating low bar: jump it or get swept off your feet.

@export var arm_length := 9.0
@export var height := 0.45
@export var angular_speed := 1.4

var body: AnimatableBody3D


func _ready() -> void:
	LevelUtil.box(self, Vector3(0.6, 1.0, 0.6), Transform3D(Basis(), Vector3(0, 0.5, 0)), Color(0.3, 0.3, 0.32))
	body = AnimatableBody3D.new()
	body.sync_to_physics = true
	body.collision_layer = InputSetup.LAYER_HAZARDS
	body.collision_mask = 0
	var size := Vector3(arm_length, 0.35, 0.35)
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	cs.position = Vector3(0, height, 0)
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = cs.position
	mi.material_override = LevelUtil.mat(Color(0.9, 0.55, 0.1))
	body.add_child(mi)
	add_child(body)


func _physics_process(dt: float) -> void:
	body.rotate_y(angular_speed * dt)
