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


## [test function, group, part of the quick suite?]  Order within a group is kept.
const TESTS := [
	["test_idle_stability", "core", true],
	["test_skin_follows_puppet", "core", true],
	["test_lod_tiers", "core", true],
	["test_lod_promotes_on_hit", "core", false],
	["test_lod_ragdoll_stays_full", "core", false],
	["test_lift_carry_throw", "objects", true],
	["test_lift_and_drop", "objects", false],
	["test_push_and_pull_crate", "objects", true],
	["test_heavy_block_is_slower", "objects", false],
	["test_too_heavy", "objects", false],
	["test_punch_flinch", "combat", true],
	["test_punch_combo_stagger", "combat", false],
	["test_kick_stagger", "combat", true],
	["test_kick_staggered_knockdown", "combat", false],
	["test_running_kick_knockdown", "combat", false],
	["test_guard_blocks_punch", "combat", true],
	["test_guard_from_behind", "combat", false],
	["test_kick_breaks_guard", "combat", false],
	["test_air_hit_knockdown", "combat", false],
	["test_sparring_hits_player", "combat", false],
	["test_punch_prop", "combat", false],
	["test_no_attack_while_carrying", "objects", false],
	["test_run_into_npc", "combat", true],
	["test_walk_momentum", "movement", true],
	["test_run_momentum", "movement", false],
	["test_skid", "movement", false],
	["test_jump_heights", "movement", true],
	["test_crouch_and_tunnel", "movement", true],
	["test_foot_ik_slope", "terrain", true],
	["test_foot_ik_stairs", "terrain", false],
	["test_climb_stairs", "terrain", false],
	["test_ground_mantle", "terrain", true],
	["test_running_mantle", "terrain", false],
	["test_air_mantle_platform", "terrain", false],
	["test_grab_hang_shimmy_climb", "terrain", true],
	["test_hang_drop", "terrain", false],
	["test_no_grab_out_of_reach", "terrain", false],
	["test_slide", "movement", false],
	["test_roll", "movement", true],
	["test_stumble_landing", "movement", false],
	["test_hard_fall_ragdoll_and_get_up", "movement", true],
	["test_roll_landing_saves", "movement", false],
	["test_swinging_log_knockdown", "movement", false],
	["test_bumper_launch", "movement", false],
	["test_smoke_random_input", "movement", false],
]

## Shortened waits in the quick suite.
var quick := false


func _initialize() -> void:
	_run()


## User args (after `--`): --suite=quick|full  --group=a,b  --only=test_a,test_b  --list
func _selected() -> Array:
	var groups: Array = []
	var only: Array = []
	for a in OS.get_cmdline_user_args():
		if a == "--suite=quick":
			quick = true
		elif a.begins_with("--group="):
			groups = Array(a.trim_prefix("--group=").split(","))
		elif a.begins_with("--only="):
			only = Array(a.trim_prefix("--only=").split(","))
	return TESTS.filter(func(t):
		if not only.is_empty():
			return t[0] in only
		return (groups.is_empty() or t[1] in groups) and (not quick or t[2]))


func _run() -> void:
	if "--list" in OS.get_cmdline_user_args():
		for t in TESTS:
			print("%s %s%s" % [t[1], t[0], " (quick)" if t[2] else ""])
		quit()
		return
	var selected := _selected()
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await physics_frame
	player = main.player
	cfg = player.config
	player.use_external_input = true
	player.state_changed.connect(func(_o, n): _seen.append(n))

	var t_all := Time.get_ticks_msec()
	for t in selected:
		var t0 := Time.get_ticks_msec()
		await call(t[0])
		print("  [%s: %.1f s]" % [t[0], (Time.get_ticks_msec() - t0) / 1000.0])

	print("\n==== %d passed, %d failed ==== (%d tests, %.0f s)" % [_passes, _fails.size(), selected.size(), (Time.get_ticks_msec() - t_all) / 1000.0])
	for f in _fails:
		print("  FAIL: " + f)
	quit(1 if _fails.size() > 0 else 0)


# ------------------------------------------------------------------ helpers

func frames(n: int) -> void:
	for i in n:
		await physics_frame


func seconds(s: float) -> void:
	await frames(int(round(s / TICK)))


func inp(move := Vector2.ZERO, run := false, jump := false, crouch := false, roll := false,
		interact := false, throw := false, punch := false, kick := false, guard := false) -> void:
	player.external_input = {"move": move, "run": run, "jump": jump, "crouch": crouch, "roll": roll,
		"interact": interact, "throw": throw, "punch": punch, "kick": kick, "guard": guard}


