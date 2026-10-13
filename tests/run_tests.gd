extends SceneTree
## Headless gameplay tests. Run with:
##   godot --headless --fixed-fps 120 --path . -s tests/run_tests.gd
## --fixed-fps 120 makes every frame exactly one physics tick, so results are deterministic.

const TICK := 1.0 / 120.0

var main: Node3D
var player: PlayerController
var cfg: MovementConfig
var _fails: Array[String] = []
var _passes := 0
var _seen: Array = []


func _initialize() -> void:
	_run()


func _run() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await physics_frame
	player = main.player
	cfg = player.config
	player.use_external_input = true
	player.state_changed.connect(func(_o, n): _seen.append(n))

	await test_idle_stability()
	await test_walk_momentum()
	await test_run_momentum()
	await test_skid()
	await test_jump_heights()
	await test_crouch_and_tunnel()
	await test_foot_ik_slope()
	await test_foot_ik_stairs()
	await test_climb_stairs()
	await test_slide()
	await test_roll()
	await test_stumble_landing()
	await test_hard_fall_ragdoll_and_get_up()
	await test_roll_landing_saves()
	await test_swinging_log_knockdown()
	await test_bumper_launch()
	await test_smoke_random_input()

	print("\n==== %d passed, %d failed ====" % [_passes, _fails.size()])
	for f in _fails:
		print("  FAIL: " + f)
	quit(1 if _fails.size() > 0 else 0)


# ------------------------------------------------------------------ helpers

func frames(n: int) -> void:
	for i in n:
		await physics_frame


func seconds(s: float) -> void:
	await frames(int(round(s / TICK)))


func inp(move := Vector2.ZERO, run := false, jump := false, crouch := false, roll := false) -> void:
	player.external_input = {"move": move, "run": run, "jump": jump, "crouch": crouch, "roll": roll}


func place(pos: Vector3, settle := 0.4, yaw := 0.0) -> void:
	inp()
	player.teleport(pos, yaw)
	await seconds(settle)
	_seen.clear()


func check(name: String, ok: bool, detail := "") -> void:
	if ok:
		_passes += 1
		print("  ok   %s %s" % [name, detail])
	else:
		_fails.append("%s %s" % [name, detail])
		print("  FAIL %s %s" % [name, detail])


func pelvis_error() -> float:
	var target := player.global_position + Vector3.UP * 1.0
	return player.rig.pelvis().global_position.distance_to(target)


func wait_state(s: PlayerController.State, timeout: float) -> float:
	var t := 0.0
	while t < timeout:
		if player.state == s:
			return t
		await physics_frame
		t += TICK
	return -1.0


## Height of the foot body center above the ground directly beneath it (rest pose: 0.04).
func foot_clearance(side: String) -> float:
	var foot: Node3D = player.rig.bones[StringName("foot_" + side)]
	var p := foot.global_position
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.5, p + Vector3.DOWN * 1.5,
		InputSetup.LAYER_WORLD | InputSetup.LAYER_DETAIL)
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return p.y - (hit.position as Vector3).y if hit else 99.0


func foot_alignment(side: String) -> float:
	var foot: Node3D = player.rig.bones[StringName("foot_" + side)]
	var p := foot.global_position
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.5, p + Vector3.DOWN * 1.5,
		InputSetup.LAYER_WORLD | InputSetup.LAYER_DETAIL)
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return foot.global_basis.y.normalized().dot(hit.normal) if hit else 0.0


func open() -> Vector3:
	return main.markers.open


# ------------------------------------------------------------------ tests

