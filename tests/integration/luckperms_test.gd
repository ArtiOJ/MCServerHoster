extends Node
## LuckPerms from the Permissions menu's operations on a real Paper server: install, read,
## change groups, players and tracks, notice changes that don't take effect, and keep the
## last state readable while the server is stopped.
## Usage: godot --headless --path . res://tests/integration/luckperms_test.tscn -- --no-autostart --profile=lp --root=<dir> [--version=26.3]

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://luckperms-test-servers")
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
		"name": "Perms Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	_check(created.ok, "create server")
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance

	var state: Dictionary = await inst.call_op("perms_get")
	_check(state.ok and not state.installed and not state.editable, "not installed yet: %s" % state.get("note", ""))
	var installed: Dictionary = await inst.call_op("perms_install")
	_check(installed.ok and str(installed.version) != "", "LuckPerms %s installed" % installed.get("version", installed.get("error", "")))
	_check(LuckPerms.installed_info(inst.config.directory).installed, "jar in plugins")

	await _boot(inst)
	state = await inst.call_op("perms_get")
	_check(state.ok and state.live and state.editable, "live read: %s" % state.get("note", ""))
	_check(LuckPerms.find(state, "group", "default") != null, "default group listed")

	# Permissions to pick from: a plugin's declared ones, Minecraft's commands, built-ins.
	var zip := ZIPPacker.new()
	zip.open(inst.config.directory.path_join("plugins/homes-1.0.jar"))
	zip.start_file("plugin.yml")
	zip.write_file("name: Homes\nversion: 1.0\nmain: a.B\ncommands:\n  home:\n    permission: homes.use\npermissions:\n  homes.use:\n    description: Teleport home\n    default: true\n".to_utf8_buffer())
	zip.close_file()
	zip.close()
	var known: Dictionary = await inst.call_op("perms_known")
	var nodes: Array = known.get("permissions", []).map(func(p: Dictionary) -> String: return p.node)
	_check(known.ok and nodes.has("homes.use") and nodes.has("luckperms.*"), "plugin and built-in permissions listed")
	_check(nodes.has("minecraft.command.gamemode") and nodes.has("minecraft.command.tp"), "Minecraft's commands listed from the server (%d permissions)" % nodes.size())
	_check(FileAccess.file_exists(inst.config.directory.path_join(LuckPerms.VANILLA_CACHE)), "command list remembered for when it's stopped")

	var steve: Dictionary = await inst.call_op("perms_player", {"name": "Steve"})
	_check(steve.ok and LuckPerms.is_uuid(str(steve.uuid)), "player looked up: %s" % steve.get("uuid", steve.get("error", "")))
	var uuid := str(steve.get("uuid", ""))
	state = await inst.call_op("perms_apply", {"changes": [
		{"action": "group_create", "group": "mod"},
		{"action": "weight_set", "group": "mod", "weight": 50},
		{"action": "prefix_set", "holder": "group", "name": "mod", "priority": 50, "text": "&c[Mod] "},
		{"action": "permission_set", "holder": "group", "name": "mod", "node": "kick.use", "value": true},
		{"action": "permission_set", "holder": "group", "name": "mod", "node": "fly.use", "value": true, "duration": "1h", "context": "world=world"},
		{"action": "parent_add", "holder": "group", "name": "mod", "group": "default"},
		{"action": "track_create", "track": "staff"},
		{"action": "track_append", "track": "staff", "group": "default"},
		{"action": "track_append", "track": "staff", "group": "mod"},
		{"action": "permission_set", "holder": "user", "name": uuid, "node": "spawn.use", "value": false},
	]})
	_check(state.ok and state.get("failed", ["?"]).is_empty(), "batch applied: %s" % [state.get("failed", state.get("error", ""))])
	var mod: Variant = LuckPerms.find(state, "group", "mod")
	_check(mod != null and mod.weight == 50 and mod.prefixes.size() == 1, "group with weight and prefix")
	var fly: Array = (mod.permissions if mod != null else []).filter(func(p: Dictionary) -> bool: return p.node == "fly.use")
	_check(fly.size() == 1 and int(fly[0].expiry) > 0 and fly[0].context == "world=world", "timed permission in one world: %s" % [fly])
	_check(LuckPerms.find(state, "user", uuid) != null, "player has their own data")
	_check(state.players.any(func(p: Dictionary) -> bool: return p.uuid == uuid), "player listed")

	state = await inst.call_op("perms_apply", {"changes": [{"action": "promote", "name": uuid, "track": "staff"}]})
	var user: Variant = LuckPerms.find(state, "user", uuid)
	_check(user != null and user.parents.any(func(p: Dictionary) -> bool: return p.group == "mod"), "promoted on the track")

	state = await inst.call_op("perms_apply", {"changes": [{"action": "parent_add", "holder": "user", "name": uuid, "group": "nosuchgroup"}]})
	_check(state.ok and state.failed.size() == 1, "a change LuckPerms refused is reported: %s" % [state.get("failed", [])])
	var refused: Dictionary = await inst.call_op("perms_apply", {"changes": [{"action": "permission_set", "holder": "group", "name": "mod", "node": "bad node"}]})
	_check(not refused.ok, "invalid input refused before sending: %s" % refused.get("error", ""))

	state = await inst.call_op("perms_apply", {"changes": [
		{"action": "permission_unset", "holder": "group", "name": "mod", "node": "fly.use", "context": "world=world", "temporary": true},
		{"action": "prefix_remove", "holder": "group", "name": "mod", "priority": 50, "text": "&c[Mod] "},
		{"action": "track_remove", "track": "staff", "group": "default"},
	]})
	_check(state.ok and state.failed.is_empty(), "removals applied: %s" % [state.get("failed", state.get("error", ""))])
	state = await inst.call_op("perms_apply", {"changes": [{"action": "track_insert", "track": "staff", "group": "default", "position": 1}]})
	_check(state.ok and state.failed.is_empty(), "inserted at the front of the track: %s" % [state.get("failed", "")])

	await _stop(inst)
	state = await inst.call_op("perms_get")
	_check(state.ok and not state.live and not state.editable and LuckPerms.find(state, "group", "mod") != null, "stopped: last read shown read-only (%s)" % state.note)
	var known_offline: Dictionary = await inst.call_op("perms_known")
	_check(known_offline.get("permissions", []).any(func(p: Dictionary) -> bool: return p.node == "minecraft.command.gamemode"), "Minecraft's commands still listed while stopped")
	var offline: Dictionary = await inst.call_op("perms_apply", {"changes": [{"action": "group_create", "group": "later"}]})
	_check(not offline.ok, "changes need the running server")
	await _boot(inst)
	state = await inst.call_op("perms_get")
	_check(LuckPerms.find(state, "group", "mod") != null and LuckPerms.find(state, "user", uuid) != null, "changes survived a restart")
	state = await inst.call_op("perms_apply", {"changes": [{"action": "group_delete", "group": "mod"}]})
	_check(state.ok and state.failed.is_empty() and LuckPerms.find(state, "group", "mod") == null, "group deleted")
	_check(DirAccess.get_files_at(inst.config.directory.path_join(LuckPerms.DATA_DIR)).count("server-manager-") == 0
			and not Array(DirAccess.get_files_at(inst.config.directory.path_join(LuckPerms.DATA_DIR))).any(func(f: String) -> bool: return f.begins_with(LuckPerms.EXPORT_PREFIX)), "export files cleaned up")
	await _stop(inst)
	if _failures.is_empty():
		ServerManager.delete_server(inst.config.id, true, true)
	_finish()


func _boot(inst: ServerInstance) -> void:
	inst.start()
	await _wait_for(func() -> bool: return (inst.is_online() and inst.rcon.is_ready()) or inst.state == ServerInstance.State.CRASHED, 240.0)
	_check(inst.is_online() and inst.rcon.is_ready(), "server boots")


func _stop(inst: ServerInstance) -> void:
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nLuckPerms test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