func press_interact() -> void:
	inp(Vector2.ZERO, false, false, false, false, true)
	await physics_frame
	inp()


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


## Height of the foot body center above the ground directly beneath it (rest pose: 0.035).
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
	for i in int((3.0 if quick else 10.0) / TICK):
		await physics_frame
		var y := player.rig.pelvis().global_position.y - player.global_position.y
		lo = minf(lo, y)
		hi = maxf(hi, y)
		head_lo = minf(head_lo, player.rig.bones[&"head"].global_position.y - player.global_position.y)
	check("pelvis steady while idle", hi - lo < 0.06, "(range %.3f m)" % (hi - lo))
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


## World position of a puppet joint pivot.
func puppet_pivot(bone: StringName) -> Vector3:
	var b: PuppetBone = player.rig.bones[bone]
	return b.global_transform * (b.def.pivot - b.def.center)


func skin_error() -> float:
	player.skin.update_pose()  # bodies were just synced from the last physics step
	var pairs := {"hand.L": &"hand_l", "hand.R": &"hand_r", "foot.L": &"foot_l", "foot.R": &"foot_r",
		"shin.L": &"shin_l", "forearm.R": &"forearm_r", "spine.005": &"head"}
	var worst := 0.0
	for bone in pairs:
		worst = maxf(worst, player.skin.bone_world_position(bone).distance_to(puppet_pivot(pairs[bone])))
	return worst


## Smallest dot product between a mesh limb bone's direction and its physics segment.
func skin_alignment() -> float:
	player.skin.update_pose()
	var pairs := {"upper_arm.L": &"upper_arm_l", "forearm.R": &"forearm_r", "thigh.L": &"thigh_l", "shin.R": &"shin_r"}
	var worst := 1.0
	for bone in pairs:
		var b: PuppetBone = player.rig.bones[pairs[bone]]
		var seg := (b.global_transform * (b.def.center - b.def.pivot) - b.global_transform.origin).normalized()
		worst = minf(worst, player.skin.bone_world_direction(bone).dot(seg))
	return worst


func test_skin_follows_puppet() -> void:
	print("skinned humanoid follows the puppet")
	await place(open(), 0.5)
	check("skin aligned with puppet joints (idle)", skin_error() < 0.08, "(worst %.3f m)" % skin_error())
	check("mesh limbs point along their physics segments (idle)", skin_alignment() > 0.97, "(min dot %.3f)" % skin_alignment())
	inp(Vector2(0, -1), true)
	var worst := 0.0
	var align := 1.0
	for i in int(2.5 / TICK):
		await physics_frame
		worst = maxf(worst, skin_error())
		align = minf(align, skin_alignment())
	inp()
	check("skin stays aligned while running", worst < 0.08, "(worst %.3f m)" % worst)
	check("mesh limbs follow physics limbs while running", align > 0.95, "(min dot %.3f)" % align)
	await place(open() + Vector3(0, 10, 0), 0.0)
	await wait_state(PlayerController.State.RAGDOLL, 4.0)
	await seconds(1.0)
	var hips := player.skin.bone_world_position("spine").distance_to(player.rig.pelvis().global_position)
	check("skin follows the ragdoll", hips < 0.2 and skin_error() < 0.15, "(hips %.3f, worst joint %.3f m)" % [hips, skin_error()])
	await wait_state(PlayerController.State.IDLE, 8.0)


## Stand `dist` metres in front of a prop's +Z face, facing it.
func face_prop(body: RigidBody3D, dist: float) -> void:
	var ext := PlayerController.object_extents(body)
	var p := body.global_position
	await place(Vector3(p.x, 0, p.z + ext.z + dist), 0.4)


func test_lift_carry_throw() -> void:
	print("lift, carry, throw")
	var box: RigidBody3D = main.props.small_box
	await face_prop(box, 0.45)
	await press_interact()
	check("E lifts a light object", player.is_carrying() == box)
	await seconds(0.8)
	var hold_err := box.global_position.distance_to(player._hold_target())
	check("object held in front of the chest", hold_err < 0.25 and box.global_position.y > 0.9, "(err %.2f m, y %.2f)" % [hold_err, box.global_position.y])
	var hands: Vector3 = (player.rig.bones[&"hand_l"].global_position + player.rig.bones[&"hand_r"].global_position) * 0.5
	check("hands hold the object", hands.distance_to(box.global_position) < 0.3, "(%.2f m)" % hands.distance_to(box.global_position))
	inp(Vector2(0, -1), true)
	var max_err := 0.0
	for i in int(2.0 / TICK):
		await physics_frame
		max_err = maxf(max_err, box.global_position.distance_to(player._hold_target()))
	check("object stays held while running", player.is_carrying() == box and max_err < 0.45, "(max err %.2f m)" % max_err)
	check("carrying slows you down", player.horizontal_speed() < cfg.run_speed * 0.99, "(%.1f m/s)" % player.horizontal_speed())
	inp()
	await seconds(1.0)
	var start := box.global_position
	inp(Vector2.ZERO, false, false, false, false, false, true)
	await physics_frame
	inp()
	check("F throws", player.is_carrying() == null)
	await seconds(0.8)
	var flew := Vector2(box.global_position.x - start.x, box.global_position.z - start.z).length()
	check("thrown object flies forward", flew > 3.0, "(%.1f m)" % flew)
	await seconds(1.0)