func test_idle_stability() -> void:
	print("idle stability")
	await place(open(), 1.0)
	var lo := 99.0
	var hi := -99.0
	var head_lo := 99.0
	for i in int(10.0 / TICK):
		await physics_frame
		var y := player.rig.pelvis().global_position.y - player.global_position.y
		lo = minf(lo, y)
		hi = maxf(hi, y)
		head_lo = minf(head_lo, player.rig.bones[&"head"].global_position.y - player.global_position.y)
	check("pelvis steady over 10 s", hi - lo < 0.06, "(range %.3f m)" % (hi - lo))
	check("pelvis at standing height", absf(lo - 1.0) < 0.12, "(%.2f m)" % lo)
	check("head stays up", head_lo > 1.5, "(%.2f m)" % head_lo)
	check("no NaN / explosion", not player.rig.has_invalid_state())
	# Joint-limit convention sanity: a crouch must actually bend the knee.
	inp(Vector2.ZERO, false, false, true)
	await seconds(0.8)
	var thigh: Node3D = player.rig.bones[&"thigh_l"]
	var shin: Node3D = player.rig.bones[&"shin_l"]
	var knee := thigh.global_basis.y.angle_to(shin.global_basis.y)
	check("crouch bends the knee (joint limits ok)", knee > 1.0, "(%.2f rad)" % knee)
	var shin_fwd := shin.global_basis.y.dot(Vector3.FORWARD)
	check("knee bends the right way (shin top tilts forward)", shin_fwd > 0.3, "(%.2f)" % shin_fwd)


func test_walk_momentum() -> void:
	print("walk momentum")
	await place(open())
	inp(Vector2(0, -1))
	var t := 0.0
	var max_err := 0.0
	while player.horizontal_speed() < cfg.walk_speed * 0.95 and t < 3.0:
		await physics_frame
		t += TICK
	check("walk accel is gradual", t > 0.15 and t < 1.0, "(%.2f s to 95%%)" % t)
	for i in 120:
		await physics_frame
		max_err = maxf(max_err, pelvis_error())
	check("puppet tracks proxy while walking", max_err < 0.35, "(max %.2f m)" % max_err)
	var moved_dir := Vector3(player.velocity.x, 0, player.velocity.z).normalized()
	check("forward input moves along -Z", moved_dir.dot(Vector3.FORWARD) > 0.95)
	inp()
	await physics_frame
	check("release keeps momentum", player.horizontal_speed() > cfg.walk_speed * 0.8, "(%.2f m/s)" % player.horizontal_speed())
	await seconds(1.0)
	check("comes to rest by friction", player.horizontal_speed() < 0.05)


func test_run_momentum() -> void:
	print("run momentum")
	await place(open())
	inp(Vector2(0, -1), true)
	var t := 0.0
	var max_err := 0.0
	while player.horizontal_speed() < cfg.run_speed * 0.95 and t < 5.0:
		await physics_frame
		t += TICK
		max_err = maxf(max_err, pelvis_error())
	check("run builds momentum slowly", t > 0.6 and t < 2.5, "(%.2f s to 95%%)" % t)
	check("state is RUN", player.state == PlayerController.State.RUN)
	await seconds(1.0)
	check("puppet tracks proxy while running", max_err < 0.45, "(max %.2f m)" % max_err)
	check("no NaN while running", not player.rig.has_invalid_state())


func test_skid() -> void:
	print("skid / turning")
	await place(open())
	inp(Vector2(0, -1), true)
	await seconds(2.5)
	var yaw_before := player.facing_yaw
	inp(Vector2(0, 1), true)
	var skidded := false
	for i in 12:
		await physics_frame
		skidded = skidded or player._skidding
	check("hard reverse at speed skids", skidded)
	check("facing doesn't snap during skid", absf(angle_difference(player.facing_yaw, yaw_before)) < 0.3)
	await seconds(2.0)
	check("eventually runs the other way", player.velocity.z > 3.0, "(vz %.2f)" % player.velocity.z)


func test_jump_heights() -> void:
	print("jump")
	await place(open())
	var y0 := player.global_position.y
	inp(Vector2.ZERO, false, true)
	var apex := y0
	for i in 120:
		await physics_frame
		apex = maxf(apex, player.global_position.y)
	inp()
	await wait_state(PlayerController.State.IDLE, 2.0)
	var full := apex - y0
	check("full jump apex matches config", absf(full - cfg.jump_height) < 0.12, "(%.2f m vs %.2f)" % [full, cfg.jump_height])
	await seconds(0.3)
	inp(Vector2.ZERO, false, true)
	await frames(4)
	inp()
	apex = y0
	for i in 120:
		await physics_frame
		apex = maxf(apex, player.global_position.y)
	var short := apex - y0
	check("tap jump is lower (variable height)", short < full * 0.7, "(%.2f m)" % short)
	await seconds(0.5)


