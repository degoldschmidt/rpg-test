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
	["test_crowd_layer", "core", true],
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
	["test_gait_planted_feet", "movement", true],
	["test_gait_stop_and_turn", "movement", false],
	["test_gait_arms_contralateral", "movement", true],
	["test_gait_turns", "movement", false],
	["test_mocap_import", "anim", true],
	["test_mocap_locomotion", "anim", true],
	["test_mocap_transitions", "anim", true],
	["test_mocap_crowd_bake", "anim", false],
	["test_mocap_fallback", "anim", false],
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
	# The displayed foot (what the skin shows; with mocap, calm legs show their animation).
	var shown := player.rig.display_transform(foot as PuppetBone).basis
	return shown.y.normalized().dot(hit.normal) if hit else 0.0


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
## Joint position of a puppet segment as displayed (the pose the skin follows).
func puppet_pivot(bone: StringName) -> Vector3:
	var b: PuppetBone = player.rig.bones[bone]
	return player.rig.display_transform(b) * (b.def.pivot - b.def.center)


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
		var t := player.rig.display_transform(b)
		var seg := (t * (b.def.center - b.def.pivot) - t.origin).normalized()
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

func test_crowd_layer() -> void:
	print("crowd layer: data agents, nearest become real characters")
	var vat := CrowdVAT.get_baked(self)
	var d: PackedFloat32Array = vat.pos_data
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for i in range(0, d.size(), 3):
		var p := Vector3(d[i], d[i + 1], d[i + 2])
		lo = lo.min(p)
		hi = hi.max(p)
	check("baked animation has the character's size, feet on the ground",
		hi.y - lo.y > 1.6 and hi.y - lo.y < 2.0 and absf(lo.y) < 0.1, "(%s .. %s)" % [lo, hi])
	var layer := CrowdLayer.new()
	main.add_child(layer)
	var c: Vector3 = main.markers.open + Vector3(0, 0, -30)
	for i in 64:
		layer.add_agent(c + Vector3((i % 8) * 2.6 - 9.1, 0, (i / 8) * 2.6 - 9.1), 0.0, Color(0.7, 0.5, 0.4))
	layer.focus = player
	layer.build()
	await place(c + Vector3(0, 0, 40), 0.5)
	check("far from the crowd nobody is materialized", layer.materialized_count() == 0)
	await place(c + Vector3(1.3, 0, 12), 0.5, 0.0)   # in line with a column of agents
	var n := layer.materialized_count()
	check("nearest agents become real characters, up to the pool size", n == layer.pool_size, "(%d)" % n)
	var ok := true
	for ch: PlayerController in layer.active_characters():
		ok = ok and ch.global_position.distance_to(player.global_position) < layer.query_radius + 1.0 \
			and ch.state != PlayerController.State.RAGDOLL
	check("materialized characters stand near the player, upright", ok)
	# Sprint through the crowd: running into the real characters knocks them over.
	var hit := false
	inp(Vector2(0, -1), true)
	for i in int(3.0 / TICK):
		await physics_frame
		for ch: PlayerController in layer.active_characters():
			hit = hit or ch.state in [PlayerController.State.RAGDOLL, PlayerController.State.STAGGER]
	inp()
	check("running into crowd NPCs staggers or knocks them down", hit)
	await place(c + Vector3(0, 0, 60), 8.0)
	check("after the player leaves, characters go back to the pool", layer.materialized_count() == 0,
		"(%d still out)" % layer.materialized_count())
	var stray := 0.0
	var min_gap := INF
	for i in layer.count:
		stray = maxf(stray, Vector2(layer.pos[i].x - layer.home[i].x, layer.pos[i].z - layer.home[i].z).length())
		for j in range(i + 1, layer.count):
			min_gap = minf(min_gap, Vector2(layer.pos[i].x - layer.pos[j].x, layer.pos[i].z - layer.pos[j].z).length())
	check("agents keep wandering near home after being handed back", stray < layer.wander_radius + 1.5, "(%.1f m)" % stray)
	check("agents keep personal space", min_gap > 0.4, "(closest pair %.2f m)" % min_gap)
	layer.queue_free()
	await physics_frame


