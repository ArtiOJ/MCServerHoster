extends TestCase
## WorldManager: discovery and grouping for both Paper layouts, seeds/versions,
## singleplayer export, datapack metadata and in-game pack lists.

const LEVEL_121 := "res://tests/fixtures/level_1_21_11.dat"
const LEVEL_263 := "res://tests/fixtures/level_26_3.dat"


func _tmp() -> String:
	var dir := ProjectSettings.globalize_path("user://test-worlds-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _touch(path: String, text := "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _copy_level(fixture: String, dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.copy_absolute(ProjectSettings.globalize_path(fixture), dir.path_join("level.dat"))


## A gzip NBT file {"": {data: {seed: <long>}}}, like 26.x world_gen_settings.dat.
func _write_gen_settings(path: String, seed: int) -> void:
	var b := PackedByteArray()
	b.append_array([10, 0, 0])  # root compound, empty name
	b.append_array([10, 0, 4]); b.append_array("data".to_utf8_buffer())
	b.append_array([4, 0, 4]); b.append_array("seed".to_utf8_buffer())
	var v := PackedByteArray(); v.resize(8); v.encode_s64(0, seed); v.reverse()  # big-endian
	b.append_array(v)
	b.append_array([0, 0])  # end data, end root
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b.compress(FileAccess.COMPRESSION_GZIP))


## Server folder: split 1.21 world "world", a 26.x world "w26", a singleplayer-layout
## world "sp", and non-world folders.
func _make_server() -> String:
	var dir := _tmp()
	_copy_level(LEVEL_121, dir.path_join("world"))
	_touch(dir.path_join("world/region/r.0.0.mca"), "overworld")
	_touch(dir.path_join("world/session.lock"))
	_touch(dir.path_join("world/uid.dat"))
	_copy_level(LEVEL_121, dir.path_join("world_nether"))
	_touch(dir.path_join("world_nether/DIM-1/region/r.0.0.mca"), "nether")
	_copy_level(LEVEL_121, dir.path_join("world_the_end"))
	_touch(dir.path_join("world_the_end/DIM1/region/r.0.0.mca"), "end")
	_copy_level(LEVEL_263, dir.path_join("w26"))
	_touch(dir.path_join("w26/dimensions/minecraft/overworld/region/r.0.0.mca"))
	_write_gen_settings(dir.path_join("w26/dimensions/minecraft/overworld/data/minecraft/world_gen_settings.dat"), 1554127567574725737)
	_copy_level(LEVEL_121, dir.path_join("sp"))
	_touch(dir.path_join("sp/DIM-1/region/r.0.0.mca"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("plugins"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("logs"))
	return dir


func test_discovery_groups_split_worlds() -> void:
	var dir := _make_server()
	var worlds := WorldManager.list_worlds(dir, "world")
	var folders := worlds.map(func(w: Dictionary) -> String: return w.folder)
	check_eq(folders, ["world", "sp", "w26"], "active first, nether/end folders grouped, non-worlds ignored")
	var main: Dictionary = worlds[0]
	check(main.active and main.generated, "active world")
	check_eq(main.folders, PackedStringArray(["world", "world_nether", "world_the_end"]), "split folders grouped")
	check_eq(main.layout, WorldImporter.Layout.SPLIT, "split layout")
	check_eq(main.version, "1.21.11", "version from level.dat")
	check_eq(main.seed, "-28615018676675051", "seed from WorldGenSettings")
	check_eq(main.game_mode, "survival", "game mode")
	check(main.size_bytes > 0, "size counted across folders")
	var w26: Dictionary = worlds[2]
	check_eq(w26.layout, WorldImporter.Layout.DIMENSIONS, "26.x layout")
	check_eq(w26.version, "26.3", "26.x version")
	check_eq(w26.seed, "1554127567574725737", "26.x seed from world_gen_settings.dat")
	check_eq(worlds[1].layout, WorldImporter.Layout.SINGLEPLAYER, "singleplayer layout")
	FileOps.remove_tree(dir)


func test_missing_active_world_is_listed_as_new() -> void:
	var dir := _make_server()
	var worlds := WorldManager.list_worlds(dir, "fresh", false)
	var fresh: Array = worlds.filter(func(w: Dictionary) -> bool: return w.folder == "fresh")
	check(fresh.size() == 1 and fresh[0].active and not fresh[0].generated, "placeholder for the not-yet-generated active world")
	check_eq(worlds[0].folder, "fresh", "listed first")
	FileOps.remove_tree(dir)


func test_export_merges_split_layout_into_singleplayer() -> void:
	var dir := _make_server()
	var world := WorldManager.read_world(dir, "world", "world")
	var names := WorldManager.export_entries(dir, world).map(func(e: Array) -> String: return e[1])
	check(names.has("world/level.dat"), "level.dat at the top of the world folder")
	check(names.has("world/DIM-1/region/r.0.0.mca"), "nether merged into DIM-1")
	check(names.has("world/DIM1/region/r.0.0.mca"), "end merged into DIM1")
	check(not names.any(func(n: String) -> bool: return n.ends_with("session.lock") or n.ends_with("uid.dat")), "lock/uid files skipped")
	check(not names.any(func(n: String) -> bool: return n.begins_with("world_nether")), "no sibling folders in the zip")
	var zip := dir.path_join("export.zip")
	check_eq(WorldManager.export_zip(dir, world, zip, {"mutex": Mutex.new(), "progress": 0.0}), "", "zip written")
	var tree := Engine.get_main_loop() as SceneTree
	var analysis: Dictionary = await WorldImporter.analyze(tree.root, zip, "1.21.11")
	check(analysis.ok, "exported zip imports cleanly: %s" % analysis.error)
	check_eq(analysis.layout, WorldImporter.Layout.SINGLEPLAYER, "exported as singleplayer layout")
	check_eq(analysis.dimensions, PackedStringArray(["Overworld", "Nether", "End"]), "all dimensions present")
	WorldImporter.cleanup(analysis)
	FileOps.remove_tree(dir)


func test_pack_meta_parsing() -> void:
	var m := WorldManager.parse_pack_meta('{"pack": {"description": "Simple", "pack_format": 94}}')
	check(m.valid and m.description == "Simple" and m.format == "94", "plain description")
	m = WorldManager.parse_pack_meta('{"pack": {"description": {"text": "Red ", "extra": [{"text": "pack"}]}, "min_format": 94, "max_format": [94, 1]}}')
	check_eq(m.description, "Red pack", "text component description")
	check_eq(m.format, "94", "max_format as [major, minor]")
	m = WorldManager.parse_pack_meta('{"pack": {"description": ["§aGreen", {"text": " too"}], "pack_format": 48}}')
	check_eq(m.description, "Green too", "array description, colour codes stripped")
	check(not WorldManager.parse_pack_meta("not json").valid, "invalid json")
	check(not WorldManager.parse_pack_meta('{"meta": {}}').valid, "missing pack section")


func test_datapack_list_parsing_and_commands() -> void:
	var enabled := WorldManager.parse_datapack_list("There are 3 data pack(s) enabled: [vanilla (built-in)], [file/test (world)], [file/My Pack.zip (world)]")
	check_eq(enabled, PackedStringArray(["vanilla", "file/test", "file/My Pack.zip"]), "enabled list")
	check_eq(WorldManager.parse_datapack_list("There are no more data packs available"), PackedStringArray(), "nothing available")
	check_eq(WorldManager.parse_datapack_list("There are 1 data pack(s) available: [§afile/x§r (world)]"), PackedStringArray(["file/x"]), "colour codes")
	check_eq(WorldManager.datapack_command("file/My \"Pack\".zip", false), "datapack disable \"file/My \\\"Pack\\\".zip\"", "quoted command")


func test_add_and_list_datapacks() -> void:
	var dir := _tmp()
	var packs := dir.path_join("world/datapacks")
	var good := dir.path_join("good.zip")
	var zp := ZIPPacker.new()
	zp.open(good)
	zp.start_file("pack.mcmeta")
	zp.write_file('{"pack": {"description": "Good pack", "pack_format": 94}}'.to_utf8_buffer())
	zp.close_file()
	zp.close()
	var bad := dir.path_join("nested.zip")
	zp.open(bad)
	zp.start_file("nested/pack.mcmeta")
	zp.write_file("{}".to_utf8_buffer())
	zp.close_file()
	zp.close()
	_touch(dir.path_join("folderpack/pack.mcmeta"), '{"pack": {"description": "Folder pack", "pack_format": 94}}')
	check_eq(WorldManager.add_datapack(packs, good), "", "zip added")
	check(WorldManager.add_datapack(packs, bad).contains("pack.mcmeta"), "nested zip rejected with a reason")
	check_eq(WorldManager.add_datapack(packs, dir.path_join("folderpack")), "", "folder added")
	check(WorldManager.add_datapack(packs, good).contains("already"), "duplicate rejected")
	var list := WorldManager.list_datapacks(packs)
	check_eq(list.map(func(p: Dictionary) -> String: return p.id), ["file/folderpack", "file/good.zip"], "pack ids")
	check_eq(list[1].description, "Good pack", "description read from inside the zip")
	check_eq(WorldManager.remove_datapack(list[1]), "", "removed")
	check_eq(WorldManager.list_datapacks(packs).size(), 1, "one left")
	FileOps.remove_tree(dir)


func test_running_world_before_first_save() -> void:
	# A server that just generated its world has region data but no level.dat yet.
	var dir := ProjectSettings.globalize_path("user://test-unsaved-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir.path_join("world/region"))
	var worlds := WorldManager.list_worlds(dir, "world", false)
	check_eq(worlds.size(), 1, "one world")
	check(worlds[0].generated and worlds[0].active and worlds[0].unsaved, "listed as an active, generated world")
	FileOps.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var fresh := WorldManager.list_worlds(dir, "world", false)
	check(not fresh[0].generated, "no data yet: still a placeholder")
	FileOps.remove_tree(dir)