func test_lift_and_drop() -> void:
	print("lift and drop the sack (18 kg)")
	var sack: RigidBody3D = main.props.sack
	await face_prop(sack, 0.45)
	await press_interact()
	check("lifts the sack", player.is_carrying() == sack)
	await seconds(0.8)
	inp(Vector2(0, -1))
	await seconds(1.5)
	inp()
	check("heavier load slows walking", player.horizontal_speed() < cfg.walk_speed * 0.8, "(%.2f m/s)" % player.horizontal_speed())
	await seconds(0.5)
	await press_interact()
	check("E drops it", player.is_carrying() == null)
	await seconds(1.0)
	check("dropped object lands", sack.global_position.y < 0.35, "(y %.2f)" % sack.global_position.y)
	await seconds(0.5)
	check("no ragdoll from handling objects", not PlayerController.State.RAGDOLL in _seen)


func push_for(body: RigidBody3D, dir: float, t: float) -> float:
	await face_prop(body, 0.25)
	await press_interact()
	if player.state != PlayerController.State.GRAB:
		return -999.0
	await seconds(0.3)
	var z0 := body.global_position.z
	inp(Vector2(0, dir))
	await seconds(t)
	inp()
	return body.global_position.z - z0


func test_push_and_pull_crate() -> void:
	print("push and pull the 80 kg crate")
	var crate: RigidBody3D = main.props.crate
	await face_prop(crate, 0.25)
	await press_interact()
	check("E grabs a heavy object", player.state == PlayerController.State.GRAB)
	await seconds(0.4)
	var face_z := crate.global_position.z + PlayerController.object_extents(crate).z
	var hand_gap := 0.0
	for s in ["l", "r"]:
		hand_gap = maxf(hand_gap, absf(player.rig.bones[StringName("hand_" + s)].global_position.z - face_z))
	check("hands on the crate face", hand_gap < 0.15, "(%.2f m)" % hand_gap)
	var z0 := crate.global_position.z
	inp(Vector2(0, -1))
	await seconds(2.0)
	var pushed := z0 - crate.global_position.z
	check("pushing moves the crate away", pushed > 1.5, "(%.2f m)" % pushed)
	check("still grabbing after the push", player.state == PlayerController.State.GRAB)
	var z1 := crate.global_position.z
	inp(Vector2(0, 1))
	await seconds(2.0)
	inp()
	var pulled := crate.global_position.z - z1
	check("pulling drags the crate back", pulled > 1.0, "(%.2f m)" % pulled)
	var gap := player.global_position.z - (crate.global_position.z + PlayerController.object_extents(crate).z)
	check("player stays at the crate", absf(gap - cfg.grab_gap) < 0.2, "(gap %.2f m)" % gap)
	await press_interact()
	check("E lets go", player.state != PlayerController.State.GRAB and player.is_grabbing() == null)
	await seconds(0.5)


func test_heavy_block_is_slower() -> void:
	print("250 kg block is slower")
	var moved_crate: float = await push_for(main.props.crate, -1.0, 1.5)
	await press_interact()
	var moved_block: float = await push_for(main.props.block, -1.0, 1.5)
	await press_interact()
	check("block can be pushed", moved_block < -0.3, "(%.2f m)" % -moved_block)
	check("heavier = slower", -moved_block < -moved_crate * 0.7, "(block %.2f m vs crate %.2f m)" % [-moved_block, -moved_crate])
	await seconds(0.5)


func test_too_heavy() -> void:
	print("600 kg monolith")
	var m: RigidBody3D = main.props.monolith
	await face_prop(m, 0.25)
	check("hint says too heavy", player.interact_hint().begins_with("Too heavy"), "(%s)" % player.interact_hint())
	await press_interact()
	check("can't grab it", player.state != PlayerController.State.GRAB and player.is_carrying() == null)


# ------------------------------------------------------------------ combat helpers

