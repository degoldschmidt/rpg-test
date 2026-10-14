extends SceneTree
## Scripted showcase clips for watching the prototype without playing it. Record one with:
##   xvfb-run godot --rendering-driver opengl3 --resolution 1280x720 --write-movie out.avi \
##     --fixed-fps 30 --path . -s tests/showcase.gd -- --clip=combat
## Clips: movement, gait, falls, terrain, ledges, objects, combat, hazards

var main: Node3D
var player: PlayerController
var cam: CameraRig
var caption: Label


func _initialize() -> void:
	_run()


func _run() -> void:
	var clip := "movement"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--clip="):
			clip = a.trim_prefix("--clip=")
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await physics_frame
	player = main.player
	player.use_external_input = true
	cam = main.camera_rig
	main.hud.get_child(1).visible = false  # controls help
	var layer := CanvasLayer.new()
	caption = Label.new()
	caption.anchor_left = 0.0
	caption.anchor_right = 1.0
	caption.anchor_top = 1.0
	caption.anchor_bottom = 1.0
	caption.offset_top = -70
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 30)
	caption.add_theme_color_override("font_outline_color", Color.BLACK)
	caption.add_theme_constant_override("outline_size", 8)
	layer.add_child(caption)
	root.add_child(layer)
	await call("clip_" + clip)
	await secs(0.5)
	quit()


# ------------------------------------------------------------------ helpers

func secs(s: float) -> void:
	for i in int(s * 120.0):
		await physics_frame


func say(text: String) -> void:
	caption.text = text


## Input that moves along a world direction, whatever the camera yaw.
func go(dir: Vector3, extra := {}) -> void:
	var local := Basis(Vector3.UP, -cam.yaw) * dir
	var d := {"move": Vector2(local.x, local.z)}
	d.merge(extra, true)
	player.external_input = d


func idle(extra := {}) -> void:
	player.external_input = extra


func tap(key: String, dir := Vector3.ZERO) -> void:
	go(dir, {key: true})
	await secs(0.05)
	go(dir)


func spot(pos: Vector3, yaw := 0.0, cam_yaw := 0.6, pitch := -0.2, dist := 4.5) -> void:
	player.teleport(pos, yaw)
	cam.yaw = cam_yaw
	cam.pitch = pitch
	cam.arm.spring_length = dist
	cam.global_position = player.camera_target()
	await secs(0.4)


# ------------------------------------------------------------------ clips

func clip_movement() -> void:
	var o: Vector3 = main.markers.open
	await spot(o, 0.0, 0.9)
	say("Walk: speeds up gradually and keeps momentum")
	go(Vector3.FORWARD)
	await secs(2.0)
	idle()
	await secs(1.2)
	say("Run (Shift): slower to build up, wider turns")
	go(Vector3.FORWARD, {"run": true})
	await secs(2.5)
	go(Vector3.RIGHT, {"run": true})
	await secs(1.5)
	say("Hard reverse at speed: skid")
	go(Vector3.LEFT, {"run": true})
	await secs(2.0)
	idle()
	await secs(1.0)
	say("Jump: tap for a hop, hold for full height")
	await tap("jump")
	await secs(1.2)
	go(Vector3.ZERO, {"jump": true})
	await secs(1.3)
	idle()
	await secs(0.6)
	say("Forward roll (Q)")
	await tap("roll", Vector3.FORWARD)
	await secs(1.2)
	say("Run + crouch: slide")
	go(Vector3.FORWARD, {"run": true})
	await secs(2.0)
	go(Vector3.FORWARD, {"run": true, "crouch": true})
	await secs(1.8)
	idle()
	await secs(1.0)


