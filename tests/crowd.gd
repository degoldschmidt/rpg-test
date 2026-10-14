extends SceneTree
## Crowd stress test: the player runs through 100 wandering NPCs (full active-ragdoll characters
## with LOD). Running into them shoves, staggers or knocks them down.
##
## 1) Measure (headless, real CPU time per 60 fps frame = 2 physics ticks + AI + animation + skin):
##    godot --headless --fixed-fps 60 --path . -s tests/crowd.gd -- --measure --timeline=crowd.json [--npcs=100]
## 2) Video of the same deterministic run, overlaying the measured simulation FPS per frame:
##    godot --rendering-driver opengl3 --resolution 1280x720 --write-movie crowd.avi --fixed-fps 60 \
##      --path . -s tests/crowd.gd -- --timeline=crowd.json
## 3) Live, in real time with real rendering (e.g. on your own machine), showing actual FPS:
##    godot --path . -s tests/crowd.gd -- --live [--no-vsync]
## (tools/crowd_mac.sh wraps all three for macOS.)

const PLAYER_SCENE := preload("res://scenes/player.tscn")
var NPCS := 100
const SPACING := 2.6
const DURATION := 22.0   # seconds of game time

var main: Node3D
var player: PlayerController
var cam: CameraRig
var npcs: Array[PlayerController] = []
var measure := false
var live := false
var no_vsync := false
var timeline_path := ""
var timeline: Array = []      ## measure: [ms, full, kinematic, proxy, ragdolls] per frame
var overlay: Label
var center := Vector3.ZERO
var waypoints: Array[Vector3] = []
var _wp := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--measure":
			measure = true
		elif a == "--live":
			live = true
		elif a == "--no-vsync":
			no_vsync = true
		elif a.begins_with("--npcs="):
			NPCS = int(a.trim_prefix("--npcs="))
		elif a.begins_with("--timeline="):
			timeline_path = a.trim_prefix("--timeline=")
	_run()


func _run() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await physics_frame
	player = main.player
	player.use_external_input = true
	cam = main.camera_rig
	main.hud.get_child(0).visible = false   # stats (its FPS line is the render speed)
	main.hud.get_child(1).visible = false   # controls help
	_spawn_crowd()
	_build_overlay()
	if not measure and timeline_path != "":
		timeline = JSON.parse_string(FileAccess.get_file_as_string(timeline_path))

	player.teleport(center + Vector3(0, 0, 26), 0.0)
	cam.yaw = 0.0
	cam.pitch = -0.32
	cam.arm.spring_length = 7.5
	waypoints = [center + Vector3(0, 0, -24), center + Vector3(16, 0, -8), center + Vector3(-18, 0, 6),
		center + Vector3(6, 0, 20)]

	if live:
		await _run_live()
		quit()
		return
	var frames := int(DURATION * 60.0)
	if measure:
		PlayerController.profile = true
		PlayerController.prof = {}
		PlayerController.profile_usec = 0
	var last := Time.get_ticks_usec()
	for f in frames:
		_drive(f / 60.0)
		await process_frame
		var now := Time.get_ticks_usec()
		if measure:
			var c := _counts()
			timeline.append([(now - last) / 1000.0, c[0], c[1], c[2], c[3]])
		else:
			_show(f)
		last = now
	if measure:
		_report()
	quit()


## Real time, real rendering: what you actually get on this machine (vsync caps the FPS at the
## display refresh unless --no-vsync).
func _run_live() -> void:
	if no_vsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var start := Time.get_ticks_usec()
	var last := start
	var recent: Array[float] = []
	while (Time.get_ticks_usec() - start) / 1e6 < DURATION:
		_drive((Time.get_ticks_usec() - start) / 1e6)
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - last) / 1000.0
		last = now
		var c := _counts()
		timeline.append([ms, c[0], c[1], c[2], c[3]])
		recent.append(ms)
		if recent.size() > 30:
			recent.pop_front()
		var avg: float = recent.reduce(func(a, x): return a + x, 0.0) / recent.size()
		overlay.text = "%d FPS  (%.1f ms / frame) — live: rendering + simulation%s\n100 NPCs — full %d / kinematic %d / proxy %d — ragdolls %d\n%s, %s" % [
			roundi(1000.0 / avg), avg, "" if no_vsync else " (vsync on: capped at display refresh)",
			c[0], c[1], c[2], c[3], OS.get_name(), RenderingServer.get_video_adapter_name()]
		overlay.modulate = Color(0.6, 1.0, 0.6) if avg <= 1000.0 / 60.0 else Color(1.0, 0.75, 0.5)
	print("Live run on %s / %s / %s (%d threads):" % [OS.get_name(), OS.get_processor_name(),
		RenderingServer.get_video_adapter_name(), OS.get_processor_count()])
	_report()