func test_crouch_and_tunnel() -> void:
	print("crouch + tunnel")
	await place(open())
	inp(Vector2.ZERO, false, false, true)
	await frames(20)
	check("crouch state", player.state == PlayerController.State.CROUCH)
	check("capsule shrinks", is_equal_approx(player.capsule_height(), cfg.crouch_height))
	var t: Vector3 = main.markers.tunnel
	await place(t + Vector3(0, 0, 5))
	inp(Vector2(0, -1), false, false, true)
	await seconds(2.6)
	check("crouch-walked into tunnel", player.global_position.z < t.z + 2.5, "(z %.2f)" % player.global_position.z)
	inp(Vector2.ZERO)
	await seconds(0.5)
	check("can't stand under ceiling", player.state == PlayerController.State.CROUCH and player.is_crouched_shape())
	inp(Vector2(0, -1))
	await seconds(4.5)
	check("stands up after leaving tunnel", not player.is_crouched_shape() and player.global_position.z < t.z - 3.0,
		"(state %s, z %.1f)" % [PlayerController.State.keys()[player.state], player.global_position.z])


func test_foot_ik_slope() -> void:
	print("foot IK on a 30 deg slope (standing across it)")
	# Facing +X on a slope rising toward -Z: left foot uphill, right foot downhill.
	await place(main.markers.ramp_30 + Vector3.UP * 0.05, 1.5, -PI * 0.5)
	for side in ["l", "r"]:
		var c := foot_clearance(side)
		check("%s foot rests on the slope" % side, absf(c - 0.04) < 0.035, "(clearance %.3f m)" % c)
		var a := foot_alignment(side)
		check("%s foot tilts to the slope" % side, a > 0.97, "(dot %.3f)" % a)
	var drop := player.rig.pelvis().global_position.y - player.global_position.y
	check("pelvis lowers for the downhill leg", drop < 0.97, "(pelvis %.2f m above capsule)" % drop)


func test_foot_ik_stairs() -> void:
	print("foot IK standing on stairs")
	var tread := Vector3(main.markers.stairs.x, 1.35, -2 - 5 * 0.35 - 0.175)
	await place(tread, 1.5)
	for side in ["l", "r"]:
		var c := foot_clearance(side)
		check("%s foot stands on the tread" % side, absf(c - 0.04) < 0.035, "(clearance %.3f m)" % c)
	# Split stance across two steps.
	await place(Vector3(main.markers.stairs.x, 1.35, -2 - 5 * 0.35), 1.5, -PI * 0.5)
	for side in ["l", "r"]:
		var c := foot_clearance(side)
		check("%s foot on its own step (sideways stance)" % side, absf(c - 0.04) < 0.035, "(clearance %.3f m)" % c)


func test_climb_stairs() -> void:
	print("climb stairs")
	await place(main.markers.stairs)
	inp(Vector2(0, -1))
	var worst_sink := 99.0
	var peak := 0.0
	for i in int(2.2 / TICK):
		await physics_frame
		worst_sink = minf(worst_sink, minf(foot_clearance("l"), foot_clearance("r")))
		peak = maxf(peak, player.global_position.y)
	inp()
	check("walks up the stairs", peak > 2.3, "(peak y %.2f)" % peak)
	check("no stumble/ragdoll on stairs", not PlayerController.State.RAGDOLL in _seen and not PlayerController.State.STUMBLE in _seen)
	check("feet never sink into the treads", worst_sink > -0.03, "(lowest foot center %.3f m)" % worst_sink)
	await seconds(0.5)


func test_slide() -> void:
	print("slide")
	await place(open())
	inp(Vector2(0, -1), true)
	await seconds(2.5)
	inp(Vector2(0, -1), true, false, true)
	await physics_frame
	check("crouch at run speed starts a slide", player.state == PlayerController.State.SLIDE)
	var z0 := player.global_position.z
	await wait_state(PlayerController.State.CROUCH, 4.0)
	var dist := z0 - player.global_position.z
	check("slide carries momentum", dist > 4.0, "(%.1f m)" % dist)
	inp()
	await seconds(0.5)