## Side view on the legs: stroll, walk, run, stop, turns.
func clip_gait() -> void:
	var o: Vector3 = main.markers.open + Vector3(0, 0, 30)
	await spot(o, 0.0, PI * 0.5, -0.12, 3.6)
	var plan := [
		["Stroll (half stick): heel strike, planted feet, toe-off", Vector3.FORWARD * 0.45, false, 3.5],
		["Walk (full stick): jog with a flight phase", Vector3.FORWARD, false, 3.0],
		["Run (Shift)", Vector3.FORWARD, true, 3.0],
		["Stop: feet settle under the hips", Vector3.ZERO, false, 2.5],
		["Walk off and turn around", Vector3.FORWARD * 0.6, false, 1.5],
		["", Vector3.BACK * 0.6, false, 2.5],
		["Run, hard turn", Vector3.BACK, true, 1.5],
		["", Vector3.RIGHT, true, 2.0],
		["", Vector3.ZERO, false, 2.0],
	]
	for step in plan:
		if step[0] != "":
			say(step[0])
		for i in int(step[3] * 120.0):
			if step[1] == Vector3.ZERO:
				idle()
			else:
				go(step[1], {"run": step[2]})
			cam.yaw = lerp_angle(cam.yaw, player.facing_yaw + PI * 0.5, 0.05)
			await physics_frame


func clip_falls() -> void:
	var o: Vector3 = main.markers.open
	await spot(o + Vector3(0, 4, 0), 0.0, 1.4, -0.1, 5.0)
	say("4 m drop: stumble")
	await secs(2.5)
	await spot(o + Vector3(0, 10, 0), 0.0, 1.4, -0.1, 5.5)
	say("10 m drop: ragdoll, then get back up")
	await secs(6.0)
	await spot(o + Vector3(0, 10, 0), 0.0, 1.4, -0.1, 5.5)
	say("10 m drop, roll just before landing: rolled out")
	var pressed := false
	for i in int(4.0 * 120):
		if not pressed and player.velocity.y < 0.0 and player.global_position.y < o.y + 3.5:
			go(Vector3.ZERO, {"roll": true})
			pressed = true
		elif pressed:
			idle()
		await physics_frame


func clip_terrain() -> void:
	var st: Vector3 = main.markers.stairs
	await spot(st + Vector3(0, 0, 1.5), 0.0, -1.2, -0.15, 4.0)
	say("Stairs: smooth movement, feet planted on each step (foot IK)")
	go(Vector3.FORWARD)
	await secs(3.2)
	idle()
	await secs(1.0)
	var r: Vector3 = main.markers.ramp_30
	await spot(r + Vector3.UP * 0.05, -PI * 0.5, 0.0, -0.1, 3.5)
	say("Standing across a 30° slope: hips drop, feet tilt to the ground")
	await secs(3.0)
	say("Walking down the slope")
	go(Vector3.BACK)
	await secs(2.5)
	idle()
	await secs(0.8)


func clip_ledges() -> void:
	var mb: Vector3 = main.markers.mantle_block
	await spot(mb + Vector3(0, 0, 4), 0.0, -1.0, -0.15, 4.5)
	say("Running jump at a chest-high ledge: mantle")
	go(Vector3.FORWARD, {"run": true})
	while player.global_position.z - mb.z > 1.3:
		await physics_frame
	await tap("jump", Vector3.FORWARD)
	await secs(1.5)
	idle()
	await secs(0.8)
	var cw: Vector3 = main.markers.climb_wall
	await spot(cw + Vector3(-2, 0, 0.6), 0.0, -1.0, -0.05, 4.5)
	say("Jump at a high ledge: grab and hang")
	go(Vector3.FORWARD, {"jump": true})
	while player.state != PlayerController.State.LEDGE_HANG:
		await physics_frame
	idle()
	await secs(1.5)
	say("Shimmy along the ledge")
	go(Vector3.RIGHT)
	await secs(2.5)
	idle()
	await secs(0.5)
	say("Climb up")
	await tap("jump")
	await secs(2.0)
	say("And again onto the higher ledge")
	go(Vector3.FORWARD, {"jump": true})
	var t := 0.0
	while player.state != PlayerController.State.LEDGE_HANG and player.state != PlayerController.State.CLIMB and t < 2.0:
		await physics_frame
		t += 1.0 / 120.0
	idle()
	await secs(1.0)
	await tap("jump")
	await secs(2.0)


