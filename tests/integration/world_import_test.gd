extends Node
## End-to-end world import test with real Paper servers:
##  1. a source server generates a world with marker blocks in all three dimensions,
##  2. that world is packaged like a downloaded singleplayer map (.zip, nether/end inside),
##  3. it is imported into a second server (replace mode, then add-as-new mode),
##  4. the second server boots and the markers are checked over RCON in every dimension.
## On 26.1+ a lone dimension folder (a Paper world without level.dat) is imported too.
## Optional --legacy-zip=<zip> also imports an older (1.21) singleplayer map to test upgrades.
## Optional --dimension=<dir> imports a real dimension folder (read only) and reports its seed.
## Usage: godot --headless --path . res://tests/integration/world_import_test.tscn -- --no-autostart --profile=wi --root=<dir> [--version=1.21.11] [--legacy-zip=<zip>] [--dimension=<dir>]

const MARKERS := [["overworld", "0 200 0", "emerald_block"], ["the_nether", "0 100 0", "gold_block"], ["the_end", "0 100 0", "diamond_block"]]
const SKIP_FILES: PackedStringArray = ["session.lock", "uid.dat", "paper-world.yml"]

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://world-import-test")
	var version := "1.21.11"
	var legacy_zip := ""
	var dimension := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--version="):
			version = arg.get_slice("=", 1)
		elif arg.begins_with("--legacy-zip="):
			legacy_zip = arg.get_slice("=", 1)
		elif arg.begins_with("--dimension="):
			dimension = arg.get_slice("=", 1)
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

	# 5. Minecraft 26+: one dimension on its own becomes the overworld of a new world.
	if WorldImporter.uses_dimensions_layout(version):
		var lone := root.path_join("islands")
		FileOps.copy_tree(src_dir.path_join("world/dimensions/minecraft/overworld"), lone)
		var e: Dictionary = await WorldImporter.analyze(self, lone, version)
		_check(e.ok and e.layout == WorldImporter.Layout.DIMENSION, "lone dimension analysed: %s %s" % [e.error, e.warnings])
		var r4: Dictionary = await WorldImporter.import_into(target, e, WorldImporter.Mode.ADD, false)
		_check(r4.ok and r4.level_name == "islands", "lone dimension imported as \"%s\"" % r4.get("level_name", ""))
		await _boot(target, "target boots the lone dimension")
		await target.rcon.execute("execute in minecraft:overworld run forceload add 0 0")
		await get_tree().create_timer(1.0).timeout
		var reply := await target.rcon.execute("execute in minecraft:overworld if block %s minecraft:%s" % [MARKERS[0][1], MARKERS[0][2]])
		_check(reply.contains("passed"), "lone dimension: overworld marker preserved (%s)" % reply.strip_edges())
		var seed := WorldManager.read_seed(src_dir.path_join("world"))
		reply = await target.rcon.execute("seed")
		_check(seed != "" and reply.contains(seed), "lone dimension: seed kept (%s, source %s)" % [reply.strip_edges(), seed])
		await _stop(target)
		# The same dimension added to that world as an extra dimension.
		var g: Dictionary = await WorldImporter.analyze(self, lone, version)
		var r6: Dictionary = await WorldImporter.import_into(target, g, WorldImporter.Mode.DIMENSION, false)
		_check(r6.ok and r6.get("dimension") == "minecraft:islands", "added as dimension %s (%s)" % [r6.get("dimension", ""), r6.get("command", "")])
		await _boot(target, "target boots with the added dimension")
		await target.rcon.execute("execute in minecraft:islands run forceload add 0 0")
		await get_tree().create_timer(1.0).timeout
		reply = await target.rcon.execute("execute in minecraft:islands if block %s minecraft:%s" % [MARKERS[0][1], MARKERS[0][2]])
		_check(reply.contains("passed"), "added dimension: marker preserved (%s)" % reply.strip_edges())
		reply = await target.rcon.execute("execute in minecraft:overworld if block %s minecraft:%s" % [MARKERS[0][1], MARKERS[0][2]])
		_check(reply.contains("passed"), "added dimension: overworld untouched (%s)" % reply.strip_edges())
		await _stop(target)
		# A dimension from a taller world (Y -128 to 383): it gets its own dimension type,
		# built from the server's vanilla one, which Minecraft must accept.
		var tall: Dictionary = g.dimension_choices[0].duplicate()
		tall.min_y = -128
		tall.height = 512
		var custom := WorldImporter.custom_dimension_type(target.config.directory, tall)
		_check(custom.ok and not custom.definition.is_empty(), "taller dimension type built: %s" % custom.get("error", ""))
		var world_dir := target.config.directory.path_join(target.get_properties().get_value("level-name", "world"))
		_check(WorldImporter.place_dimension(tall, world_dir, "tall", false, custom.definition) == OK, "taller dimension placed")
		await _boot(target, "target boots with the taller dimension")
		await target.rcon.execute("execute in minecraft:tall run forceload add 0 0")
		await get_tree().create_timer(1.0).timeout
		reply = await target.rcon.execute("execute in minecraft:tall if block %s minecraft:%s" % [MARKERS[0][1], MARKERS[0][2]])
		_check(reply.contains("passed"), "taller dimension: marker preserved (%s)" % reply.strip_edges())
		reply = await target.rcon.execute("execute in minecraft:tall run setblock 0 -120 0 minecraft:stone")
		_check(reply.contains("Changed"), "taller dimension: blocks below the normal floor (%s)" % reply.strip_edges())
		await _stop(target)
		FileOps.remove_tree(lone)

	if dimension != "":
		var f: Dictionary = await WorldImporter.analyze(self, dimension, version)
		_check(f.ok, "real dimension analysed: %s %s" % [f.error, f.warnings])
		print("  name=%s mode=%s difficulty=%s data_version=%d" % [WorldImporter.display_name(f), f.game_mode, f.difficulty, f.data_version])
		var r5: Dictionary = await WorldImporter.import_into(target, f, WorldImporter.Mode.ADD, true)
		_check(r5.ok, "real dimension imported as \"%s\"" % r5.get("level_name", ""))
		await _boot(target, "target boots the real dimension")
		print("  ", await target.rcon.execute("seed"))
		await _check_generator(target, "minecraft:overworld", f)
		print("  ", await target.rcon.execute("difficulty"))
		await _stop(target)
		var h: Dictionary = await WorldImporter.analyze(self, dimension, version)
		var added := []
		for i in h.dimension_choices.size():
			var r7: Dictionary = await WorldImporter.import_into(target, h, WorldImporter.Mode.DIMENSION, false, Callable(), i)
			_check(r7.ok, "%s added as %s: %s" % [h.dimension_choices[i].label, r7.get("dimension", ""), r7.get("command", "")])
			added.append([str(r7.get("dimension", "")), h.dimension_choices[i]])
		await _boot(target, "target boots with the real dimensions added")
		for pair in added:
			var choice: Dictionary = pair[1]
			var spawn: Array = choice.spawn
			var usable := spawn.size() == 3 and int(spawn[1]) >= WorldImporter.MIN_BUILD_Y and int(spawn[1]) <= WorldImporter.MAX_BUILD_Y
			if usable:
				await _check_generator(target, pair[0], {"spawn": spawn, "generator": choice.generator})
			# The teleport command, run by an armour stand instead of a player.
			var x := int(spawn[0]) if spawn.size() == 3 else 0
			var z := int(spawn[2]) if spawn.size() == 3 else 0
			await target.rcon.execute("execute in %s run forceload add %d %d" % [pair[0], x, z])
			await target.rcon.execute("execute in %s run summon armor_stand %d 400 %d {Tags:[\"probe\"],NoGravity:1b}" % [pair[0], x, z])
			var command := WorldImporter.teleport_command(pair[0], spawn, choice.type).trim_prefix("/execute ")
			print("  ", await target.rcon.execute("execute as @e[tag=probe,limit=1] " + command))
			var pos := await target.rcon.execute("execute in %s run data get entity @e[tag=probe,limit=1] Pos" % pair[0])
			var y := pos.get_slice(",", 1).strip_edges().to_float()
			_check(y > WorldImporter.MIN_BUILD_Y and y < 400.0, "%s: teleport command lands on terrain (%s)" % [pair[0], pos.strip_edges()])
			await target.rcon.execute("kill @e[tag=probe]")
		await _stop(target)
		var lvl2 := Nbt.read_file(target.config.directory.path_join(str(r5.get("level_name", ""))).path_join("level.dat"))
		print("  level.dat spawn: %s" % str(Nbt.dig(lvl2, ["Data", "spawn"])))
		print("  imported folder: %s" % target.config.directory.path_join(str(r5.get("level_name", ""))))

	_check(not DirAccess.dir_exists_absolute(root.path_join("_temp")) or DirAccess.get_directories_at(root.path_join("_temp")).is_empty(), "staging folders cleaned up")
	if _failures.is_empty() and dimension == "":
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


