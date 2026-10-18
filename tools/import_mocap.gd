extends SceneTree
## Imports the Mixamo clips in assets/animations/mixamo/ (retarget, root motion, foot contacts),
## caches them in user://mocap_cache/ so the game starts without re-importing, and lists what
## each clip is used for.
## Run: godot --headless --path . --import; godot --headless --path . -s tools/import_mocap.gd


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	var lib := MocapImporter.load_library(LocomotionPlayer.MOCAP_DIR)
	if lib.is_empty():
		print("No clips in %s (see the README there for which to download)." % LocomotionPlayer.MOCAP_DIR)
		quit()
		return
	var lp := LocomotionPlayer.new()
	var roles := {}
	if lp.idle:
		roles[lp.idle] = "idle"
	for c in lp.cycles:
		roles[c] = "cycle"
	for pair in [[lp.stop_walk, "walk stop"], [lp.stop_run, "run stop"], [lp.start_walk, "walk start"],
			[lp.start_run, "sprint start"], [lp.turn_run, "run turn-around"]]:
		if pair[0]:
			roles[pair[0]] = pair[1]
	for c in lp.turns_stand:
		roles[c] = "turn on the spot"
	var names := lib.keys()
	names.sort()
	print("%-24s %6s %5s %7s %7s  %s" % ["clip", "length", "loop", "speed", "turn", "used as"])
	for n: String in names:
		var c: MocapClip = lib[n]
		print("%-24s %5.2fs %5s %5.2f/s %+6.0f°  %s" % [n, c.length(), "yes" if c.loop else "no", c.speed,
			rad_to_deg(c.turn), roles.get(c, "-")])
	print("%d clips imported and cached in %s (%d ms)." % [lib.size(), ProjectSettings.globalize_path(MocapImporter.CACHE_DIR),
		Time.get_ticks_msec() - t0])
	quit()
