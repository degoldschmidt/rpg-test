class_name CameraRig
extends Node3D
## Third-person orbit camera: mouse / right stick, spring arm against the world.

@export var player: PlayerController
@export var distance := 4.5
@export var mouse_sensitivity := 0.0025
@export var stick_speed := 3.0
@export var follow_sharpness := 10.0

var yaw := 0.0
var pitch := -0.3
var arm: SpringArm3D
var camera: Camera3D


func _ready() -> void:
	top_level = true
	arm = SpringArm3D.new()
	arm.spring_length = distance
	arm.collision_mask = InputSetup.LAYER_WORLD
	arm.margin = 0.2
	var probe := SphereShape3D.new()
	probe.radius = 0.2
	arm.shape = probe
	add_child(arm)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.current = true
	arm.add_child(camera)
	if player:
		yaw = player.facing_yaw
		global_position = player.camera_target()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity


func _process(dt: float) -> void:
	var stick := Input.get_vector("cam_left", "cam_right", "cam_up", "cam_down")
	yaw -= stick.x * stick_speed * dt
	pitch -= stick.y * stick_speed * dt
	pitch = clampf(pitch, -1.3, 0.6)
	rotation = Vector3(pitch, yaw, 0.0)
	if player:
		global_position = global_position.lerp(player.camera_target(), 1.0 - exp(-follow_sharpness * dt))
		player.camera_yaw = yaw