## Whatever drives the legs: the mocap LocomotionPlayer (when clips are installed) or the
## procedural FootPlanner. Both expose stance / swing / feet per side.
func steps():
	return player.pose_gen.loco if player.pose_gen._clip_w > 0.5 else player.pose_gen.gait


func mocap_on() -> bool:
	return player.pose_gen._clip_w > 0.5


## Planted feet don't slide, swinging feet clear the ground, at stroll / walk / run.
func test_gait_planted_feet() -> void:
	print("gait: planted feet, swing clearance")
	for spec in [["stroll", 0.45, false, 0.08], ["walk", 1.0, false, 0.15], ["run", 1.0, true, 0.3]]:
		await place(open(), 0.4)
		inp(Vector2(0, -spec[1]), spec[2])
		await seconds(1.5 if quick else 2.0)
		var prev := {}
		var slip := 0.0
		var n := 0
		var clear := 0.0
		var lo := INF
		var knee := INF
		var g = steps()
		for i in int(1.5 / TICK):
			await physics_frame
			lo = minf(lo, player.rig.pelvis().global_position.y - player.global_position.y)
			knee = minf(knee, minf(knee_bend("l"), knee_bend("r")))
			for s: StringName in [&"l", &"r"]:
				var p := player.rig.display_transform(player.rig.bones[StringName("foot_" + s)]).origin
				if g.stance[s] > 0.2 and g.stance[s] < 0.5 and prev.has(s):
					slip += Vector2(p.x - prev[s].x, p.z - prev[s].z).length() / TICK
					n += 1
				if g.swing[s] >= 0.0:
					clear = maxf(clear, p.y - 0.035 - player.global_position.y)
				prev[s] = p
		inp()
		slip /= maxf(n, 1)
		check("%s: planted feet don't slide" % spec[0], n > 0 and slip < 0.1, "(%.3f m/s)" % slip)
		check("%s: swinging feet clear the ground" % spec[0], clear > spec[3], "(%.2f m)" % clear)
		check("%s: hips stay up (no lunging)" % spec[0], lo > 0.82, "(pelvis min %.2f m)" % lo)
		check("%s: knees never bend backwards" % spec[0], knee > -0.01, "(worst %.3f m)" % knee)


## How far the displayed knee sits in front of the hip-ankle line, along the foot's forward
## direction (negative: the knee is bent backwards).
func knee_bend(s: String) -> float:
	var r := player.rig
	var hip := r.display_transform(r.bones[StringName("thigh_" + s)]) * ((r.bones[StringName("thigh_" + s)] as PuppetBone).def.pivot - (r.bones[StringName("thigh_" + s)] as PuppetBone).def.center)
	var shin: PuppetBone = r.bones[StringName("shin_" + s)]
	var knee := r.display_transform(shin) * (shin.def.pivot - shin.def.center)
	var foot: PuppetBone = r.bones[StringName("foot_" + s)]
	var ft := r.display_transform(foot)
	var ankle := ft * (foot.def.pivot - foot.def.center)
	var dir := (ankle - hip).normalized()
	var off := (knee - hip) - dir * (knee - hip).dot(dir)
	# Forward = where the hips face (a swinging foot may point down or back, e.g. sprinting).
	var fwd := -r.display_transform(r.pelvis()).basis.z
	fwd.y = 0.0
	return off.dot(fwd.normalized())


