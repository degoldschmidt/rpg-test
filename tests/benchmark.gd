extends SceneTree
## Character cost benchmark. Run:
##   godot --headless --fixed-fps 120 --path . -s tests/benchmark.gd [-- --counts=1,10,25 --out=docs/performance.md]
## Spawns N characters on a flat floor per scenario and measures wall-clock time per physics tick.

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const WARMUP := 120
const TICKS := 600

var counts: Array = [1, 10, 25, 50, 100]
var scenarios: Array = ["idle", "walk", "ragdoll", "walk_kinematic", "walk_proxy"]
var out_path := ""
var rows: Array = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--counts="):
			counts = Array(a.trim_prefix("--counts=").split(",")).map(func(x): return int(x))
		elif a.begins_with("--scenarios="):
			scenarios = Array(a.trim_prefix("--scenarios=").split(","))
		elif a.begins_with("--out="):
			out_path = a.trim_prefix("--out=")
	_run()


func _run() -> void:
	InputSetup.ensure_actions()
	for sc in scenarios:
		for n in counts:
			rows.append(await _measure(sc, n))
	var md := _table()
	print(md)
	if out_path != "":
		var f := FileAccess.open("res://" + out_path, FileAccess.WRITE)
		f.store_string(md)
	quit()


func _world() -> Node3D:
	var w := Node3D.new()
	root.add_child(w)
	LevelUtil.box(w, Vector3(400, 1, 400), Transform3D(Basis(), Vector3(0, -0.5, 0)), Color.GRAY)
	return w


func _measure(scenario: String, n: int) -> Dictionary:
	var w := _world()
	var chars: Array[PlayerController] = []
	var side := int(ceil(sqrt(n)))
	for i in n:
		var c: PlayerController = PLAYER_SCENE.instantiate()
		c.use_external_input = true
		if scenario == "walk_kinematic" or scenario == "walk_proxy":
			c.lod_enabled = true
			c.lod_force = CharacterLOD.Tier.KINEMATIC if scenario == "walk_kinematic" else CharacterLOD.Tier.PROXY_ONLY
		c.position = Vector3((i % side) * 4.0, 0, (i / side) * 4.0)
		w.add_child(c)
		chars.append(c)
	await physics_frame
	for i in WARMUP + TICKS:
		_drive(scenario, chars, i)
		if i == WARMUP:
			PlayerController.profile = true
			PlayerController.profile_usec = 0
		var t0 := Time.get_ticks_usec()
		await process_frame
		if i == WARMUP:
			rows_tmp = {"wall": 0}
		if i >= WARMUP:
			rows_tmp.wall += Time.get_ticks_usec() - t0
	PlayerController.profile = false
	var r := {
		"scenario": scenario, "n": n,
		"wall_ms": rows_tmp.wall / 1000.0 / TICKS,
		"script_ms": PlayerController.profile_usec / 1000.0 / TICKS,
	}
	r["other_ms"] = r.wall_ms - r.script_ms
	r["per_char_ms"] = r.wall_ms / n
	print("%-9s n=%3d  %.2f ms/tick (controller script %.2f, physics+drive+skin %.2f)  %.3f ms/char" % [scenario, n, r.wall_ms, r.script_ms, r.other_ms, r.per_char_ms])
	w.queue_free()
	await process_frame
	await process_frame
	return r


var rows_tmp := {}


func _drive(scenario: String, chars: Array[PlayerController], i: int) -> void:
	for k in chars.size():
		var c := chars[k]
		match scenario:
			"walk", "walk_kinematic", "walk_proxy":
				var a := i * 0.01 + k
				c.external_input = {"move": Vector2(cos(a), sin(a))}
			"ragdoll":
				if c.state != PlayerController.State.RAGDOLL:
					c.enter_ragdoll()
			_:
				c.external_input = {}


func _table() -> String:
	var s := "| Scenario | Characters | ms / tick | controller script ms | physics + drive + skin ms | ms / character |\n|---|---|---|---|---|---|\n"
	for r in rows:
		s += "| %s | %d | %.2f | %.2f | %.2f | %.3f |\n" % [r.scenario, r.n, r.wall_ms, r.script_ms, r.other_ms, r.per_char_ms]
	return s