var _reactions: Array = []   ## [who, kind]


func watch_reactions() -> void:
	if player.combat.reacted.get_connections().size() > 1:
		return  # already watching (HUD connects one)
	player.combat.reacted.connect(func(k, _s): _reactions.append(["player", k]))
	for n in main.dummies:
		var d: PlayerController = main.dummies[n]
		d.combat.reacted.connect(func(k, _s): _reactions.append([n, k]))


func reactions_of(who: String) -> Array:
	return _reactions.filter(func(r): return r[0] == who).map(func(r): return r[1])


## Reset a dummy to its spot (facing -Z) and stand the player `dist` m in front of it
## (or behind it), facing it.
func square_up(dummy_name: String, dist: float, behind := false) -> PlayerController:
	watch_reactions()
	var d: PlayerController = main.dummies[dummy_name]
	d.reset()
	var p := d.global_position
	if behind:
		await place(p + Vector3(0, 0, dist), 0.0, 0.0)
	else:
		await place(p + Vector3(0, 0, -dist), 0.0, PI)
	await seconds(0.6)
	_reactions.clear()
	_seen.clear()
	return d


func strike(kind: String) -> void:
	if kind == "punch":
		inp(Vector2.ZERO, false, false, false, false, false, false, true)
	else:
		inp(Vector2.ZERO, false, false, false, false, false, false, false, true)
	await physics_frame
	inp()


func max_bone_deviation(c: PlayerController) -> float:
	var worst := 0.0
	for b: PuppetBone in c.rig.bones.values():
		worst = maxf(worst, b.global_position.distance_to(b.target.origin))
	return worst


# ------------------------------------------------------------------ LOD tests

func lod_name(c: PlayerController) -> String:
	return CharacterLOD.Tier.keys()[c.rig.lod]


func bodies_frozen(c: PlayerController) -> bool:
	return c.rig.bones.values().all(func(b): return b.freeze)


func test_lod_tiers() -> void:
	print("LOD tiers by distance")
	var d: PlayerController = main.dummies.passive
	d.reset()
	var p := d.global_position
	await place(p + Vector3(0, 0, 80), 0.6)
	check("far dummy is PROXY_ONLY", d.rig.lod == CharacterLOD.Tier.PROXY_ONLY, "(%s)" % lod_name(d))
	check("its puppet is frozen and out of collision", bodies_frozen(d) and d.rig.pelvis().collision_layer == 0)
	check("the player is always FULL", player.rig.lod == CharacterLOD.Tier.FULL)
	await place(p + Vector3(0, 0, 40), 0.6)
	check("mid-range dummy is KINEMATIC", d.rig.lod == CharacterLOD.Tier.KINEMATIC, "(%s)" % lod_name(d))
	check("kinematic puppet is parked (no physics bodies)", bodies_frozen(d) and d.rig.pelvis().collision_layer == 0)
	d.skin.update_pose()
	var hips := d.skin.bone_world_position("spine").distance_to(d.rig.pelvis().global_position)
	check("skin still follows a reduced-tier puppet", hips < 0.2, "(%.2f m)" % hips)
	await place(p + Vector3(0, 0, 3), 0.6)
	check("nearby dummy is FULL again", d.rig.lod == CharacterLOD.Tier.FULL and not bodies_frozen(d), "(%s)" % lod_name(d))
	await seconds(1.0)
	var err := d.rig.pelvis().global_position.distance_to(d.global_position + Vector3.UP)
	check("promoted dummy stands normally", err < 0.15 and d.state == PlayerController.State.IDLE, "(pelvis err %.2f m)" % err)


func test_lod_promotes_on_hit() -> void:
	print("LOD promotes on hit")
	watch_reactions()
	var d: PlayerController = main.dummies.passive
	d.reset()
	await place(d.global_position + Vector3(0, 0, 40), 0.6)
	check("starts KINEMATIC", d.rig.lod == CharacterLOD.Tier.KINEMATIC, "(%s)" % lod_name(d))
	_reactions.clear()
	d.receive_hit({"dir": Vector3.FORWARD, "strength": 1.0, "point": d.rig.bones[&"head"].global_position,
		"bone": &"head", "attacker": player, "up": 0.1})
	check("a hit promotes it to FULL immediately", d.rig.lod == CharacterLOD.Tier.FULL)
	check("and it still reacts (FLINCH)", reactions_of("passive") == [&"flinch"], "(%s)" % [reactions_of("passive")])
	await seconds(cfg.lod_promote_hold + 0.6)
	check("drops back to its distance tier afterwards", d.rig.lod == CharacterLOD.Tier.KINEMATIC, "(%s)" % lod_name(d))