## Stopping settles the feet under the hips; turning on the spot steps the feet round.
func test_gait_stop_and_turn() -> void:
	print("gait: stop settles, turning steps")
	await place(open(), 0.4)
	inp(Vector2(0, -1))
	await seconds(1.5)
	inp()
	await seconds(2.0)
	var g = steps()   # the mocap player when clips drive the legs, else the FootPlanner
	var ok := true
	for s: StringName in [&"l", &"r"]:
		var side := -1.0 if s == &"l" else 1.0
		var home := player.root_transform() * Vector3(side * FootPlanner.HIP_X, 0, 0)
		var p: Vector3 = (g.feet[s] as Transform3D).origin
		ok = ok and Vector2(p.x - home.x, p.z - home.z).length() < 0.2 and g.stance[s] >= 0.0
	check("after stopping, both feet are planted under the hips", ok)
	var ph: float = g.phase
	await seconds(0.5)
	check("standing still doesn't keep stepping", is_equal_approx(g.phase, ph))
	player.facing_yaw += 1.4   # turn on the spot
	await seconds(2.0)
	var yaw_err := 0.0
	for s: StringName in [&"l", &"r"]:
		var f: Vector3 = -(g.feet[s] as Transform3D).basis.z
		yaw_err = maxf(yaw_err, absf(wrapf(atan2(-f.x, -f.z) - player.facing_yaw, -PI, PI)))
	check("turning on the spot steps the feet round", yaw_err < 0.5, "(worst foot %.2f rad off)" % yaw_err)


## Forward swing (rad, + = forward) of a displayed limb segment, in the body's forward plane.
func segment_pitch(bone: StringName) -> float:
	var b: PuppetBone = player.rig.bones[bone]
	var t := player.rig.display_transform(b)
	var d := t * (b.def.center - b.def.pivot) - t.origin
	return atan2(d.dot(player.facing_dir()), -d.y)


static func correlation(a: Array, b: Array) -> float:
	var ma: float = a.reduce(func(s, x): return s + x, 0.0) / a.size()
	var mb: float = b.reduce(func(s, x): return s + x, 0.0) / b.size()
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in a.size():
		sab += (a[i] - ma) * (b[i] - mb)
		saa += (a[i] - ma) * (a[i] - ma)
		sbb += (b[i] - mb) * (b[i] - mb)
	return sab / sqrt(maxf(saa * sbb, 1e-9))


## Arms swing against the legs: left arm forward while the right leg is forward.
func test_gait_arms_contralateral() -> void:
	print("gait: contralateral arm swing")
	for spec in [["walk", 0.45, false], ["jog", 1.0, false], ["run", 1.0, true]]:
		await place(open(), 0.4)
		inp(Vector2(0, -spec[1]), spec[2])
		await seconds(1.5 if quick else 2.0)
		var arm_l := []
		var arm_r := []
		var legs := []
		for i in int(1.5 / TICK):
			await physics_frame
			arm_l.append(segment_pitch(&"upper_arm_l"))
			arm_r.append(segment_pitch(&"upper_arm_r"))
			legs.append(segment_pitch(&"thigh_r") - segment_pitch(&"thigh_l"))
		inp()
		var cl := correlation(arm_l, legs)
		var cr := correlation(arm_r, legs)
		var need := 0.45 if mocap_on() else 0.7   # mocap arm swing is looser than the procedural one
		check("%s: left arm swings with the right leg, right arm with the left" % spec[0], cl > need and cr < -need,
			"(left arm vs right-left legs %.2f, right arm %.2f)" % [cl, cr])


