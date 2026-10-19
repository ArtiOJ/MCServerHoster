extends Node
## End-to-end test for the event engine and PowerManager with a real Paper server.
## Sleep/wake are simulated by feeding PowerManager the lines logind would send;
## the computer itself never sleeps. Inhibitor locks are checked with `systemd-inhibit --list`.
## Usage: godot --headless --path . res://tests/integration/events_test.tscn -- --no-autostart --profile=ev --root=<dir>

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://events-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	AppSettings.sleep_policy = AppSettings.SleepPolicy.BLOCK_WHILE_PLAYERS
	AppSettings.restart_after_wake = true
	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Events Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	_check(created.ok, "create server")
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance
	# With the wake helper installed, a timed Start event legitimately holds a sleep lock to arm
	# the wake alarm; this test checks the server locks only (wake_sleep_test covers waking).
	AppSettings.wake_for_events = false

	# Timed START at the next minute, a broadcast when online, and stop-when-empty after 6 s.
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var local := int(Time.get_unix_time_from_system()) + bias + 60
	var start_rule := EventRule.from_template({"trigger": EventRule.Trigger.TIME, "action": EventRule.Action.START,
			"time_of_day": "%02d:%02d" % [posmod(local, 86400) / 3600, posmod(local, 3600) / 60]})
	var hello := EventRule.from_template({"trigger": EventRule.Trigger.SERVER_ONLINE, "action": EventRule.Action.BROADCAST, "text": "hello-from-event"})
	var empty_stop := EventRule.from_template({"trigger": EventRule.Trigger.SERVER_EMPTY, "threshold": 0.1, "action": EventRule.Action.STOP, "enabled": false})
	var wrong_day := EventRule.from_template({"trigger": EventRule.Trigger.SERVER_ONLINE, "action": EventRule.Action.BROADCAST, "text": "never-today", "weekdays": EventRule.ALL_DAYS & ~(1 << Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_system()) + bias).weekday)})
	inst.config.events = [start_rule, hello, empty_stop, wrong_day]
	inst.save_config()

	print("Waiting for the timed start at %s…" % start_rule.time_of_day)
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	_check(inst.is_online(), "TIME event started the server")
	await _wait_for(func() -> bool: return _console_has(inst, "[Server] hello-from-event"), 10.0)
	_check(_console_has(inst, "[Server] hello-from-event"), "SERVER_ONLINE event broadcast a message")
	_check(not _console_has(inst, "never-today"), "rule restricted to other weekdays did not fire")

	# Inhibitor locks: delay lock while a server runs, block lock only per policy.
	await get_tree().create_timer(2.5).timeout
	_check(_inhibitors().contains("Stopping Minecraft servers cleanly"), "delay lock held while a server runs")
	_check(not _inhibitors().contains("Minecraft servers are in use"), "no block lock with no players online")
	AppSettings.sleep_policy = AppSettings.SleepPolicy.BLOCK_WHILE_RUNNING
	PowerManager.update_locks()
	await get_tree().create_timer(0.5).timeout
	_check(_inhibitors().contains("Minecraft servers are in use"), "block lock with 'block while running'")
	AppSettings.sleep_policy = AppSettings.SleepPolicy.BLOCK_WHILE_PLAYERS
	PowerManager.update_locks()
	await get_tree().create_timer(0.5).timeout
	_check(not _inhibitors().contains("Minecraft servers are in use"), "block lock released when policy changes")

	# Simulated sleep → servers stop and the delay lock is released; wake → restarted.
	PowerManager.handle_monitor_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)")
	await _wait_for(func() -> bool: return not inst.is_process_alive(), PowerManager.max_delay_sec + 2.0)
	_check(not inst.is_process_alive(), "server stopped before sleep (within %.0f s)" % PowerManager.max_delay_sec)
	await get_tree().create_timer(1.0).timeout
	_check(not _inhibitors().contains("Stopping Minecraft servers cleanly"), "delay lock released so the system can sleep")
	PowerManager.handle_monitor_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)")
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	_check(inst.is_online(), "server restarted after wake")

	# Stop when empty.
	empty_stop.enabled = true
	inst.save_config()
	# The process can be gone a moment before the manager handles its exit and leaves STOPPING.
	await _wait_for(func() -> bool: return inst.state == ServerInstance.State.STOPPED, 30.0)
	_check(inst.state == ServerInstance.State.STOPPED, "SERVER_EMPTY event stopped the idle server")
	await get_tree().create_timer(2.5).timeout
	_check(not _inhibitors().contains("Stopping Minecraft servers cleanly"), "no locks once all servers stopped")

	ServerManager.delete_server(inst.config.id, true, true)
	_check(not DirAccess.dir_exists_absolute(inst.config.directory), "server folder deleted permanently")
	_finish()


func _console_has(inst: ServerInstance, text: String) -> bool:
	return inst.console_lines.any(func(e: Dictionary) -> bool: return (e.plain as String).contains(text))


func _inhibitors() -> String:
	var out: Array = []
	OS.execute("systemd-inhibit", ["--list", "--no-pager", "--no-legend"], out)
	return str(out[0]) if not out.is_empty() else ""


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nEvents test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
