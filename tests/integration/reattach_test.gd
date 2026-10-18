extends Node
## Re-attach test, run as two separate app launches sharing one settings profile:
##   --phase=1  create + start a server, then quit WITHOUT stopping it (like "Quit, leave running")
##   --phase=2  a fresh launch must re-attach: console from the log, commands over RCON, stop works
## Phase 2 deletes the PID file first, forcing discovery by scanning for the Java process.
## Usage: godot --headless --path . res://tests/integration/reattach_test.tscn -- --no-autostart --profile=ra --root=<dir> --phase=1|2

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://reattach-test-servers")
	var phase := 1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--phase="):
			phase = arg.get_slice("=", 1).to_int()
	if phase == 1:
		await _phase_one(root)
	else:
		await _phase_two()
	_finish()


func _phase_one(root: String) -> void:
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Reattach Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	_check(created.ok, "create server")
	var inst: ServerInstance = created.instance
	inst.start()
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	_check(inst.is_online(), "server online in the first session")
	print("PHASE1_PID=%d" % inst.process.pid)
	# Remove the PID file so phase 2 must find the server by scanning processes.
	DirAccess.remove_absolute(inst.config.meta_dir().path_join("server.pid"))


func _phase_two() -> void:
	var instances := ServerManager.get_instances()
	_check(instances.size() == 1, "server registered from the saved profile")
	if instances.is_empty():
		return
	var inst := instances[0]
	await _wait_for(func() -> bool: return inst.is_online() and inst.rcon.is_ready(), 30.0)
	_check(inst.process.is_attached(), "re-attached to the running process")
	_check(inst.is_online(), "state is Running after re-attach")
	_check(inst.rcon.is_ready() and inst.can_send_commands(), "commands available over RCON")
	_check(inst.uptime_seconds() > 5, "uptime reflects the real process age (%ds)" % inst.uptime_seconds())
	_check(inst.console_lines.any(func(e: Dictionary) -> bool: return (e.plain as String).contains("Done (")), "console shows recent log backlog")
	_check(inst.monitor.rss_bytes > 0 or await _rss(inst), "resource monitor tracks the re-attached PID")

	inst.send_command("say reattached-hello")
	await _wait_for(func() -> bool: return _console_has(inst, "reattached-hello") and _count(inst, "reattached-hello") >= 2, 10.0)
	_check(_console_has(inst, "[Rcon] reattached-hello") or _console_has(inst, "[Server] reattached-hello"), "command reached the server; its log line was tailed")
	inst.send_command("list")
	await _wait_for(func() -> bool: return _console_has(inst, "players online"), 10.0)
	_check(_console_has(inst, "players online"), "RCON reply shown in the console")
	_check(LogParser.level_of("[19:16:01] [Server thread/INFO]: hi") == LogParser.Level.INFO, "log-file line format parsed")

	var pid := inst.process.pid
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)
	_check(inst.state == ServerInstance.State.STOPPED, "graceful stop of the re-attached server (state %s)" % inst.state_name())
	_check(not PlatformBackend.get_current().is_pid_alive(pid), "process really exited")
	_check(inst.start() == OK, "normal start afterwards")
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	_check(inst.is_online() and not inst.process.is_attached(), "running normally with pipes again")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)
	ServerManager.delete_server(inst.config.id, true, true)


func _rss(inst: ServerInstance) -> bool:
	await get_tree().create_timer(1.5).timeout
	return inst.monitor.rss_bytes > 0


func _console_has(inst: ServerInstance, text: String) -> bool:
	return inst.console_lines.any(func(e: Dictionary) -> bool: return (e.plain as String).contains(text))


func _count(inst: ServerInstance, text: String) -> int:
	return inst.console_lines.filter(func(e: Dictionary) -> bool: return (e.plain as String).contains(text)).size()


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nReattach test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
