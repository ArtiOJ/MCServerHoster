extends Node
## Plugins from Modrinth on a real Paper server: search, install with required plugins,
## recognising installed jars, refusing projects without a build for the version, and the
## server loading what was installed. Needs network access.
## Usage: godot --headless --path . res://tests/integration/modrinth_test.tscn -- --no-autostart --profile=mr --root=<dir> [--version=26.3]

const ENCHANTMENT := "4sP0LXxp"  # VeinMiner Enchantment (small), requires VeinMiner
const VEINMINER := "OhduvhIc"
const CLIENT_MOD := "AANobbMI"  # Sodium: no Paper builds

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://modrinth-test-servers")
	var version := "26.3"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--version="):
			version = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()

	var found: Dictionary = await ModrinthApi.search(self, "veinminer", version)
	_check(found.ok and found.hits.any(func(h: Dictionary) -> bool: return h.project_id == ENCHANTMENT), "search finds VeinMiner Enchantment for %s (%d results)" % [version, found.get("total", 0)])
	var none: Dictionary = await ModrinthApi.compatible_version(self, ENCHANTMENT, "1.7.10")
	_check(none.ok and none.version.is_empty(), "no build for an unsupported version")

	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Plugins Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	_check(created.ok, "create server")
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance

	var res: Dictionary = await inst.call_op("plugin_install_modrinth", {"project_id": ENCHANTMENT})
	var ids: Array = res.get("installed", []).map(func(d: Dictionary) -> String: return d.project_id)
	_check(res.ok and ids.has(ENCHANTMENT) and ids.has(VEINMINER), "installed with the plugin it requires: %s %s" % [ids, res.get("error", "")])
	var list: Dictionary = await inst.call_op("plugins_list")
	_check(list.ok and list.plugins.size() == 2 and list.plugins.all(func(p: Dictionary) -> bool: return str(p.sha1).length() == 40), "two jars, hashed")
	var hashes: Array = list.plugins.map(func(p: Dictionary) -> String: return p.sha1)
	var known: Dictionary = await ModrinthApi.lookup_sha1(self, hashes)
	var projects: Array = known.get("found", {}).values().map(func(v: Dictionary) -> String: return v.project_id)
	_check(known.ok and projects.has(ENCHANTMENT) and projects.has(VEINMINER), "installed jars recognised as Modrinth files")
	var again: Dictionary = await inst.call_op("plugin_install_modrinth", {"project_id": ENCHANTMENT})
	_check(again.ok and again.get("already", false) and again.installed.is_empty(), "installing again changes nothing")
	var mod: Dictionary = await inst.call_op("plugin_install_modrinth", {"project_id": CLIENT_MOD})
	_check(not mod.ok and str(mod.error).contains("no Paper"), "a project without a Paper build is refused: %s" % mod.get("error", ""))

	inst.start()
	await _wait_for(func() -> bool: return inst.is_online() or inst.state == ServerInstance.State.CRASHED, 240.0)
	_check(inst.is_online(), "server boots with the plugins")
	var enabled := func(plugin: String) -> bool:
		return inst.console_lines.any(func(e: Dictionary) -> bool: return (e.plain as String).to_lower().contains("enabling " + plugin))
	_check(enabled.call("veinminer v") and enabled.call("veinminer_enchantment"), "Paper enabled both plugins")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)
	if _failures.is_empty():
		ServerManager.delete_server(inst.config.id, true, true)
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
	print("\nModrinth test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
