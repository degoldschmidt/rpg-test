extends SceneTree
## Transition probe: plays the mocap transitions (run turn-around, walk/sprint start, stops,
## standing turns) and traces what the body does through them: the transition and its clip
## time, the body's yaw offset, pelvis height (physical and displayed), how far the locked feet
## sit from the clip's feet. Prints the lowest pelvis per scenario.
## Run: godot --headless --fixed-fps 120 --path . -s tests/transition_probe.gd [-- --trace]

const TICK := 1.0 / 120.0

var main: Node3D
var player: PlayerController
var trace := false


func _initialize() -> void:
	trace = "--trace" in OS.get_cmdline_user_args()
	_run()


func _run() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await physics_frame
	player = main.player
	player.use_external_input = true
	# name, [stick, run, seconds]...
	var scenarios := [
		["run turn-around", [[Vector2(0, -1), true, 2.5], [Vector2(0, 1), true, 1.5]]],
		["stroll start", [[Vector2.ZERO, false, 1.0], [Vector2(0, -0.45), false, 2.0]]],
		["jog start", [[Vector2.ZERO, false, 1.0], [Vector2(0, -1), false, 2.0]]],
		["sprint start", [[Vector2.ZERO, false, 1.0], [Vector2(0, -1), true, 1.5]]],
		["walk stop", [[Vector2(0, -1), false, 2.0], [Vector2.ZERO, false, 2.0]]],
		["stand turn left 90", [[Vector2.ZERO, false, 1.0], [Vector2(-1, 0), false, 0.15], [Vector2.ZERO, false, 2.0]]],
		["stand turn right 90", [[Vector2.ZERO, false, 1.0], [Vector2(1, 0), false, 0.15], [Vector2.ZERO, false, 2.0]]],
		["stand turn 180", [[Vector2.ZERO, false, 1.0], [Vector2(0, 1), false, 0.15], [Vector2.ZERO, false, 2.5]]],
	]
	for sc in scenarios:
		await play(sc[0], sc[1])
	quit()


func play(label: String, steps: Array) -> void:
	player.teleport(main.markers.open + Vector3(0, 0, 40), 0.0)
	player.external_input = {}
	for i in 90:
		await physics_frame
	var loco: LocomotionPlayer = player.pose_gen.loco
	var lo := INF
	var lo_disp := INF
	var seen := {}
	var t := 0.0
	var record := false
	for st in steps:
		player.external_input = {"move": st[0], "run": st[1]}
		record = record or st != steps[0] or steps.size() == 1
		for i in int(float(st[2]) / TICK):
			await physics_frame
			t += TICK
			if loco == null:
				loco = player.pose_gen.loco
				continue
			if loco.transition != &"":
				seen[loco.transition] = true
			if not record:
				continue
			var gy := player.global_position.y
			var ph := player.rig.pelvis().global_position.y - gy
			var pd := player.rig.display_transform(player.rig.pelvis()).origin.y - gy
			lo = minf(lo, ph)
			lo_disp = minf(lo_disp, pd)
			if trace and i % 6 == 0:
				print("  %5.2f %-10s tr_t %.2f w %.2f yaw_off %+.2f | v %.2f | pelvis %.2f disp %.2f | lock_err l %.2f r %.2f | stance l %+.1f r %+.1f" % [
					t, loco.transition, loco._tr_t, loco._tr_w, loco._yaw_off, player.horizontal_speed(), ph, pd,
					(loco.lock_err[&"l"] as Vector3).length(), (loco.lock_err[&"r"] as Vector3).length(),
					loco.stance[&"l"], loco.stance[&"r"]])
	player.external_input = {}
	var yaw_err := 0.0
	if loco:
		for s: StringName in [&"l", &"r"]:
			var f: Vector3 = -(loco.feet[s] as Transform3D).basis.z
			yaw_err = maxf(yaw_err, absf(wrapf(atan2(-f.x, -f.z) - player.facing_yaw, -PI, PI)))
	var pel_f := -player.rig.display_transform(player.rig.pelvis()).basis.z
	var pel_err := absf(wrapf(atan2(-pel_f.x, -pel_f.z) - player.facing_yaw, -PI, PI))
	print("TRANSITION %-20s pelvis min %.2f (shown %.2f) | transitions %s | end: pelvis yaw err %.2f, feet yaw err %.2f" % [
		label, lo, lo_disp, ",".join(seen.keys()), pel_err, yaw_err])
