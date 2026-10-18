extends Node
## End-to-end world import test with real Paper servers:
##  1. a source server generates a world with marker blocks in all three dimensions,
##  2. that world is packaged like a downloaded singleplayer map (.zip, nether/end inside),
##  3. it is imported into a second server (replace mode, then add-as-new mode),
##  4. the second server boots and the markers are checked over RCON in every dimension.
## Optional --legacy-zip=<zip> also imports an older (1.21) singleplayer map to test upgrades.
## Usage: godot --headless --path . res://tests/integration/world_import_test.tscn -- --no-autostart --profile=wi --root=<dir> [--version=1.21.11] [--legacy-zip=<zip>]

const MARKERS := [["overworld", "0 200 0", "emerald_block"], ["the_nether", "0 100 0", "gold_block"], ["the_end", "0 100 0", "diamond_block"]]
const SKIP_FILES: PackedStringArray = ["session.lock", "uid.dat", "paper-world.yml"]

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://world-import-test")
	var version := "1.21.11"
	var legacy_zip := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--version="):
			version = arg.get_slice("=", 1)
		elif arg.begins_with("--legacy-zip="):
			legacy_zip = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var source := await _create("Map Source", version)
	var target := await _create("Map Target", version)
	if source == null or target == null:
		return _finish()

	# 1. Source world with markers; adventure + hard so the map's settings can be checked.
	await _boot(source, "source boots")
	for m in MARKERS:
		print("  ", await source.rcon.execute("execute in minecraft:%s run forceload add 0 0" % m[0]))
		print("  ", await source.rcon.execute("execute in minecraft:%s run setblock %s minecraft:%s" % m))
	print("  ", await source.rcon.execute("defaultgamemode adventure"))
	print("  ", await source.rcon.execute("difficulty hard"))
	print("  ", await source.rcon.execute("save-all flush"))
	await get_tree().create_timer(2.0).timeout
	await _check_markers(source, "source")
	await _stop(source)
	var lvl := Nbt.read_file(source.config.directory.path_join("world/level.dat"))
	print("  source level.dat GameType=%s Difficulty=%s" % [Nbt.dig(lvl, ["Data", "GameType"]), Nbt.dig(lvl, ["Data", "Difficulty"], Nbt.dig(lvl, ["Data", "difficulty_settings", "difficulty"]))])

	# 2. Package it like a downloaded singleplayer map.
	var zip_path := root.path_join("Adventure Map.zip")
	var src_dir := source.config.directory
	var items := [[src_dir.path_join("world"), "Adventure Map"]]
	if DirAccess.dir_exists_absolute(src_dir.path_join("world_nether/DIM-1")):
		items.append([src_dir.path_join("world_nether/DIM-1"), "Adventure Map/DIM-1"])
		items.append([src_dir.path_join("world_the_end/DIM1"), "Adventure Map/DIM1"])
	_zip_dirs(zip_path, items)
	_check(FileAccess.file_exists(zip_path), "map packaged as %s" % zip_path.get_file())
	var zr := ZIPReader.new()
	zr.open(zip_path)
	var names := zr.get_files()
	zr.close()
	print("  zip entries: %d, DIM-1 region files: %d" % [names.size(), Array(names).filter(func(n: String) -> bool: return n.contains("DIM-1/region/")).size()])

	# 3a. Replace mode into a server that already has a generated world.
	await _boot(target, "target boots with its own world")
	await _stop(target)
	var a: Dictionary = await WorldImporter.analyze(self, zip_path, version)
	_check(a.ok, "analysis ok: %s" % a.error)
	_check(a.layout == (WorldImporter.Layout.DIMENSIONS if Fmt.compare_versions(version, "26.1") >= 0 else WorldImporter.Layout.SINGLEPLAYER), "layout detected: %s" % WorldImporter.LAYOUT_NAMES[a.layout])
	_check(a.dimensions.size() == 3, "all three dimensions found: %s" % ", ".join(a.dimensions))
	_check(a.game_mode == "adventure" and a.difficulty == "hard", "map settings read (%s/%s)" % [a.game_mode, a.difficulty])
	var r: Dictionary = await WorldImporter.import_into(target, a, WorldImporter.Mode.REPLACE, true)
	WorldImporter.cleanup(a)
	_check(r.ok, "replace import: %s" % r.get("error", ""))
	_check(target.backups.list_backups().any(func(b: Dictionary) -> bool: return b.name.ends_with("_pre-import.zip")), "safety backup of the replaced world")
	var props := target.get_properties()
	_check(props.get_value("gamemode") == "adventure" and props.get_value("difficulty") == "hard", "map settings applied to server.properties")
	await _boot(target, "target boots the imported map (replace)")
	await _check_markers(target, "replace")
	await _stop(target)

	# 3b. Add as a new world and switch to it.
	var b: Dictionary = await WorldImporter.analyze(self, zip_path, version)
	var r2: Dictionary = await WorldImporter.import_into(target, b, WorldImporter.Mode.ADD, false)
	WorldImporter.cleanup(b)
	_check(r2.ok and r2.level_name != "world", "add import as new world folder \"%s\"" % r2.get("level_name", ""))
	_check(DirAccess.dir_exists_absolute(target.config.directory.path_join("world")), "previous world kept on disk")
	await _boot(target, "target boots the added world")
	await _check_markers(target, "add")
	await _stop(target)

	# 4. Optional: an older singleplayer map is upgraded on import.
	if legacy_zip != "":
		var c: Dictionary = await WorldImporter.analyze(self, legacy_zip, version)
		_check(c.ok, "legacy map analysis: %s %s" % [c.error, c.warnings])
		var r3: Dictionary = await WorldImporter.import_into(target, c, WorldImporter.Mode.REPLACE, false)
		WorldImporter.cleanup(c)
		_check(r3.ok, "legacy map import")
		await _boot(target, "target boots the upgraded legacy map")
		await _check_markers(target, "legacy")
		await _stop(target)

	_check(not DirAccess.dir_exists_absolute(root.path_join("_temp")) or DirAccess.get_directories_at(root.path_join("_temp")).is_empty(), "staging folders cleaned up")
	if _failures.is_empty():
		ServerManager.delete_server(source.config.id, true, true)
		ServerManager.delete_server(target.config.id, true, true)
	_finish()


