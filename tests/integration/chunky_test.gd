extends Node
## Chunky from the Chunky tab's operations on a real Paper server: install, tasks (an area,
## pause/continue/cancel, existing chunks only), trim with its safety backup, and the world
## name of an extra dimension. Needs network access (Modrinth).
## Usage: godot --headless --path . res://tests/integration/chunky_test.tscn -- --no-autostart --profile=ch --root=<dir> [--version=26.3]

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://chunky-test-servers")
	var version := "26.3"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--version="):
			version = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Chunky Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 2048, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	_check(created.ok, "create server")
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance
	var status: Dictionary = await inst.call_op("chunky_status")
	_check(status.ok and not status.installed, "not installed yet")
	var installed: Dictionary = await inst.call_op("plugin_install_modrinth", {"project_id": Chunky.MODRINTH_ID})
	_check(installed.ok, "Chunky installed from Modrinth: %s" % installed.get("error", ""))

	await _boot(inst)
	status = await inst.call_op("chunky_status")
	var names: Array = status.get("worlds", []).map(func(w: Dictionary) -> String: return w.name)
	_check(status.ready and names.has("world") and names.has("world_nether"), "ready, worlds %s" % [names])

	var started: Dictionary = await inst.call_op("chunky_start", {"task": {"world": "world", "mode": Chunky.Mode.AREA, "shape": "square", "center": Chunky.Center.SPAWN, "radius": 160}})
	_check(started.ok, "area task started: %s" % started.get("error", started.get("text", "")))
	await _wait_task(inst, "world", "finished", 60.0)
	_check(_task(inst, "world").get("state") == "finished" and int(_task(inst, "world").processed) > 300, "area generated: %s" % _task(inst, "world"))

	started = await inst.call_op("chunky_start", {"task": {"world": "world", "mode": Chunky.Mode.AREA, "shape": "circle", "center": Chunky.Center.COORDINATES, "x": 5000, "z": 5000, "radius": 3000}})
	await _wait_task(inst, "world", "running", 20.0)
	await get_tree().create_timer(3.0).timeout
	var paused: Dictionary = await inst.call_op("chunky_control", {"action": "pause", "world": "world"})
	await _wait_task(inst, "world", "paused", 10.0)
	_check(paused.ok and _task(inst, "world").get("state") == "paused", "paused")
	await inst.call_op("chunky_control", {"action": "continue", "world": "world"})
	await _wait_task(inst, "world", "running", 10.0)
	_check(_task(inst, "world").get("state") == "running" and float(_task(inst, "world").percent) > 0.0, "continued with progress: %s" % _task(inst, "world"))
	var cancelled: Dictionary = await inst.call_op("chunky_control", {"action": "cancel", "world": "world"})
	await get_tree().create_timer(1.0).timeout
	_check(cancelled.ok and _task(inst, "world").is_empty(), "cancelled: %s" % _task(inst, "world"))

	started = await inst.call_op("chunky_start", {"task": {"world": "world", "mode": Chunky.Mode.EXISTING}})
	await _wait_task(inst, "world", "finished", 120.0)
	_check(started.ok and _task(inst, "world").get("state") == "finished", "existing chunks loaded: %s" % _task(inst, "world"))

	var trimmed: Dictionary = await inst.call_op("chunky_trim", {"task": {"world": "world", "shape": "square", "center": Chunky.Center.SPAWN, "radius": 64}})
	_check(trimmed.ok and str(trimmed.get("backup", "")).ends_with("pre-trim.zip") and trimmed.restart_needed, "trim after a safety backup: %s" % trimmed.get("error", trimmed.get("reply", "")))
	await get_tree().create_timer(5.0).timeout
	await _stop(inst)

	# An extra dimension (the overworld copied in as "islands"): Paper names it world_minecraft_islands.
	var level := inst.config.directory.path_join("world")
	var lone := inst.config.directory.path_join("islands-source")
	FileOps.copy_tree(level.path_join("dimensions/minecraft/overworld"), lone)
	var a: Dictionary = await WorldImporter.analyze(self, lone, version)
	_check(a.ok and not a.dimension_choices.is_empty(), "dimension analysed")
	if a.ok and not a.dimension_choices.is_empty():
		WorldImporter.place_dimension(a.dimension_choices[0], level, "islands")
	FileOps.remove_tree(lone)
	await _boot(inst)
	status = await inst.call_op("chunky_status")
	names = status.get("worlds", []).map(func(w: Dictionary) -> String: return w.name)
	_check(names.has("world_minecraft_islands"), "extra dimension listed: %s" % [names])
	started = await inst.call_op("chunky_start", {"task": {"world": "world_minecraft_islands", "mode": Chunky.Mode.EXISTING}})
	_check(started.ok, "Chunky accepts the extra dimension's name: %s" % started.get("error", ""))
	await _wait_task(inst, "world_minecraft_islands", "finished", 60.0)
	_check(_task(inst, "world_minecraft_islands").get("state") == "finished", "its existing chunks loaded")
	await _stop(inst)
	if _failures.is_empty():
		ServerManager.delete_server(inst.config.id, true, true)
	_finish()


func _task(inst: ServerInstance, world: String) -> Dictionary:
	return inst.chunky_tasks.get(world, {})


func _wait_task(inst: ServerInstance, world: String, state: String, timeout_sec: float) -> void:
	await _wait_for(func() -> bool: return _task(inst, world).get("state", "") == state, timeout_sec)


func _boot(inst: ServerInstance) -> void:
	inst.start()
	await _wait_for(func() -> bool: return (inst.is_online() and inst.rcon.is_ready()) or inst.state == ServerInstance.State.CRASHED, 240.0)
	_check(inst.is_online() and inst.rcon.is_ready(), "server boots")


func _stop(inst: ServerInstance) -> void:
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 120.0)


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nChunky test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