func clip_objects() -> void:
	var sack: RigidBody3D = main.props.sack
	var sp := sack.global_position
	await spot(Vector3(sp.x, 0, sp.z + 0.75), 0.0, 0.9, -0.2, 4.0)
	say("E: lift the 18 kg sack (slows you down)")
	await tap("interact")
	await secs(1.0)
	go(Vector3.BACK)
	await secs(1.5)
	go(Vector3.RIGHT)
	await secs(1.5)
	idle()
	await secs(0.5)
	say("F: throw it")
	await tap("throw")
	await secs(2.0)
	var crate: RigidBody3D = main.props.crate
	var cp := crate.global_position
	await spot(Vector3(cp.x, 0, cp.z + 0.6 + 0.3), 0.0, 0.7, -0.2, 4.5)
	say("E on the 80 kg crate: grab, W pushes")
	await tap("interact")
	await secs(0.5)
	go(Vector3.FORWARD)
	await secs(2.5)
	say("S pulls")
	go(Vector3.BACK)
	await secs(2.5)
	idle()
	await tap("interact")
	await secs(0.5)
	var bl: RigidBody3D = main.props.block
	var bp := bl.global_position
	await spot(Vector3(bp.x, 0, bp.z + 0.75 + 0.3), 0.0, 0.7, -0.2, 4.5)
	say("250 kg block: much slower")
	await tap("interact")
	await secs(0.5)
	go(Vector3.FORWARD)
	await secs(2.5)
	idle()
	await tap("interact")
	await secs(0.5)


func face_dummy(name: String, dist: float, cam_yaw := PI * 0.5 + 0.2) -> PlayerController:
	var d: PlayerController = main.dummies[name]
	d.reset()
	await spot(d.global_position + Vector3(0, 0, -dist), PI, cam_yaw, -0.12, 3.8)
	await secs(0.4)
	return d


func clip_combat() -> void:
	await face_dummy("passive", 1.0)
	say("Punch: the target flinches")
	await tap("punch")
	await secs(1.2)
	say("Three quick punches: stagger")
	for i in 3:
		await tap("punch")
		await secs(0.5)
	await secs(1.2)
	await face_dummy("passive", 1.1)
	say("Kick: stagger and knock-back")
	await tap("kick")
	await secs(2.0)
	await face_dummy("guard", 1.0)
	say("Guarding dummy blocks punches...")
	await secs(0.5)
	await tap("punch")
	await secs(1.2)
	say("...but a kick breaks the guard")
	await tap("kick")
	await secs(2.0)
	var d: PlayerController = await face_dummy("passive", 7.0, PI * 0.5 + 0.6)
	say("Running kick: knockdown, then it gets back up")
	go(Vector3.BACK, {"run": true})
	while d.global_position.distance_to(player.global_position) > 1.9:
		await physics_frame
	go(Vector3.BACK, {"run": true, "kick": true})
	await secs(0.05)
	idle()
	await secs(5.0)
	var sp: PlayerController = main.dummies.sparring
	sp.reset()
	await spot(sp.global_position + Vector3(0, 0, -1.6), PI, PI * 0.5 - 0.3, -0.12, 4.0)
	say("Sparring dummy attacks; holding guard blocks its punches")
	await secs(3.0)
	idle({"guard": true})
	await secs(4.0)
	idle()
	say("Hitting back")
	for i in 3:
		await tap("punch")
		await secs(0.6)
	await tap("kick")
	await secs(2.5)


func clip_hazards() -> void:
	await spot(main.markers.log, 0.0, 1.57, -0.1, 6.0)
	say("Swinging log: full ragdoll")
	await secs(6.0)
	var b: Vector3 = main.markers.bumper
	await spot(b + Vector3(0, 0, 4), 0.0, 1.0, -0.15, 6.0)
	say("Bumper: launched")
	go(Vector3.FORWARD)
	await secs(1.0)
	idle()
	await secs(5.0)
