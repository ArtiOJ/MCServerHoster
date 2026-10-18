extends Node
## End-to-end test for creation-time settings (properties, Paper/Spigot/Bukkit YAML,
## game rules), temporary runs (keep and discard) and duplicating a running server.
## Needs network + Java. Usage:
## godot --headless --path . res://tests/integration/feature_test.tscn -- --no-autostart --profile=ft --root=<dir> [--version=26.3]

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://feature-test-servers")
	var version := "26.3"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--version="):
			version = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()

	# PvP is a game rule from 1.21.9 and a server.properties key before that.
	var pvp_is_rule := SettingsCatalog.applies_to(SettingsCatalog.get_entry("gamerule.pvp"), version)
	var pvp_id := "gamerule.pvp" if pvp_is_rule else "pvp"
	var keep_rule := SettingsCatalog.rule_name(SettingsCatalog.get_entry("gamerule.keep_inventory"), version)
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Feature Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
		"settings": {
			"motd": "Feature test",
			"gamerule.keep_inventory": "true",
			pvp_id: "false",
			"bukkit.yml::settings.allow-end": "false",
			"config/paper-world-defaults.yml::misc.redstone-implementation": "ALTERNATE_CURRENT",
			"spigot.yml::world-settings.default.mob-spawn-range": "6",
		},
	})
	_check(created.ok, "create with settings: %s" % created.get("error", ""))
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance
	var dir := inst.config.directory
	_check(inst.config.pending_gamerules.size() == (2 if pvp_is_rule else 1), "game rules queued before first boot")

	# --- First boot: game rules applied, YAML preserved -----------------------
	await _boot(inst, "first boot")
	await _wait_for(func() -> bool: return inst.config.known_gamerules.get("gamerule.keep_inventory", "") == "true", 20.0)
	_check(inst.config.pending_gamerules.is_empty(), "pending game rules cleared after boot")
	_check(LogParser.parse_gamerule(await inst.rcon.execute("gamerule " + keep_rule)) == "true", "keep inventory is true on the server (%s)" % keep_rule)
	if pvp_is_rule:
		_check(LogParser.parse_gamerule(await inst.rcon.execute("gamerule pvp")) == "false", "pvp game rule is false on the server")
	else:
		_check(inst.get_properties().get_value("pvp") == "false", "pvp property survived boot")
	_check(inst.config.known_gamerules.get("gamerule.spawn_mobs", "") == "true", "refresh_gamerules read untouched rules")
	var settings := ServerSettings.open(inst.config)
	_check(settings.get_value(SettingsCatalog.get_entry("bukkit.yml::settings.allow-end")) == "false", "bukkit allow-end survived boot")
	_check(settings.get_value(SettingsCatalog.get_entry("config/paper-world-defaults.yml::misc.redstone-implementation")) == "ALTERNATE_CURRENT", "paper redstone survived boot")
	_check(settings.get_value(SettingsCatalog.get_entry("spigot.yml::world-settings.default.mob-spawn-range")) == "6", "spigot spawn range survived boot")
	_check(YamlDoc.load_file(dir.path_join("config/paper-world-defaults.yml")).has("anticheat.anti-xray.enabled"), "Paper completed the partial file")

	# --- Live game rule change while online ----------------------------------
	var live := ServerSettings.open(inst.config)
	live.set_by_id("gamerule.keep_inventory", "false")
	live.save()
	inst.apply_pending_gamerules()
	await get_tree().create_timer(1.0).timeout
	_check(LogParser.parse_gamerule(await inst.rcon.execute("gamerule " + keep_rule)) == "false", "game rule changed live")

	# --- Duplicate while running ------------------------------------------------
	var dup: Dictionary = await ServerManager.duplicate_server(inst, "Feature Copy", true, false)
	_check(dup.ok, "duplicate running server: %s" % dup.get("error", ""))
	if dup.ok:
		var copy: ServerInstance = dup.instance
		_check(copy.config.port != inst.config.port and copy.config.rcon_port != inst.config.rcon_port, "copy has its own ports")
		_check(DirAccess.dir_exists_absolute(copy.config.directory.path_join("world")), "copy has the world")
		_check(not DirAccess.dir_exists_absolute(copy.config.directory.path_join("plugins")), "copy has no plugins folder")
		await _boot(copy, "copy boots alongside original")
		_check(inst.is_online() and copy.is_online(), "original and copy run at the same time")
		copy.stop()
		await _wait_for(func() -> bool: return not copy.is_process_alive(), 90.0)
		ServerManager.delete_server(copy.config.id, true, false, true)

	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)

	# --- Temporary run, discarded ------------------------------------------------
	var ended := [0]
	inst.temporary_run_ended.connect(func() -> void: ended[0] += 1)
	_check(await inst.start_temporary() == OK, "temporary start (discard case)")
	var temp := inst.config.temp_run_dir
	_check(temp != "" and DirAccess.dir_exists_absolute(temp), "temporary folder exists")
	await _wait_for(func() -> bool: return inst.is_online(), 240.0)
	_check(PlatformBackend.get_current().process_cwd(inst.process.pid) == temp, "process runs inside the temporary copy")
	_write_marker(temp, "discard-marker.txt")
	_check(inst.start() == ERR_ALREADY_IN_USE, "cannot double-start")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)
	_check(ended[0] == 1, "temporary_run_ended emitted once")
	_check(inst.start() == ERR_UNAVAILABLE, "normal start refused while a copy is pending")
	_check(await inst.finish_temporary(false) == OK, "discard temporary copy")
	_check(not DirAccess.dir_exists_absolute(temp), "temporary folder deleted")
	_check(not FileAccess.file_exists(dir.path_join("discard-marker.txt")), "discarded change did not reach the server")

	# --- Temporary run, kept ------------------------------------------------------
	_check(await inst.start_temporary() == OK, "temporary start (keep case)")
	temp = inst.config.temp_run_dir
	await _wait_for(func() -> bool: return inst.is_online(), 240.0)
	_write_marker(temp, "keep-marker.txt")
	inst.restart()
	await _wait_for(func() -> bool: return inst.is_online(), 240.0)
	_check(inst.is_temporary() and PlatformBackend.get_current().process_cwd(inst.process.pid) == temp, "restart stays on the temporary copy")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)
	_check(await inst.finish_temporary(true) == OK, "keep temporary copy")
	_check(FileAccess.file_exists(dir.path_join("keep-marker.txt")), "kept change is now in the server folder")
	_check(ServerConfig.load_from_dir(dir) != null, "manager config survived the swap")
	_check(not inst.is_temporary(), "no temporary copy pending")
	await _boot(inst, "server boots normally after keeping")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)

	ServerManager.delete_server(inst.config.id, true, false, true)
	_finish()


func _boot(inst: ServerInstance, label: String) -> void:
	var err := inst.start()
	await _wait_for(func() -> bool: return inst.is_online() or inst.state == ServerInstance.State.CRASHED, 240.0)
	await _wait_for(func() -> bool: return inst.rcon.is_ready(), 20.0)
	_check(err == OK and inst.is_online(), label)


func _write_marker(dir: String, file: String) -> void:
	var f := FileAccess.open(dir.path_join(file), FileAccess.WRITE)
	f.store_string("marker")


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nFeature test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
