extends Node
## End-to-end test: downloads a real Paper build, boots it, queries it over RCON,
## takes a live backup, stops it and deletes it again. Needs network + Java.
## Usage: godot --headless --path . res://tests/integration/integration_test.tscn -- --no-autostart --profile=it [--root=/tmp/x] [--version=1.21.11]

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://integration-servers")
	var version := "1.21.11"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--version="):
			version = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	print("Servers root: ", root)

	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	_check(vinfo.ok, "version info: %s" % vinfo.get("error", ""))
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	_check(latest.ok, "latest build: %s" % latest.get("error", ""))
	if not _failures.is_empty():
		return _finish()
	print("Paper %s build #%d, Java %d+" % [version, latest.build.id, vinfo.java_min])

	var created: Dictionary = await ServerManager.create_server({
		"name": "Integration Test",
		"version": version,
		"build": latest.build,
		"version_info": vinfo,
		"ram_max_mb": 1536,
		"ram_min_mb": 512,
		"port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4", "simulation-distance": "4"},
	}, func(stage: String, _f: float) -> void: pass)
	_check(created.ok, "create: %s" % created.get("error", ""))
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance
	inst.console_line_added.connect(func(e: Dictionary) -> void: print("  | ", e.plain))
	inst.config.cpu_quota_pct = 400
	inst.config.cpu_affinity = "0-3"
	inst.config.memory_hard_cap = true
	inst.save_config()

	_check(inst.start() == OK, "start returns OK")
	await _wait_for(func() -> bool: return inst.state in [ServerInstance.State.RUNNING, ServerInstance.State.CRASHED], 240.0)
	_check(inst.state == ServerInstance.State.RUNNING, "server reached RUNNING (state=%s)" % inst.state_name())
	if inst.state == ServerInstance.State.RUNNING:
		var pid := inst.process.pid
		var cgroup := PlatformBackend.read_text("/proc/%d/cgroup" % pid)
		_check(cgroup.contains(".scope"), "process runs in a systemd scope: " + cgroup)
		_check(PlatformBackend.read_text("/proc/%d/comm" % pid).strip_edges() == "java", "tracked PID is the JVM")
		await _wait_for(func() -> bool: return inst.tps >= 0.0, 30.0)
		_check(inst.tps > 0.0, "TPS via RCON (%.2f)" % inst.tps)
		_check(inst.max_players > 0, "max players via RCON")
		_check(inst.monitor.rss_bytes > 0, "RSS sampled (%s)" % Fmt.bytes(inst.monitor.rss_bytes))
		inst.send_command("say integration-hello")
		await _wait_for(func() -> bool: return inst.console_lines.any(func(e: Dictionary) -> bool: return e.plain.contains("integration-hello") and e.level != LogParser.Level.COMMAND), 10.0)
		_check(inst.console_lines.any(func(e: Dictionary) -> bool: return e.plain.contains("[Server] integration-hello")), "command echoed by server")
		var backup: String = await inst.backups.create_backup(false)
		_check(backup != "" and FileAccess.file_exists(backup), "live world backup created")
		inst.stop()
		await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)
		_check(inst.state == ServerInstance.State.STOPPED, "stopped cleanly (state=%s)" % inst.state_name())
		_check(inst.last_exit_code == 0, "exit code 0")
		if backup != "":
			_check(await inst.backups.restore_backup(backup) == OK, "restore backup")
			_check(inst.backups.list_backups().any(func(b: Dictionary) -> bool: return b.name.ends_with("_pre-restore.zip")), "safety backup saved before restoring")

	var del := ServerManager.delete_server(inst.config.id, true, true)
	_check(del == OK, "delete server (%s)" % error_string(del))
	_finish()


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nIntegration: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