func test_lod_ragdoll_stays_full() -> void:
	print("LOD keeps ragdolls FULL")
	var d: PlayerController = main.dummies.passive
	d.reset()
	await place(d.global_position + Vector3(0, 0, 3), 0.6)
	d.enter_ragdoll(Vector3(0, 2, 3), d.rig.pelvis().global_position)
	await place(d.global_position + Vector3(0, 0, 80), 0.0)
	var stayed := true
	while d.state in [PlayerController.State.RAGDOLL, PlayerController.State.GET_UP]:
		stayed = stayed and d.rig.lod == CharacterLOD.Tier.FULL
		await physics_frame
	check("ragdoll + get-up stay FULL even when far away", stayed)
	check("it got back up", d.state == PlayerController.State.IDLE)
	await seconds(cfg.lod_promote_hold + 0.6)
	check("then drops to PROXY_ONLY", d.rig.lod == CharacterLOD.Tier.PROXY_ONLY, "(%s)" % lod_name(d))
	d.reset()


# ------------------------------------------------------------------ combat tests

func test_run_into_npc() -> void:
	print("running into NPCs")
	var d := await square_up("passive", 6.0)
	inp(Vector2(0, 1), true)
	var t := await wait_dummy_state(d, PlayerController.State.RAGDOLL, 2.0)
	inp()
	check("sprinting into an NPC knocks it down", t >= 0.0 and &"knockdown" in reactions_of("passive"), "(%s)" % [reactions_of("passive")])
	await wait_dummy_state(d, PlayerController.State.IDLE, 8.0)
	d = await square_up("passive", 2.5)
	inp(Vector2(0, 1))
	t = await wait_dummy_state(d, PlayerController.State.STAGGER, 2.0)
	inp()
	check("walking into an NPC staggers it", t >= 0.0 and reactions_of("passive") == [&"stagger"], "(%s)" % [reactions_of("passive")])
	await seconds(1.0)


func test_punch_flinch() -> void:
	print("punch -> flinch")
	var d := await square_up("passive", 1.0)
	var p0 := d.global_position
	await strike("punch")
	check("punch starts an attack", player.state == PlayerController.State.ATTACK)
	var dev := 0.0
	var bad_state := false
	for i in int(0.6 / TICK):
		await physics_frame
		dev = maxf(dev, max_bone_deviation(d))
		bad_state = bad_state or d.state in [PlayerController.State.STAGGER, PlayerController.State.RAGDOLL]
	check("punch lands as a FLINCH", reactions_of("passive") == [&"flinch"], "(%s)" % [reactions_of("passive")])
	check("struck part recoils physically", dev > 0.06, "(max bone deviation %.2f m)" % dev)
	check("flinch doesn't interrupt the target", not bad_state and d.global_position.distance_to(p0) < 0.3)
	check("attacker returns to normal", player.state != PlayerController.State.ATTACK)


func test_punch_combo_stagger() -> void:
	print("three quick punches -> stagger")
	var d := await square_up("passive", 1.0)
	for i in 3:
		await strike("punch")
		while player.state == PlayerController.State.ATTACK:
			await physics_frame
		await physics_frame
	await seconds(0.3)
	var r := reactions_of("passive")
	check("third punch in a row staggers", r.size() == 3 and r[2] == &"stagger", "(%s)" % [r])


func test_kick_stagger() -> void:
	print("kick -> stagger")
	var d := await square_up("passive", 1.1)
	var p0 := d.global_position
	await strike("kick")
	var t := await wait_dummy_state(d, PlayerController.State.STAGGER, 1.0)
	await seconds(0.8)
	var pushed := d.global_position.distance_to(p0)
	check("kick STAGGERS", t >= 0.0 and reactions_of("passive") == [&"stagger"], "(%s)" % [reactions_of("passive")])
	check("stagger knocks the target back", pushed > 0.4, "(%.2f m)" % pushed)
	check("target recovers on its feet", d.state in [PlayerController.State.IDLE, PlayerController.State.WALK])


func wait_dummy_state(d: PlayerController, s: PlayerController.State, timeout: float) -> float:
	var t := 0.0
	while t < timeout:
		if d.state == s:
			return t
		await physics_frame
		t += TICK
	return -1.0


