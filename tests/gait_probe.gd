extends SceneTree
## Gait quality probe: drives the player at fixed stick inputs on flat ground and measures how
## the feet behave (the displayed puppet feet, i.e. what the skin shows). Per speed:
##   slip       average horizontal speed of a planted foot during flat stance (0 = perfectly planted)
##   clearance  highest the foot body gets above the ground during a step
##   duty       fraction of the cycle each foot is planted
##   cadence    steps per second
##   pelvis     lowest pelvis height (rest: 1.0 m)
## Run: godot --headless --fixed-fps 120 --path . -s tests/gait_probe.gd

const TICK := 1.0 / 120.0

var main: Node3D
var player: PlayerController


func _initialize() -> void:
	_run()


func _run() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await physics_frame
	player = main.player
	player.use_external_input = true
	for spec in [["stroll", 0.45, false], ["walk", 1.0, false], ["run", 1.0, true]]:
		var r: Dictionary = await measure(spec[1], spec[2])
		print("GAIT %-6s speed %.2f m/s | slip %.3f m/s | clearance %.2f m | duty %.2f | cadence %.2f steps/s | pelvis min %.2f m | mocap %.1f" % [
			spec[0], r.speed, r.slip, r.clearance, r.duty, r.cadence, r.pelvis, r.mocap])
	quit()


func measure(stick: float, run: bool) -> Dictionary:
	player.teleport(main.markers.open + Vector3(0, 0, 40), 0.0)
	player.external_input = {}
	for i in 60:
		await physics_frame
	player.external_input = {"move": Vector2(0, -stick), "run": run}
	for i in int(2.5 / TICK):   # reach steady speed
		await physics_frame
	# Whichever drives the legs: mocap clips (LocomotionPlayer) or the procedural FootPlanner.
	var g = player.pose_gen.loco if player.pose_gen._clip_w > 0.5 else player.pose_gen.gait
	var prev := {}
	var slip := 0.0
	var slip_n := 0
	var clear := 0.0
	var speed := 0.0
	var pelvis := INF
	var n := int(3.0 / TICK)
	for i in n:
		await physics_frame
		speed += player.horizontal_speed() / n
		var gy := player.global_position.y
		pelvis = minf(pelvis, player.rig.pelvis().global_position.y - gy)
		for s: StringName in [&"l", &"r"]:
			var p: Vector3 = player.rig.display_transform(player.rig.bones[StringName("foot_" + s)]).origin
			var st: float = g.stance[s]
			if st > 0.2 and st < 0.5 and prev.has(s):
				slip += Vector2(p.x - prev[s].x, p.z - prev[s].z).length() / TICK
				slip_n += 1
			if g.swing[s] >= 0.0:
				clear = maxf(clear, p.y - 0.035 - gy)
			prev[s] = p
	player.external_input = {}
	return {"speed": speed, "slip": slip / maxf(slip_n, 1), "clearance": clear,
		"duty": g.duty if g is FootPlanner else -1.0, "cadence": g.cadence if g is FootPlanner else -1.0, "pelvis": pelvis,
		"mocap": player.pose_gen._clip_w}
