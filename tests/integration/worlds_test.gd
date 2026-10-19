extends Node
## End-to-end test for the Worlds tab: export a split Paper world as a singleplayer
## zip, reset with a new seed, switch worlds, and enable/disable a datapack on a real
## Paper server. Needs network + Java 21.
## Usage: godot --headless --path . res://tests/integration/worlds_test.tscn -- --no-autostart --profile=wt --root=<dir>

const VERSION := "1.21.11"
const DATA_FORMAT := 94
const NEW_SEED := "424242"

var _failures := PackedStringArray()
var _root := ""


func _ready() -> void:
	_root = ProjectSettings.globalize_path("user://worlds-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			_root = arg.get_slice("=", 1)
	AppSettings.servers_root = _root
	AppSettings.server_dirs = PackedStringArray()
	var vinfo: Dictionary = await PaperApi.fetch_version_info(VERSION)
	var latest: Dictionary = await PaperApi.fetch_latest_build(VERSION)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Worlds Test", "version": VERSION, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	_check(created.ok, "create server")
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance
	var dir := inst.config.directory

	# 1. Generate the world.
	await _boot(inst, "first boot generates the world")
	await _stop(inst)
	var worlds := WorldManager.list_worlds(dir, "world")
	_check(worlds.size() == 1 and worlds[0].active and worlds[0].generated, "one active world listed")
	var original: Dictionary = worlds[0]
	_check(original.folders.size() == 3 and original.layout == WorldImporter.Layout.SPLIT, "split layout grouped (%s)" % ", ".join(original.folders))
	_check(original.seed != "" and original.version == VERSION, "seed %s and version %s read" % [original.seed, original.version])

	# 2. Export as a singleplayer zip.
	var zip := _root.path_join("exported-world.zip")
	var err := WorldManager.export_zip(dir, original, zip, {"mutex": Mutex.new(), "progress": 0.0})
	_check(err == "" and FileAccess.file_exists(zip), "export written: %s" % err)
	var names := ZIPReader.new()
	names.open(zip)
	var files := names.get_files()
	names.close()
	_check(Array(files).any(func(f: String) -> bool: return f.begins_with("world/DIM-1/region/")), "zip has the nether in world/DIM-1")
	_check(Array(files).any(func(f: String) -> bool: return f.begins_with("world/DIM1/region/")), "zip has the end in world/DIM1")
	_check(not Array(files).any(func(f: String) -> bool: return f.ends_with("session.lock") or f.ends_with("uid.dat")), "no session.lock/uid.dat")
	var analysis: Dictionary = await WorldImporter.analyze(self, zip, VERSION)
	_check(analysis.ok and analysis.layout == WorldImporter.Layout.SINGLEPLAYER, "exported zip is a valid singleplayer world: %s" % analysis.error)
	_check(analysis.dimensions == PackedStringArray(["Overworld", "Nether", "End"]), "all dimensions in the export")
	WorldImporter.cleanup(analysis)

	# 3. Reset with a new seed.
	var reset_err: String = await WorldManager.reset_world(inst, original, NEW_SEED, false)
	_check(reset_err == "", "reset accepted: %s" % reset_err)
	_check(inst.backups.list_backups().any(func(b: Dictionary) -> bool: return b.name.ends_with("_pre-reset.zip")), "pre-reset safety backup saved")
	_check(not DirAccess.dir_exists_absolute(dir.path_join("world")) and not DirAccess.dir_exists_absolute(dir.path_join("world_nether")), "old world folders removed")
	_check(inst.get_properties().get_value("level-seed") == NEW_SEED, "new seed written")
	var listed := WorldManager.list_worlds(dir, "world", false)
	_check(listed.size() == 1 and not listed[0].generated, "active world shown as not generated yet")
	await _boot(inst, "boot after reset")
	var seed_reply := await inst.rcon.execute("seed")
	_check(seed_reply.contains(NEW_SEED), "regenerated world uses the new seed (%s)" % Ansi.strip(seed_reply))
	await _stop(inst)

	# 4. Import the exported world as a second world, then switch between worlds.
	var again: Dictionary = await WorldImporter.analyze(self, zip, VERSION)
	var imported: Dictionary = await WorldImporter.import_into(inst, again, WorldImporter.Mode.ADD, false)
	WorldImporter.cleanup(again)
	_check(imported.ok, "exported world imported as a second world")
	var second: String = imported.get("level_name", "")
	_check(WorldManager.set_active(inst, "world") == "", "switch back to the reset world")
	_check(inst.get_properties().get_value("level-name") == "world", "level-name updated")
	_check(WorldManager.set_active(inst, second) == "", "switch to the imported world")
	worlds = WorldManager.list_worlds(dir, second, false)
	_check(worlds.size() == 2, "both worlds listed")

	# 5. Datapack on the imported world.
	var packs_dir := dir.path_join(second).path_join("datapacks")
	var pack_src := _root.path_join("testpack")
	_write(pack_src.path_join("pack.mcmeta"), JSON.stringify({"pack": {"description": "Manager test pack", "pack_format": DATA_FORMAT, "min_format": DATA_FORMAT, "max_format": DATA_FORMAT}}))
	_write(pack_src.path_join("data/managertest/function/hello.mcfunction"), "say hello from the test pack\n")
	_check(WorldManager.add_datapack(packs_dir, pack_src) == "", "datapack added")

	await _boot(inst, "boot the imported world")
	seed_reply = await inst.rcon.execute("seed")
	_check(seed_reply.contains(original.seed), "imported world keeps its original seed (%s)" % Ansi.strip(seed_reply))

	var tab: WorldsTab = load("res://scenes/server_view/tabs/worlds_tab.tscn").instantiate()
	add_child(tab)
	tab.bind(inst)
	await tab.refresh()
	var world_rows := tab._world_tree.get_root().get_child_count()
	_check(world_rows == 2, "Worlds tab lists both worlds (%d)" % world_rows)
	var pack_item := _pack_row(tab, "file/testpack")
	_check(pack_item != null and pack_item.get_text(WorldsTab.PackCol.STATUS) == "Enabled", "tab shows the pack as enabled on the running server (%s)" % (pack_item.get_text(WorldsTab.PackCol.STATUS) if pack_item != null else "no row"))
	_check(tab._online_enabled.has("file/testpack"), "datapack list enabled includes file/testpack")

	pack_item.select(0)
	await tab._toggle_pack(false)
	_check(not tab._online_enabled.has("file/testpack") and tab._online_available.has("file/testpack"), "disabled through the tab (now only available)")
	pack_item = _pack_row(tab, "file/testpack")
	_check(pack_item != null and pack_item.get_text(WorldsTab.PackCol.STATUS) == "Disabled", "tab shows it as disabled")
	pack_item.select(0)
	await tab._toggle_pack(true)
	_check(tab._online_enabled.has("file/testpack"), "re-enabled through the tab")
	tab.queue_free()

	await _stop(inst)
	ServerManager.delete_server(inst.config.id, true, true)
	_finish()


func _pack_row(tab: WorldsTab, id: String) -> TreeItem:
	for item in tab._pack_tree.get_root().get_children():
		if str(item.get_metadata(0)) == id:
			return item
	return null


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _boot(inst: ServerInstance, label: String) -> void:
	var err := inst.start()
	await _wait_for(func() -> bool: return inst.is_online() or inst.state == ServerInstance.State.CRASHED, 240.0)
	await _wait_for(func() -> bool: return inst.rcon.is_ready(), 20.0)
	_check(err == OK and inst.is_online() and inst.rcon.is_ready(), label)


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
	print("\nWorlds test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