func test_kick_staggered_knockdown() -> void:
	print("kick on a staggered target -> knockdown")
	var d := await square_up("passive", 1.1)
	await strike("kick")
	await seconds(CombatComponent.ATTACKS[&"kick"].windup - 0.04)
	d.start_stagger(Vector3.ZERO)  # caught off balance as the kick lands
	var t := await wait_dummy_state(d, PlayerController.State.RAGDOLL, 1.0)
	check("kick on a staggered target KNOCKS DOWN", t >= 0.0 and &"knockdown" in reactions_of("passive"), "(%s)" % [reactions_of("passive")])
	var up := await wait_dummy_state(d, PlayerController.State.IDLE, 8.0)
	check("knocked-down dummy gets back up", up >= 0.0, "(%.1f s)" % up)


func test_running_kick_knockdown() -> void:
	print("running kick -> knockdown")
	var d := await square_up("passive", 7.0)
	inp(Vector2(0, 1), true)
	while d.global_position.distance_to(player.global_position) > 1.9:
		await physics_frame
	inp(Vector2(0, 1), true, false, false, false, false, false, false, true)
	await physics_frame
	inp()
	var t := await wait_dummy_state(d, PlayerController.State.RAGDOLL, 1.0)
	check("running kick KNOCKS DOWN", t >= 0.0 and &"knockdown" in reactions_of("passive"), "(%s)" % [reactions_of("passive")])
	var peak := 0.0
	for i in 60:
		await physics_frame
		peak = maxf(peak, d.rig.pelvis().global_position.distance_to(d._spawn.origin + Vector3.UP))
	check("knockdown sends the body flying", peak > 0.8, "(pelvis moved %.2f m)" % peak)
	await wait_dummy_state(d, PlayerController.State.IDLE, 8.0)


func test_guard_blocks_punch() -> void:
	print("guard blocks a punch")
	var d := await square_up("guard", 1.0)
	await seconds(0.5)
	check("guard dummy is guarding", d.combat.guarding)
	await strike("punch")
	await seconds(0.6)
	check("punch from the front is BLOCKED", reactions_of("guard") == [&"blocked"], "(%s)" % [reactions_of("guard")])
	check("still guarding after the block", d.combat.guarding and d.state != PlayerController.State.STAGGER)


func test_guard_from_behind() -> void:
	print("guard doesn't cover the back")
	var brain: DummyBrain = main.dummies.guard.get_node("Brain")
	brain.turn_to_target = false
	var d := await square_up("guard", 1.0, true)
	await strike("punch")
	await seconds(0.6)
	brain.turn_to_target = true
	check("punch from behind still FLINCHES a guarding target", reactions_of("guard") == [&"flinch"], "(%s)" % [reactions_of("guard")])


func test_kick_breaks_guard() -> void:
	print("kick breaks guard")
	var d := await square_up("guard", 1.1)
	await seconds(0.5)
	await strike("kick")
	var t := await wait_dummy_state(d, PlayerController.State.STAGGER, 1.0)
	check("kick BREAKS the guard into a stagger", t >= 0.0 and reactions_of("guard") == [&"guard_break"], "(%s)" % [reactions_of("guard")])
	check("guard is down for a moment", not d.combat.guarding)
	await seconds(1.5)
	check("guard comes back", d.combat.guarding)


func test_air_hit_knockdown() -> void:
	print("airborne target -> knockdown")
	var d := await square_up("passive", 3.0)
	d.teleport(d.global_position + Vector3.UP * 2.5)
	await seconds(0.2)
	check("target is airborne", d.state == PlayerController.State.AIR)
	d.receive_hit({"dir": Vector3.BACK, "strength": CombatComponent.ATTACKS[&"kick"].strength,
		"point": d.rig.pelvis().global_position, "bone": &"spine", "attacker": player, "up": 0.25})
	check("kick-strength hit in the air KNOCKS DOWN", d.state == PlayerController.State.RAGDOLL)
	await wait_dummy_state(d, PlayerController.State.IDLE, 8.0)


func test_sparring_hits_player() -> void:
	print("sparring dummy hits the player")
	var d: PlayerController = main.dummies.sparring
	var brain: DummyBrain = d.get_node("Brain")
	d.reset()
	brain._next_kick = false
	brain._t = 0.0
	await place(d.global_position + Vector3(0, 0, -1.3), 0.0, PI)
	watch_reactions()
	_reactions.clear()
	var t := 0.0
	while reactions_of("player").is_empty() and t < 4.0:
		await physics_frame
		t += TICK
	check("sparring dummy's punch makes the player FLINCH", reactions_of("player") == [&"flinch"], "(%s after %.1f s)" % [reactions_of("player"), t])
	brain._next_kick = false
	_reactions.clear()
	inp(Vector2.ZERO, false, false, false, false, false, false, false, false, true)
	t = 0.0
	while reactions_of("player").is_empty() and t < 4.0:
		await physics_frame
		t += TICK
	inp()
	check("guarding player BLOCKS the dummy's punch", reactions_of("player") == [&"blocked"], "(%s)" % [reactions_of("player")])
	await place(main.markers.spawn)