## Slalom and a turn-around at speed: feet don't cross or twist under the body, the body
## leans into the turns, knees keep bending forward.
func test_gait_turns() -> void:
	print("gait: slalom and turn-around")
	await place(open() + Vector3(0, 0, 20), 0.4)
	inp(Vector2(0, -1), true)
	await seconds(1.5)
	var g = steps()
	var cross := -INF
	var twist := 0.0
	var knee := INF
	var bank_ok := 0
	var bank_n := 0
	var t := 0.0
	for i in int(5.5 / TICK):
		if t < 4.0:
			var a := sin(t * 2.6) * 0.9
			player.external_input = {"move": Vector2(sin(a), -cos(a)), "run": true}
		else:
			inp(Vector2(0, 1), true)   # turn around at speed
		await physics_frame
		t += TICK
		var right := Basis(Vector3.UP, player.facing_yaw) * Vector3.RIGHT
		var fl: Vector3 = (g.feet[&"l"] as Transform3D).origin
		var fr: Vector3 = (g.feet[&"r"] as Transform3D).origin
		if t < 4.0 or t > 4.9:   # mid-pivot the feet may pass each other for a moment
			cross = maxf(cross, (fl - fr).dot(right))
		knee = minf(knee, minf(knee_bend("l"), knee_bend("r")))
		var pel := player.rig.display_transform(player.rig.pelvis()).basis
		for s: StringName in [&"l", &"r"]:
			if g.stance[s] >= 0.0:
				var ff := -(g.feet[s] as Transform3D).basis.z
				var pf := -pel.z
				twist = maxf(twist, absf(wrapf(atan2(-ff.x, -ff.z) - atan2(-pf.x, -pf.z), -PI, PI)))
		if t < 4.0 and absf(g.turn_rate) > 1.0 and player.horizontal_speed() > 5.0:
			bank_n += 1
			if signf(pel.y.dot(-right)) == signf(g.turn_rate):   # turning left: top leans left
				bank_ok += 1
	inp()
	await seconds(1.0)
	check("feet don't cross while turning", cross < 0.05, "(worst %.2f m)" % cross)
	check("planted feet stay under the body's heading (no twisted legs)", rad_to_deg(twist) < 60.0, "(worst %.0f°)" % rad_to_deg(twist))
	check("the body leans into the turns", bank_n > 0 and bank_ok > 0.9 * bank_n, "(%d of %d ticks)" % [bank_ok, bank_n])
	check("knees keep bending forward through the turns", knee > -0.01, "(worst %.3f m)" % knee)


## Mixamo-like clips built in memory (CI has no Mixamo files): see tests/mocap_fixture.gd.
func fixture_library() -> Dictionary:
	var lib := {}
	for kind in ["idle", "walk", "run"]:
		var sc := MocapFixture.make_scene(kind, 3)
		lib[kind] = MocapImporter.import_scene(sc, kind, true)
		sc.free()
	return lib


func use_clips(lib) -> void:
	LocomotionPlayer.library_override = lib
	player.pose_gen.loco = null   # rebuilt from the new library on the next tick


func test_mocap_import() -> void:
	print("mocap import: retarget a Mixamo-like rig (T-pose, cm, arbitrary bone axes)")
	var lib := fixture_library()
	var walk: MocapClip = lib.walk
	var idle: MocapClip = lib.idle
	check("bone names and tracks found, clip imported", walk != null and walk.frames > 30)
	check("root motion: walking speed scaled to the puppet", absf(walk.speed - 1.27) < 0.08 and idle.speed < 0.05,
		"(walk %.2f m/s, idle %.2f)" % [walk.speed, idle.speed])
	var cl := 0
	var cr := 0
	var both_air := 0
	for f in walk.frames:
		cl += walk.support_l[f]
		cr += walk.support_r[f]
		if walk.support_l[f] == 0 and walk.support_r[f] == 0:
			both_air += 1
	check("foot contacts found, alternating with double support",
		cl > walk.frames * 0.45 and cr > walk.frames * 0.45 and both_air == 0 and walk.touchdown_l >= 0,
		"(left %d, right %d of %d frames, both up %d)" % [cl, cr, walk.frames, both_air])
	var s := walk.sample(0.3)
	var chest := Basis(s.root_rot) * Basis(s.bones[&"spine"]) * Basis(s.bones[&"chest"])
	var arm_dir := chest * Basis(s.bones[&"upper_arm_l"]) * Vector3.DOWN
	check("arms hang down after retargeting from the T-pose", arm_dir.y < -0.85, "(arm direction %s)" % arm_dir)
	var ft := walk.sample(0.0).feet as Dictionary
	check("feet sit at ankle height on the ground", absf((ft[&"l"] as Vector3).y - 0.08) < 0.04, "(left ankle %.3f m)" % (ft[&"l"] as Vector3).y)


