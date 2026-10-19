extends Node
## Changing a server's port from the app and by editing server.properties by hand.
## Usage: godot --headless --path . res://tests/integration/port_test.tscn -- --no-autostart --profile=pt --root=<dir>

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://port-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Port Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	var inst: ServerInstance = created.instance
	var a := inst.config.port
	inst.config.wake_on_connect = true
	inst.save_config()
	await _wait_for(func() -> bool: return inst.is_asleep(), 5.0)
	_check(inst.is_asleep() and not PlatformBackend.is_port_free(a), "asleep and listening on port %d" % a)
	_check(not inst.start_problem().contains("another program"), "its own listener isn't reported as another program: %s" % inst.start_problem())
	var own: Dictionary = ServerOps.port_check(inst, a)
	_check(own.free and own.own, "port check counts the listener as the server's own")

	var b := _free_port(a + 100)
	_check(inst.set_port(b) == "", "change port from the app to %d" % b)
	await get_tree().create_timer(0.5).timeout
	_check(inst.get_properties().get_int("server-port") == b and inst.get_properties().get_int("query.port") == b, "server.properties updated")
	_check(not PlatformBackend.is_port_free(b) and PlatformBackend.is_port_free(a), "start-on-connect moved to the new port")
	var other := ServerManager.port_owner(b, "")
	_check(other == inst, "port registered for this server")

	# Manual edit: change server-port in the file, as a user would in a text editor.
	var c := _free_port(b + 100)
	inst.config.wake_on_connect = false
	inst.save_config()
	var props := ServerProperties.load_file(inst.config.properties_path())
	props.set_value("server-port", c)
	props.save_file(inst.config.properties_path())
	_check(inst.start() == OK, "start after the manual edit")
	_check(inst.config.port == c, "manual edit adopted (config now %d)" % inst.config.port)
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	_check(inst.console_lines.any(func(e: Dictionary) -> bool: return (e.plain as String).contains("Starting Minecraft server on *:%d" % c)), "Paper bound the manually chosen port %d" % c)
	_check(inst.get_properties().get_int("server-port") == c, "the manual edit was not overwritten")
	var clash_msg := inst.set_port(inst.config.rcon_port)
	_check(clash_msg == "" and inst.config.rcon_port != inst.config.port, "choosing the RCON port moves RCON elsewhere")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)
	ServerManager.delete_server(inst.config.id, true, true)
	print("\nPort test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _free_port(start: int) -> int:
	var p := start
	while not PlatformBackend.is_port_free(p) or ServerManager.port_owner(p, "") != null:
		p += 1
	return p


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