## Checks that [param dim] has terrain at the dimension's spawn and that new chunks far away
## come from its own generator (a void world stays empty, unlike the test servers' flat preset).
func _check_generator(inst: ServerInstance, dim: String, analysis: Dictionary) -> void:
	var spawn: Array = analysis.spawn
	var reply := ""
	await inst.rcon.execute("execute in %s run forceload add 100000 100000" % dim)
	if spawn.size() == 3 and int(spawn[1]) > WorldImporter.MIN_BUILD_Y and int(spawn[1]) <= WorldImporter.MAX_BUILD_Y:
		await inst.rcon.execute("execute in %s run forceload add %d %d" % [dim, spawn[0], spawn[2]])
		await get_tree().create_timer(3.0).timeout
		reply = await inst.rcon.execute("execute in %s unless block %d %d %d minecraft:air" % [dim, spawn[0], int(spawn[1]) - 1, spawn[2]])
		_check(reply.contains("passed"), "%s: terrain under the spawn (%s)" % [dim, reply.strip_edges()])
	else:
		await get_tree().create_timer(3.0).timeout
		print("  %s: saved spawn %s is unusable; not checked" % [dim, spawn])
	var void_world: bool = Nbt.dig(analysis.generator, ["settings", "biome"], "") == "minecraft:the_void"
	reply = await inst.rcon.execute("execute in %s if block 100000 -64 100000 minecraft:%s" % [dim, "air" if void_world else "bedrock"])
	_check(reply.contains("passed"), "%s: new chunks use the dimension's generator (%s)" % [dim, reply.strip_edges()])


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