func test_mocap_locomotion() -> void:
	print("mocap locomotion: clips drive the puppet, feet locked while planted")
	use_clips(fixture_library())
	for spec in [["walk", 0.45, false], ["jog", 1.0, false]]:
		await place(open(), 0.4)
		inp(Vector2(0, -spec[1]), spec[2])
		await seconds(1.5 if quick else 2.0)
		var L: LocomotionPlayer = player.pose_gen.loco
		var prev := {}
		var slip := 0.0
		var n := 0
		var knee := INF
		var arm_l := []
		var legs := []
		for i in int(1.5 / TICK):
			await physics_frame
			knee = minf(knee, minf(knee_bend("l"), knee_bend("r")))
			arm_l.append(segment_pitch(&"upper_arm_l"))
			legs.append(segment_pitch(&"thigh_r") - segment_pitch(&"thigh_l"))
			for s: StringName in [&"l", &"r"]:
				var q := player.rig.display_transform(player.rig.bones[StringName("foot_" + s)]).origin
				if L.stance[s] > 0.1 and L.stance[s] < 0.6 and prev.has(s):
					slip += Vector2(q.x - prev[s].x, q.z - prev[s].z).length() / TICK
					n += 1
				prev[s] = q
		inp()
		check("%s: driven by the clips" % spec[0], player.pose_gen._clip_w > 0.99)
		check("%s: planted feet don't slide" % spec[0], n > 0 and slip / n < 0.05, "(%.3f m/s)" % (slip / maxf(n, 1)))
		check("%s: knees bend forward" % spec[0], knee > -0.01, "(worst %.3f m)" % knee)
		check("%s: arms swing against the legs (from the clip)" % spec[0], correlation(arm_l, legs) > 0.5,
			"(%.2f)" % correlation(arm_l, legs))
	await place(open(), 1.0)
	check("standing: both feet planted, clips still in charge", player.pose_gen._clip_w > 0.99
		and player.pose_gen.loco.stance[&"l"] >= 0.0 and player.pose_gen.loco.stance[&"r"] >= 0.0)
	use_clips(null)


## Walk start and turning on the spot play their clips (fixture "Start Walking", "Left Turn").
func test_mocap_transitions() -> void:
	print("mocap transitions: walk start, turning on the spot")
	var lib := fixture_library()
	for kind in [["start_walk", "Start Walking"], ["turn_left", "Left Turn"]]:
		var sc := MocapFixture.make_scene(kind[0], 3)
		lib[kind[1]] = MocapImporter.import_scene(sc, kind[1], false)
		sc.free()
	var turn: MocapClip = lib["Left Turn"]
	check("standing turn imported: about 90 degrees left, on the spot", absf(turn.turn - PI / 2) < 0.25 and turn.speed < 0.3,
		"(%.0f deg, %.2f m/s)" % [rad_to_deg(turn.turn), turn.speed])
	use_clips(lib)
	await place(open(), 1.0)
	var L: LocomotionPlayer = player.pose_gen.loco
	check("transition clips found", L.start_walk == lib["Start Walking"] and L.turns_stand == [turn])
	# Walk start: from standing, the start clip plays, then hands over to the walk cycle.
	inp(Vector2(0, -0.45))
	var started := false
	var prev := {}
	var slip := 0.0
	var n := 0
	var lo := INF
	for i in int(1.5 / TICK):
		await physics_frame
		started = started or (L.transition == &"start" and L._tr == lib["Start Walking"])
		lo = minf(lo, player.rig.pelvis().global_position.y - player.global_position.y)
		for s: StringName in [&"l", &"r"]:
			var q := player.rig.display_transform(player.rig.bones[StringName("foot_" + s)]).origin
			if L.stance[s] > 0.1 and L.stance[s] < 0.6 and prev.has(s):
				slip += Vector2(q.x - prev[s].x, q.z - prev[s].z).length() / TICK
				n += 1
			prev[s] = q
	check("walk start: the start clip plays", started)
	check("walk start: then the walk cycle takes over", L.transition == &"")
	check("walk start: planted feet don't slide", n > 0 and slip / n < 0.1, "(%.3f m/s)" % (slip / maxf(n, 1)))
	check("walk start: hips stay up", lo > 0.8, "(pelvis min %.2f m)" % lo)
	# Turning on the spot: a tap to the side steps the body round with the clip.
	inp()
	await place(open(), 1.0)
	L = player.pose_gen.loco
	var yaw0 := player.facing_yaw
	inp(Vector2(-1, 0))
	await seconds(0.15)
	inp()
	var turned := false
	var lag := 0.0
	lo = INF
	for i in int(2.0 / TICK):
		await physics_frame
		turned = turned or L.transition == &"turn_stand"
		lag = maxf(lag, absf(L._yaw_off))
		lo = minf(lo, player.rig.pelvis().global_position.y - player.global_position.y)
	var pel_f := -player.rig.display_transform(player.rig.pelvis()).basis.z
	var pel_err := absf(wrapf(atan2(-pel_f.x, -pel_f.z) - player.facing_yaw, -PI, PI))
	var feet_err := 0.0
	for s: StringName in [&"l", &"r"]:
		var f: Vector3 = -(L.feet[s] as Transform3D).basis.z
		feet_err = maxf(feet_err, absf(wrapf(atan2(-f.x, -f.z) - player.facing_yaw, -PI, PI)))
	check("turn on the spot: the turn clip plays", turned, "(turned %.0f deg)" % rad_to_deg(wrapf(player.facing_yaw - yaw0, -PI, PI)))
	check("turn on the spot: the body steps round (lags the capsule, doesn't snap)", lag > 0.3, "(max lag %.2f rad)" % lag)
	check("turn on the spot: body and feet end facing the new way", pel_err < 0.3 and feet_err < 0.5,
		"(pelvis %.2f, feet %.2f rad off)" % [pel_err, feet_err])
	check("turn on the spot: hips stay up", lo > 0.8, "(pelvis min %.2f m)" % lo)
	use_clips(null)


