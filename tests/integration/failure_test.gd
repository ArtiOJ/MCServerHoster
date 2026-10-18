extends Node
## A boot that fails (here: the port gets taken right after the start check) must be
## reported as a failed start with a plain-language reason, never as a clean stop.
## Usage: godot --headless --path . res://tests/integration/failure_test.tscn -- --no-autostart --profile=ff --root=<dir>

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://failure-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Failure Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	var inst: ServerInstance = created.instance
	inst.config.auto_restart = false
	inst.save_config()

	_check(inst.start() == OK, "start accepted (port was free at the check)")
	var squatter := TCPServer.new()
	_check(squatter.listen(inst.config.port, "*") == OK, "test grabbed the port before Paper bound it")
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 120.0)
	squatter.stop()
	_check(inst.state == ServerInstance.State.CRASHED, "reported as failed, not stopped (state %s)" % inst.state_name())
	_check(_console_has(inst, "failed to start"), "console says the start failed")
	_check(_console_has(inst, "Port %d is already in use" % inst.config.port), "console explains the port conflict")

	_check(inst.start() == OK, "start again once the port is free")
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	_check(inst.is_online(), "server comes online")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)
	_check(inst.state == ServerInstance.State.STOPPED, "a normal stop is still a stop")
	ServerManager.delete_server(inst.config.id, true, true)
	print("\nFailure test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _console_has(inst: ServerInstance, text: String) -> bool:
	return inst.console_lines.any(func(e: Dictionary) -> bool: return (e.plain as String).contains(text))


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