## Stop the bag dead at its rest pose so each strike starts from the same state.
func still_bag(bag: RigidBody3D, rest: Transform3D) -> void:
	bag.global_transform = rest
	bag.linear_velocity = Vector3.ZERO
	bag.angular_velocity = Vector3.ZERO
	await seconds(0.2)


func test_punch_prop() -> void:
	print("punching bag")
	var bag: RigidBody3D = main.props.bag
	var rest := bag.global_transform
	var p := rest.origin
	await place(Vector3(p.x, 0, p.z + 0.85), 0.6)
	await still_bag(bag, rest)
	var b0 := bag.global_position
	await strike("punch")
	var swing := 0.0
	var v_punch := 0.0
	for i in int(1.0 / TICK):
		await physics_frame
		swing = maxf(swing, Vector2(bag.global_position.x - b0.x, bag.global_position.z - b0.z).length())
		v_punch = maxf(v_punch, bag.linear_velocity.length())
	check("punch swings the bag", swing > 0.1, "(%.2f m)" % swing)
	await place(Vector3(p.x, 0, p.z + 0.85), 0.6)
	await still_bag(bag, rest)
	await strike("kick")
	var v_kick := 0.0
	for i in int(1.0 / TICK):
		await physics_frame
		v_kick = maxf(v_kick, bag.linear_velocity.length())
	check("kick hits the bag harder", v_kick > v_punch, "(peak %.2f m/s vs %.2f m/s)" % [v_kick, v_punch])


func test_no_attack_while_carrying() -> void:
	print("no attacks while carrying")
	var box: RigidBody3D = main.props.small_box
	box.global_position = open() + Vector3(-8, 0.3, 8)
	box.global_rotation = Vector3.ZERO
	box.linear_velocity = Vector3.ZERO
	box.angular_velocity = Vector3.ZERO
	await seconds(0.5)
	await face_prop(box, 0.45)
	await press_interact()
	await seconds(0.5)
	await strike("punch")
	check("can't punch while carrying", player.state != PlayerController.State.ATTACK and player.is_carrying() == box,
		"(%s, carrying %s)" % [PlayerController.State.keys()[player.state], player.is_carrying()])
	await press_interact()
	await seconds(0.5)


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
		check("%s foot rests on the slope" % side, absf(c - 0.035) < 0.035, "(clearance %.3f m)" % c)
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
		check("%s foot stands on the tread" % side, absf(c - 0.035) < 0.035, "(clearance %.3f m)" % c)
	# Split stance across two steps.
	await place(Vector3(main.markers.stairs.x, 1.35, -2 - 5 * 0.35), 1.5, -PI * 0.5)
	for side in ["l", "r"]:
		var c := foot_clearance(side)
		check("%s foot on its own step (sideways stance)" % side, absf(c - 0.035) < 0.035, "(clearance %.3f m)" % c)


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


func hand_height() -> float:
	return (player.rig.bones[&"hand_l"].global_position.y + player.rig.bones[&"hand_r"].global_position.y) * 0.5


func grounded() -> bool:
	return player.state in [PlayerController.State.IDLE, PlayerController.State.WALK,
		PlayerController.State.RUN, PlayerController.State.CROUCH]


func test_ground_mantle() -> void:
	print("ground mantle (1.2 m block)")
	await place(main.markers.mantle_block + Vector3(0, 0, 0.55))
	inp(Vector2.ZERO, false, true)
	await physics_frame
	inp()
	check("jump facing a chest-high ledge mantles", player.state == PlayerController.State.CLIMB)
	await seconds(1.2)
	check("ends standing on top", grounded() and absf(player.global_position.y - 1.2) < 0.05,
		"(y %.2f, %s)" % [player.global_position.y, PlayerController.State.keys()[player.state]])
	check("no stumble/ragdoll", not PlayerController.State.RAGDOLL in _seen and not PlayerController.State.STUMBLE in _seen)
	var pe := pelvis_error()
	check("puppet back in posture after mantle", pe < 0.3, "(%.2f m)" % pe)


func test_running_mantle() -> void:
	print("running mantle")
	var mb: Vector3 = main.markers.mantle_block
	await place(mb + Vector3(0, 0, 7))
	inp(Vector2(0, -1), true)
	while player.global_position.z - mb.z > 1.3:
		await physics_frame
	inp(Vector2(0, -1), true, true)
	var t := await wait_state(PlayerController.State.CLIMB, 1.0)
	check("running jump into a ledge mantles", t >= 0.0)
	while player.state == PlayerController.State.CLIMB:
		await physics_frame
	check("lands on top", absf(player.global_position.y - 1.2) < 0.08, "(y %.2f)" % player.global_position.y)
	check("keeps momentum over the top", player.horizontal_speed() > 2.5, "(%.1f m/s)" % player.horizontal_speed())
	inp()
	await seconds(1.0)