## With clips, the crowd's baked stroll and idle come from them (fixture clips here).
func test_mocap_crowd_bake() -> void:
	print("mocap crowd bake: VAT stroll and idle from the clips")
	var lib := fixture_library()
	use_clips(lib)
	CrowdVAT._cache = {}
	var vat := CrowdVAT.get_baked(self)
	CrowdVAT._cache = {}   # later tests bake whatever library they use
	var d: PackedFloat32Array = vat.pos_data
	var lo := Vector3.INF
	var hi := -Vector3.INF
	var finite := true
	for i in range(0, d.size(), 3):
		var p := Vector3(d[i], d[i + 1], d[i + 2])
		finite = finite and p.is_finite()
		lo = lo.min(p)
		hi = hi.max(p)
	check("baked from the clips", vat.mocap)
	check("baked animation has the character's size, feet on the ground", finite
		and hi.y - lo.y > 1.6 and hi.y - lo.y < 2.0 and absf(lo.y) < 0.1, "(%s .. %s)" % [lo, hi])
	var walk: MocapClip = lib.walk
	var run: MocapClip = lib.run
	var strides := [walk.speed * walk.cycle_length(), run.speed * run.cycle_length()]
	check("stroll cycle covers the clips' stride (feet don't slide)", vat.walk_cycle_m > strides.min() * 0.95
		and vat.walk_cycle_m < strides.max() * 1.05, "(%.2f m per cycle; clips %.2f .. %.2f)" % [vat.walk_cycle_m, strides.min(), strides.max()])
	check("idle loop is the idle clip's length", is_equal_approx(vat.idle_period, (lib.idle as MocapClip).length()))
	use_clips(null)


func test_mocap_fallback() -> void:
	print("mocap fallback: no clips -> procedural locomotion")
	use_clips({})
	await place(open(), 0.4)
	inp(Vector2(0, -1))
	await seconds(1.5)
	inp()
	check("without clips the procedural gait runs", player.pose_gen._clip_w == 0.0 and player.pose_gen.gait.weight > 0.9)
	use_clips(null)


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
