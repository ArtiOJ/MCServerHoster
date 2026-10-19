extends Node
## Whitelist / ops / bans edited through the Players tab while the server is STOPPED
## (files written directly) must be honoured after boot, and edits while ONLINE must go
## through commands and land in the files. Uses a real Paper server in offline mode.
## Usage: godot --headless --path . res://tests/integration/player_lists_test.tscn -- --no-autostart --profile=plt --root=<dir>

const TAB_SCENE := preload("res://scenes/server_view/tabs/players_tab.tscn")
const K := PlayerLists.Kind

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://player-lists-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Player Lists Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4", "op-permission-level": "4"},
	})
	var inst: ServerInstance = created.instance
	var dir := inst.config.directory
	var tab: PlayersTab = TAB_SCENE.instantiate()
	add_child(tab)
	tab.bind(inst)

	# --- Stopped: edit files directly ---------------------------------------------------
	_check(tab._edit_mode() == "files", "stopped server edits files")
	for n in ["Steve", "Alex_99"]:
		_check((await tab.add_entry(K.WHITELIST, n)).ok, "whitelist add %s offline" % n)
	_check((await tab.add_entry(K.OPS, "Steve", {"level": 2})).ok, "op Steve at level 2 offline")
	_check((await tab.add_entry(K.OPS, "Alex_99", {"level": 4})).ok, "op Alex_99 offline")
	_check(tab.change_op_level("Alex_99", 3).ok, "change Alex_99 to level 3 offline")
	_check((await tab.add_entry(K.BANS, "Herobrine", {"reason": "Griefing the spawn"})).ok, "ban Herobrine offline")
	_check((await tab.add_entry(K.IP_BANS, "10.1.2.3", {"reason": "Spam"})).ok, "ban IP offline")
	_check(not (await tab.add_entry(K.WHITELIST, "bad-name")).ok, "invalid name rejected")
	var wl := PlayerLists.read(dir, K.WHITELIST)
	_check(wl.size() == 2 and str(wl[0].uuid) == "5627dd98-e6be-3c21-b8a8-e92344183641", "whitelist file has offline UUIDs")
	_check(tab._whitelist_panel._list.item_count == 2 and tab._ip_bans_panel._list.item_count == 1, "panels show the entries")

	# --- Boot: the server must honour the offline edits -----------------------------------
	inst.start()
	await _wait_for(func() -> bool: return inst.is_online() and inst.rcon.is_ready(), 200.0)
	_check(inst.is_online(), "server online")
	var wl_reply := await inst.rcon.execute("whitelist list")
	_check(wl_reply.contains("Steve") and wl_reply.contains("Alex_99"), "server sees whitelist: " + wl_reply)
	var bans_reply := await inst.rcon.execute("banlist players")
	_check(bans_reply.contains("Herobrine") and bans_reply.contains("Griefing the spawn"), "server sees player ban: " + bans_reply)
	var ip_reply := await inst.rcon.execute("banlist ips")
	_check(ip_reply.contains("10.1.2.3"), "server sees IP ban: " + ip_reply)
	var op_reply := await inst.rcon.execute("op Steve")
	_check(op_reply.to_lower().contains("nothing changed") or op_reply.to_lower().contains("already"), "server already treats Steve as op: " + op_reply)
	var levels := {}
	for e in PlayerLists.read(dir, K.OPS):
		levels[str(e.name)] = int(e.level)
	_check(levels.get("Steve") == 2 and levels.get("Alex_99") == 3, "op levels kept after boot: %s" % levels)

	# --- Online: commands, then files reflect them --------------------------------------
	_check(tab._edit_mode() == "commands", "running server uses commands")
	_check(not tab.change_op_level("Steve", 4).ok, "level changes refused while online")
	tab.remove_entry(K.WHITELIST, "Alex_99")
	tab.remove_entry(K.BANS, "Herobrine")
	tab.remove_entry(K.OPS, "Steve")
	tab.add_entry(K.BANS, "Griefer1", {"reason": "Lava"})
	await get_tree().create_timer(2.0).timeout
	var names := func(kind: K) -> PackedStringArray:
		var out := PackedStringArray()
		for e in PlayerLists.read(dir, kind):
			out.append(str(e.get("name", "")))
		return out
	_check(not names.call(K.WHITELIST).has("Alex_99") and names.call(K.WHITELIST).has("Steve"), "whitelist remove via command reached the file")
	_check(not names.call(K.BANS).has("Herobrine") and names.call(K.BANS).has("Griefer1"), "pardon and ban via commands reached the file")
	_check(not names.call(K.OPS).has("Steve") and names.call(K.OPS).has("Alex_99"), "deop via command reached the file")
	var griefer := PlayerLists.read(dir, K.BANS)
	_check(griefer.size() == 1 and str(griefer[0].reason) == "Lava", "ban reason sent with the command")

	inst.stop()
	# The process can be gone a moment before the manager handles its exit and leaves STOPPING.
	await _wait_for(func() -> bool: return inst.state == ServerInstance.State.STOPPED, 60.0)
	_check(tab._edit_mode() == "files", "back to file editing after stop")
	tab.queue_free()
	ServerManager.delete_server(inst.config.id, true, true)
	print("\nPlayer lists test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