func test_air_mantle_platform() -> void:
	print("jump + mantle onto the 2 m platform")
	var p: Vector3 = main.markers.platform_2
	await place(Vector3(p.x, 0, p.z + 2.6))
	inp(Vector2(0, -1), false, true)
	var t := await wait_state(PlayerController.State.CLIMB, 1.2)
	check("mid-air ledge at chest height mantles", t >= 0.0)
	inp()
	await seconds(1.2)
	check("ends on the platform", grounded() and absf(player.global_position.y - p.y) < 0.05, "(y %.2f)" % player.global_position.y)


func test_grab_hang_shimmy_climb() -> void:
	print("grab, hang, shimmy, climb (3 m wall)")
	var cw: Vector3 = main.markers.climb_wall
	await place(cw + Vector3(0, 0, 0.6))
	inp(Vector2(0, -1), false, true)
	var t := 0.0
	while player.state != PlayerController.State.LEDGE_HANG and t < 1.5:
		await physics_frame
		t += TICK
	inp()
	check("jumping at a high ledge grabs it", player.state == PlayerController.State.LEDGE_HANG, "(%.2f s)" % t)
	await seconds(1.0)
	check("stays hanging", player.state == PlayerController.State.LEDGE_HANG)
	check("hangs at the right height", absf(player.global_position.y - (3.0 - cfg.hang_hand_height)) < 0.03, "(y %.2f)" % player.global_position.y)
	var hh := hand_height()
	check("puppet hands are on the ledge", absf(hh - 3.0) < 0.25, "(hands %.2f m)" % hh)
	check("no NaN while hanging", not player.rig.has_invalid_state())

	var x0 := player.global_position.x
	var y0 := player.global_position.y
	inp(Vector2(1, 0))
	await seconds(1.0)
	check("shimmies along the ledge", player.global_position.x - x0 > 0.8 and player.state == PlayerController.State.LEDGE_HANG,
		"(moved %.2f m)" % (player.global_position.x - x0))
	await seconds(4.0)
	var wall_end := cw.x + 4.0
	check("shimmy stops at the end of the ledge", player.global_position.x < wall_end - 0.1 and player.state == PlayerController.State.LEDGE_HANG,
		"(x %.2f, end %.2f)" % [player.global_position.x, wall_end])
	check("height constant while shimmying", absf(player.global_position.y - y0) < 0.02)

	inp(Vector2.ZERO, false, true)
	await physics_frame
	inp()
	check("jump climbs up", player.state == PlayerController.State.CLIMB)
	await seconds(cfg.climb_up_time + 0.5)
	check("ends on top of the wall", grounded() and absf(player.global_position.y - 3.0) < 0.05,
		"(y %.2f, %s)" % [player.global_position.y, PlayerController.State.keys()[player.state]])
	await seconds(0.8)
	var pe := pelvis_error()
	check("puppet recovers posture after climb", pe < 0.3, "(%.2f m)" % pe)
	check("no ragdoll during ledge sequence", not PlayerController.State.RAGDOLL in _seen)


func test_hang_drop() -> void:
	print("drop from hang")
	var cw: Vector3 = main.markers.climb_wall
	await place(cw + Vector3(-1, 0, 0.6))
	inp(Vector2(0, -1), false, true)
	while player.state != PlayerController.State.LEDGE_HANG:
		await physics_frame
	inp()
	await seconds(0.5)
	_seen.clear()
	inp(Vector2.ZERO, false, false, true)
	await physics_frame
	check("crouch lets go", player.state == PlayerController.State.AIR)
	await seconds(1.0)
	inp()
	check("drops to the ground without re-grabbing", grounded() and player.global_position.y < 0.05
		and not PlayerController.State.LEDGE_HANG in _seen, "(y %.2f)" % player.global_position.y)


func test_no_grab_out_of_reach() -> void:
	print("ledge out of reach")
	var p: Vector3 = main.markers.platform_10
	await place(Vector3(p.x, 0, p.z + 2.6))
	inp(Vector2(0, -1), false, true)
	await seconds(1.5)
	inp()
	check("10 m wall can't be grabbed from the ground", not PlayerController.State.LEDGE_HANG in _seen
		and not PlayerController.State.CLIMB in _seen)
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