func _spawn_crowd() -> void:
	center = main.markers.open + Vector3(0, 0, -30)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var side := int(ceil(sqrt(NPCS)))
	for i in NPCS:
		var gx := (i % side) - (side - 1) * 0.5
		var gz := (i / side) - (side - 1) * 0.5
		var pos := center + Vector3(gx * SPACING + rng.randf_range(-0.5, 0.5), 0, gz * SPACING + rng.randf_range(-0.5, 0.5))
		var d: PlayerController = PLAYER_SCENE.instantiate()
		d.name = "Npc%03d" % i
		d.use_external_input = true
		d.lod_enabled = true
		var h := rng.randf()
		d.body_color = Color.from_hsv(h, 0.5, 0.7)
		d.skin_color = Color.from_hsv(h, 0.25, 0.75)
		d.position = pos
		d.rotation.y = rng.randf_range(0.0, TAU)
		main.add_child(d)
		var brain := DummyBrain.new()
		brain.mode = DummyBrain.Mode.WANDER
		brain.wander_seed = 1000 + i
		brain.wander_radius = 2.0
		d.add_child(brain)
		npcs.append(d)


## Scripted player: wait, then run through the crowd along a few waypoints.
func _drive(t: float) -> void:
	cam.yaw = lerp_angle(cam.yaw, player.facing_yaw, 0.04)
	if t < 1.5 or _wp >= waypoints.size():
		player.external_input = {}
		return
	var to := waypoints[_wp] - player.global_position
	to.y = 0.0
	if to.length() < 2.0:
		_wp += 1
		return
	var local := Basis(Vector3.UP, -cam.yaw) * to.normalized()
	player.external_input = {"move": Vector2(local.x, local.z), "run": true}


func _counts() -> Array:
	var c := [0, 0, 0, 0]
	for n in npcs:
		c[n.rig.lod] += 1
		if n.state == PlayerController.State.RAGDOLL:
			c[3] += 1
	return c


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	overlay = Label.new()
	overlay.position = Vector2(18, 14)
	overlay.add_theme_font_size_override("font_size", 24)
	overlay.add_theme_color_override("font_outline_color", Color.BLACK)
	overlay.add_theme_constant_override("outline_size", 7)
	layer.add_child(overlay)
	root.add_child(layer)


func _show(f: int) -> void:
	if f >= timeline.size():
		return
	# Smooth over the last 30 frames (0.5 s), like an in-game FPS counter.
	var a := maxi(0, f - 29)
	var ms := 0.0
	for i in range(a, f + 1):
		ms += float(timeline[i][0])
	ms /= float(f + 1 - a)
	var c := _counts()  # live from this run; the timing comes from the measured run
	overlay.text = "Simulation: %d FPS  (%.1f ms / frame)\n100 NPCs — full %d / kinematic %d / proxy %d — ragdolls %d\nCPU only, measured headless on a 4-core 2.1 GHz cloud VM (no GPU here)" % [
		roundi(1000.0 / ms), ms, c[0], c[1], c[2], c[3]]
	overlay.modulate = Color(0.6, 1.0, 0.6) if ms <= 1000.0 / 60.0 else Color(1.0, 0.75, 0.5)


func _report() -> void:
	var ms: Array = timeline.map(func(r): return float(r[0]))
	ms = ms.slice(30)  # skip startup
	var sorted := ms.duplicate()
	sorted.sort()
	var avg: float = ms.reduce(func(acc, x): return acc + x, 0.0) / ms.size()
	var p99: float = sorted[int(sorted.size() * 0.99)]
	var worst: float = sorted[-1]
	var over := ms.filter(func(x): return x > 1000.0 / 60.0).size()
	var max_rag: int = timeline.map(func(r): return int(r[4])).max()
	var avg_tiers := [0.0, 0.0, 0.0]
	for r in timeline:
		for k in 3:
			avg_tiers[k] += float(r[k + 1]) / timeline.size()
	var parts := []
	for k in PlayerController.prof:
		parts.append("%s %.2f" % [k, PlayerController.prof[k] / 1000.0 / timeline.size()])
	print("CROWD ms/frame by section: controller total %.2f | %s" % [PlayerController.profile_usec / 1000.0 / timeline.size(), ", ".join(parts)])
	print("CROWD tiers avg full %.1f / kinematic %.1f / proxy %.1f" % avg_tiers)
	print("CROWD avg %.2f ms (%.0f FPS) | 99th pct %.2f ms (%.0f FPS) | worst %.2f ms | frames over 16.7 ms: %d of %d | max simultaneous ragdolls %d" % [
		avg, 1000.0 / avg, p99, 1000.0 / p99, worst, over, ms.size(), max_rag])
	if timeline_path != "":
		var fa := FileAccess.open(timeline_path, FileAccess.WRITE)
		fa.store_string(JSON.stringify(timeline))