func test_roll() -> void:
	print("roll")
	await place(open())
	var p0 := player.global_position
	inp(Vector2.ZERO, false, false, false, true)
	await physics_frame
	inp()
	check("roll starts", player.state == PlayerController.State.ROLL)
	var spun := false
	for i in int(cfg.roll_duration / TICK) + 6:
		await physics_frame
		# Somewhere in the roll the chest must point down-ish (body actually tumbles).
		var chest: Node3D = player.rig.bones[&"chest"]
		spun = spun or chest.global_basis.y.y < -0.2
	var dist := (player.global_position - p0).length()
	check("roll ends", player.state != PlayerController.State.ROLL)
	check("roll covers distance", dist > 2.5, "(%.1f m)" % dist)
	check("puppet tumbles through the roll", spun)
	await seconds(1.0)
	var pe := pelvis_error()
	check("puppet recovers posture after roll", pe < 0.3, "(%.2f m)" % pe)


func test_stumble_landing() -> void:
	print("stumble landing")
	await place(open() + Vector3(0, 4.0, 0), 0.0)
	await seconds(2.0)
	check("4 m drop stumbles", PlayerController.State.STUMBLE in _seen, "(impact %.1f)" % player.last_impact)
	check("4 m drop doesn't ragdoll", not PlayerController.State.RAGDOLL in _seen)


func test_hard_fall_ragdoll_and_get_up() -> void:
	print("hard fall")
	await place(open() + Vector3(0, 10.0, 0), 0.0)
	var t := await wait_state(PlayerController.State.RAGDOLL, 4.0)
	check("10 m fall ragdolls", t >= 0.0, "(impact %.1f m/s)" % player.last_impact)
	var up := await wait_state(PlayerController.State.IDLE, 10.0)
	check("gets back up", up >= 0.0 and PlayerController.State.GET_UP in _seen, "(%.1f s)" % up)
	await seconds(1.0)
	var pe := pelvis_error()
	check("standing posture restored", pe < 0.3, "(%.2f m)" % pe)
	check("no NaN after ragdoll", not player.rig.has_invalid_state())


func test_roll_landing_saves() -> void:
	print("roll landing")
	var base := open()
	await place(base + Vector3(0, 10.0, 0), 0.0)
	var pressed := false
	for i in int(4.0 / TICK):
		if not pressed and player.velocity.y < 0.0 and player.global_position.y < base.y + 3.5:
			inp(Vector2.ZERO, false, false, false, true)
			pressed = true
		elif pressed:
			inp()
		await physics_frame
	check("roll-landing from 10 m avoids ragdoll", not PlayerController.State.RAGDOLL in _seen and PlayerController.State.ROLL in _seen)


func test_swinging_log_knockdown() -> void:
	print("swinging log")
	await place(main.markers.log, 0.0)
	var t := await wait_state(PlayerController.State.RAGDOLL, 5.0)
	check("log knocks player into ragdoll", t >= 0.0, "(%.1f s, last hit %.0f)" % [t, player.last_hit])
	await seconds(1.5)
	check("no NaN after log hit", not player.rig.has_invalid_state())


func test_bumper_launch() -> void:
	print("bumper")
	await place(main.markers.bumper + Vector3(0, 0, 3.5))
	inp(Vector2(0, -1))
	var t := await wait_state(PlayerController.State.RAGDOLL, 3.0)
	inp()
	check("bumper launches into ragdoll", t >= 0.0)
	var peak := 0.0
	for i in 60:
		await physics_frame
		peak = maxf(peak, player.rig.pelvis().global_position.y)
	check("bumper sends the body flying", peak > 1.6, "(pelvis peak %.2f m)" % peak)


func test_smoke_random_input() -> void:
	print("smoke: 30 s random input around the level")
	await place(main.markers.spawn)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var worst := 0.0
	for i in int(30.0 / TICK):
		if i % 30 == 0:
			inp(Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)), rng.randf() < 0.5,
				rng.randf() < 0.2, rng.randf() < 0.15, rng.randf() < 0.1)
		await physics_frame
		if player.state != PlayerController.State.RAGDOLL and player.state != PlayerController.State.ROLL \
				and player.state != PlayerController.State.GET_UP:
			worst = maxf(worst, pelvis_error())
	inp()
	check("no NaN under random input", not player.rig.has_invalid_state())
	check("puppet never separates from proxy", worst < 1.2, "(worst %.2f m)" % worst)
