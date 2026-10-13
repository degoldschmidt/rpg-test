class_name Bumper
extends Node3D
## Spring bumper: launches the player into a ragdoll.

@export var radius := 0.9
@export var launch_speed := 11.0
@export var up_ratio := 0.7

var _cooldown := 0.0


func _ready() -> void:
	var cyl := StaticBody3D.new()
	cyl.collision_layer = InputSetup.LAYER_WORLD
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = radius
	sh.height = 1.0
	cs.shape = sh
	cs.position.y = 0.5
	cyl.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = 1.0
	mi.mesh = m
	mi.position.y = 0.5
	mi.material_override = LevelUtil.mat(Color(0.9, 0.15, 0.2))
	cyl.add_child(mi)
	add_child(cyl)

	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = InputSetup.LAYER_PROXY
	var acs := CollisionShape3D.new()
	var ash := CylinderShape3D.new()
	ash.radius = radius + 0.35
	ash.height = 1.4
	acs.shape = ash
	acs.position.y = 0.6
	area.add_child(acs)
	add_child(area)
	area.body_entered.connect(_on_body_entered)


func _physics_process(dt: float) -> void:
	_cooldown -= dt


func _on_body_entered(body: Node3D) -> void:
	if _cooldown > 0.0 or not body.has_method("apply_hit"):
		return
	_cooldown = 0.5
	var away := body.global_position - global_position
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else Vector3.FORWARD
	var dv := (away + Vector3.UP * up_ratio).normalized() * launch_speed
	body.apply_hit(dv, global_position + away * radius + Vector3.UP * 0.6)