func _create(name: String, version: String) -> ServerInstance:
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": name, "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4", "spawn-protection": "0"},
	})
	_check(created.ok, "create %s (%s)" % [name, version])
	return created.get("instance")


func _boot(inst: ServerInstance, label: String) -> void:
	inst.start()
	await _wait_for(func() -> bool: return (inst.is_online() and inst.rcon.is_ready()) or inst.state == ServerInstance.State.CRASHED, 240.0)
	_check(inst.is_online() and inst.rcon.is_ready(), label)


func _stop(inst: ServerInstance) -> void:
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)


func _check_markers(inst: ServerInstance, label: String) -> void:
	for m in MARKERS:
		await inst.rcon.execute("execute in minecraft:%s run forceload add 0 0" % m[0])
	await get_tree().create_timer(1.0).timeout
	for m in MARKERS:
		var reply := await inst.rcon.execute("execute in minecraft:%s if block %s minecraft:%s" % m)
		_check(reply.contains("passed"), "%s: %s marker preserved in %s (%s)" % [label, m[2], m[0], reply.strip_edges()])


func _zip_dirs(zip_path: String, items: Array) -> void:
	var zip := ZIPPacker.new()
	zip.open(zip_path)
	for item in items:
		_zip_tree(zip, item[0], item[1], item)
	zip.close()


func _zip_tree(zip: ZIPPacker, dir: String, prefix: String, item: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if SKIP_FILES.has(f):
			continue
		zip.start_file(prefix.path_join(f))
		zip.write_file(FileAccess.get_file_as_bytes(dir.path_join(f)))
		zip.close_file()
	for d in DirAccess.get_directories_at(dir):
		# The nether/end of an old-layout world are added separately, inside the map folder.
		if prefix == item[1] and (d == "DIM-1" or d == "DIM1") and dir == item[0]:
			continue
		_zip_tree(zip, dir.path_join(d), prefix.path_join(d), item)


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nWorld import test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
