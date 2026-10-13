extends Node3D
## Builds the greybox test level, spawns the player, camera and HUD.

const PLAYER_SCENE := preload("res://scenes/player.tscn")

## Named spots used by the level and the automated tests.
var markers := {
	"spawn": Vector3(0, 0, 8),
	"open": Vector3(70, 0, 70),          # empty flat area for movement tests
	"platform_2": Vector3(16, 2, 0),
	"platform_5": Vector3(16, 5, -8),
	"platform_10": Vector3(16, 10, -18),
	"tunnel": Vector3(0, 0, -25),
	"ramp_30": Vector3(-19, 1.5, -2 - 1.5 / tan(deg_to_rad(30.0))),
	"stairs": Vector3(-32, 0, -1),
	"log": Vector3(0, 0, 35),
	"sweeper": Vector3(14, 0, 35),
	"bumper": Vector3(-10, 0, 30),
}

var player: PlayerController
var camera_rig: CameraRig
var hud: DebugHud
var level: Node3D


func _ready() -> void:
	InputSetup.ensure_actions()
	level = Node3D.new()
	level.name = "Level"
	add_child(level)
	_build_environment()
	_build_level()

	player = PLAYER_SCENE.instantiate()
	player.position = markers.spawn
	add_child(player)

	camera_rig = CameraRig.new()
	camera_rig.player = player
	add_child(camera_rig)

	hud = DebugHud.new()
	hud.player = player
	add_child(hud)


func _physics_process(_dt: float) -> void:
	if player.global_position.y < -30.0:
		player.reset()


func _build_environment() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.85)
	sky_mat.ground_bottom_color = Color(0.3, 0.3, 0.32)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(-35), 0)
	sun.shadow_enabled = true
	sun.light_energy = 0.9
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)


func _build_level() -> void:
	var L := LevelUtil
	var grey := Color(0.42, 0.43, 0.46)
	var blue := Color(0.3, 0.4, 0.6)
	var green := Color(0.32, 0.52, 0.32)
	var orange := Color(0.75, 0.45, 0.2)

	# Ground: 300 m square, top at y = 0.
	L.box(level, Vector3(300, 1, 300), Transform3D(Basis(), Vector3(0, -0.5, 0)), grey)

	# Ramps of increasing steepness (15/30/45 deg). 45 deg is walkable, barely.
	var x := -14.0
	for deg in [15.0, 30.0, 45.0]:
		var h := 3.0
		var run := h / tan(deg_to_rad(deg))
		L.ramp(level, Vector3(x, 0, -2), Vector3(x, h, -2 - run), 3.0, green)
		L.box(level, Vector3(3, h, 3), Transform3D(Basis(), Vector3(x, h * 0.5, -2 - run - 1.5)), green)
		x -= 5.0

	# Stairs: treads collide only with the puppet / foot IK (detail layer); the capsule
	# rides a smooth invisible ramp through the step nosings (proxy-only layer).
	var sx := -32.0
	for i in 12:
		var top := (i + 1) * 0.2
		L.box(level, Vector3(3, top, 0.35), Transform3D(Basis(), Vector3(sx, top * 0.5, -2 - i * 0.35 - 0.175)), blue,
			true, InputSetup.LAYER_DETAIL if i < 11 else InputSetup.LAYER_WORLD)
	L.ramp(level, Vector3(sx, 0, -2 + 0.35), Vector3(sx, 2.4, -2 - 11 * 0.35), 3.0, blue, false, 0.6,
		InputSetup.LAYER_PROXY_ONLY)
	L.box(level, Vector3(3, 2.4, 3), Transform3D(Basis(), Vector3(sx, 1.2, -2 - 12 * 0.35 - 1.5)), blue)

	# Landing-test platforms (2 / 5 / 10 m) with access ramps running +X.
	for key in ["platform_2", "platform_5", "platform_10"]:
		var p: Vector3 = markers[key]
		L.box(level, Vector3(4, p.y, 4), Transform3D(Basis(), Vector3(p.x, p.y * 0.5, p.z)), orange)
		var run := p.y / tan(deg_to_rad(22.0))
		L.ramp(level, Vector3(p.x + 2 + run, 0, p.z), Vector3(p.x + 2, p.y, p.z), 2.5, orange)

	# Crouch tunnel: ceiling at 1.5 m, too low to stand (1.8 m capsule).
	var t: Vector3 = markers.tunnel
	L.box(level, Vector3(0.4, 2.2, 6), Transform3D(Basis(), t + Vector3(-1.4, 1.1, 0)), blue)
	L.box(level, Vector3(0.4, 2.2, 6), Transform3D(Basis(), t + Vector3(1.4, 1.1, 0)), blue)
	L.box(level, Vector3(3.2, 0.7, 6), Transform3D(Basis(), t + Vector3(0, 1.85, 0)), blue)

	# Jump gaps: 1 m high blocks with 2.5 / 3.5 / 4.5 m gaps.
	var gx := -10.0
	for gap in [0.0, 2.5, 3.5, 4.5]:
		gx += gap
		L.box(level, Vector3(2, 1, 3), Transform3D(Basis(), Vector3(gx, 0.5, 18)), green)
		gx += 2.0

	# Crate pyramid.
	var c0 := Vector3(8, 0, 10)
	var s := 0.7
	for layer in 4:
		for i in 4 - layer:
			LevelUtil.dynamic_box(level, Vector3.ONE * s, c0 + Vector3((i - (3 - layer) * 0.5) * (s + 0.02), s * 0.5 + layer * s, 0), 6.0, orange)

	# Hazards.
	var log := SwingingLog.new()
	log.position = markers.log + Vector3(0, 7, 0)
	level.add_child(log)
	L.box(level, Vector3(0.3, 7.5, 0.3), Transform3D(Basis(), markers.log + Vector3(-2.6, 3.75, 0)), grey)
	L.box(level, Vector3(0.3, 7.5, 0.3), Transform3D(Basis(), markers.log + Vector3(2.6, 3.75, 0)), grey)
	L.box(level, Vector3(5.5, 0.3, 0.3), Transform3D(Basis(), markers.log + Vector3(0, 7.5, 0)), grey)

	var sweeper := Sweeper.new()
	sweeper.position = markers.sweeper
	level.add_child(sweeper)

	var bumper := Bumper.new()
	bumper.position = markers.bumper
	level.add_child(bumper)

	# Boulder ramp: rolls boulders down toward the hazard field.
	var bx := -30.0
	L.ramp(level, Vector3(bx, 0, 34), Vector3(bx, 6, 21), 5.0, grey)
	L.box(level, Vector3(5, 6, 3), Transform3D(Basis(), Vector3(bx, 3, 19.5)), grey)
	L.box(level, Vector3(5, 2, 0.5), Transform3D(Basis(), Vector3(bx, 7, 18.25)), grey)
	var spawner := BoulderSpawner.new()
	spawner.position = Vector3(bx, 7.5, 20.0)
	level.add_child(spawner)
