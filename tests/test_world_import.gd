extends TestCase

const FIX_121 := "res://tests/fixtures/level_1_21_11.dat"
const FIX_263 := "res://tests/fixtures/level_26_3.dat"


func _root() -> Node:
	return (Engine.get_main_loop() as SceneTree).root


func _tmp(name: String) -> String:
	var dir := ProjectSettings.globalize_path("user://test-world-%s-%d" % [name, Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _touch(path: String, level_dat := "") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if level_dat != "":
		DirAccess.copy_absolute(ProjectSettings.globalize_path(level_dat), path)
	else:
		FileAccess.open(path, FileAccess.WRITE).store_string("x")


func test_nbt_reads_level_dat_from_both_versions() -> void:
	var old := Nbt.read_file(ProjectSettings.globalize_path(FIX_121))
	check_eq(Nbt.dig(old, ["Data", "Version", "Name"]), "1.21.11", "1.21 version name")
	check_eq(Nbt.dig(old, ["Data", "DataVersion"]), 4671, "1.21 data version")
	check_eq(Nbt.dig(old, ["Data", "Difficulty"]), 1, "1.21 difficulty byte")
	var new := Nbt.read_file(ProjectSettings.globalize_path(FIX_263))
	check_eq(Nbt.dig(new, ["Data", "Version", "Name"]), "26.3", "26.3 version name")
	check_eq(Nbt.dig(new, ["Data", "difficulty_settings", "difficulty"]), "easy", "26.x difficulty string")
	check_eq(Nbt.dig(new, ["Data", "Missing", "Path"], "dflt"), "dflt", "missing path default")


func test_nbt_rejects_garbage() -> void:
	check(Nbt.parse(PackedByteArray([1, 2, 3, 4, 5])).is_empty(), "random bytes")
	var raw := FileAccess.get_file_as_bytes(FIX_121)
	check(Nbt.parse(raw.slice(0, raw.size() / 2)).is_empty(), "truncated gzip")
	# A compound claiming a list of a billion entries must fail fast, not allocate.
	var evil := PackedByteArray([10, 0, 0, 9, 0, 1, 0x61, 1, 0x40, 0, 0, 0])
	check(Nbt.parse(evil).is_empty(), "absurd list length")


func test_detects_singleplayer_split_and_dimensions_layouts() -> void:
	var sp := _tmp("sp")
	_touch(sp.path_join("My Map/level.dat"), FIX_121)
	_touch(sp.path_join("My Map/region/r.0.0.mca"))
	_touch(sp.path_join("My Map/DIM-1/region/r.0.0.mca"))
	_touch(sp.path_join("My Map/DIM1/region/r.0.0.mca"))
	var a: Dictionary = await WorldImporter.analyze(_root(), sp, "1.21.11")
	check(a.ok, "singleplayer ok: " + str(a.error))
	check_eq(a.layout, WorldImporter.Layout.SINGLEPLAYER, "singleplayer layout")
	check_eq(a.dimensions, PackedStringArray(["Overworld", "Nether", "End"]), "all dimensions")
	var out := _tmp("place-sp")
	check_eq(WorldImporter.place_world(a, out, "world", "1.21.11"), OK, "place")
	check(FileAccess.file_exists(out.path_join("world_nether/DIM-1/region/r.0.0.mca")), "nether moved to split folder")
	check(FileAccess.file_exists(out.path_join("world_the_end/DIM1/region/r.0.0.mca")), "end moved to split folder")
	check(not DirAccess.dir_exists_absolute(out.path_join("world/DIM-1")), "no nether left inside")
	check(FileAccess.file_exists(sp.path_join("My Map/DIM-1/region/r.0.0.mca")), "folder source left untouched")
	var out26 := _tmp("place-sp26")
	check_eq(WorldImporter.place_world(a, out26, "world", "26.3"), OK, "place for 26.3")
	check(FileAccess.file_exists(out26.path_join("world/DIM-1/region/r.0.0.mca")), "26.x: nether stays inside for Minecraft's upgrade")
	check(not DirAccess.dir_exists_absolute(out26.path_join("world_nether")), "26.x: no split folders")

	var split := _tmp("split")
	_touch(split.path_join("survival/level.dat"), FIX_121)
	_touch(split.path_join("survival/region/r.0.0.mca"))
	_touch(split.path_join("survival/uid.dat"))
	_touch(split.path_join("survival_nether/level.dat"), FIX_121)
	_touch(split.path_join("survival_nether/DIM-1/region/r.0.0.mca"))
	_touch(split.path_join("survival_the_end/DIM1/region/r.0.0.mca"))
	var b: Dictionary = await WorldImporter.analyze(_root(), split, "1.21.11")
	check_eq(b.layout, WorldImporter.Layout.SPLIT, "split layout")
	check_eq(b.world_dir.get_file(), "survival", "picks the main world, not the nether sibling")
	var out2 := _tmp("place-split")
	WorldImporter.place_world(b, out2, "My_Map", "1.21.11")
	check(FileAccess.file_exists(out2.path_join("My_Map_nether/DIM-1/region/r.0.0.mca")), "siblings renamed to the level name")
	var out2b := _tmp("place-split26")
	WorldImporter.place_world(b, out2b, "My_Map", "26.3")
	check(FileAccess.file_exists(out2b.path_join("My_Map/DIM-1/region/r.0.0.mca")) and FileAccess.file_exists(out2b.path_join("My_Map/DIM1/region/r.0.0.mca")), "26.x: split world folded into the singleplayer layout")
	check(not DirAccess.dir_exists_absolute(out2b.path_join("My_Map_nether")), "26.x: sibling folders not created")
	check(not FileAccess.file_exists(out2.path_join("My_Map/uid.dat")), "uid.dat dropped")

	var dims := _tmp("dims")
	_touch(dims.path_join("world/level.dat"), FIX_263)
	_touch(dims.path_join("world/dimensions/minecraft/the_nether/region/r.0.0.mca"))
	var c: Dictionary = await WorldImporter.analyze(_root(), dims, "26.3")
	check(c.ok and c.layout == WorldImporter.Layout.DIMENSIONS, "26.x layout ok on 26.3")
	var d: Dictionary = await WorldImporter.analyze(_root(), dims, "1.21.11")
	check(not d.ok and d.error.contains("newer"), "26.x world blocked on 1.21.11: " + d.error)
	for x in [sp, out, out26, split, out2, out2b, dims]:
		FileOps.remove_tree(x)


func test_version_warning_and_settings() -> void:
	var dir := _tmp("ver")
	_touch(dir.path_join("w/level.dat"), FIX_121)
	var a: Dictionary = await WorldImporter.analyze(_root(), dir, "26.3")
	check(a.ok, "older world allowed")
	check(Array(a.warnings).any(func(w: String) -> bool: return w.contains("upgraded")), "upgrade warning")
	check(Array(a.warnings).any(func(w: String) -> bool: return w.contains("no saved terrain")), "no-terrain warning")
	check_eq(a.game_mode, "survival", "game mode read")
	check_eq(a.difficulty, "easy", "difficulty read")
	FileOps.remove_tree(dir)


func test_rejects_bedrock_and_empty() -> void:
	var bed := _tmp("bedrock")
	_touch(bed.path_join("world/db/CURRENT"))
	_touch(bed.path_join("world/levelname.txt"))
	var a: Dictionary = await WorldImporter.analyze(_root(), bed, "")
	check(not a.ok and a.error.contains("Bedrock"), "bedrock folder: " + a.error)
	var mcworld := bed.path_join("map.mcworld")
	_touch(mcworld)
	var b: Dictionary = await WorldImporter.analyze(_root(), mcworld, "")
	check(not b.ok and b.error.contains("Bedrock"), ".mcworld file")
	var empty := _tmp("empty")
	var c: Dictionary = await WorldImporter.analyze(_root(), empty, "")
	check(not c.ok and c.error.contains("level.dat"), "no world")
	FileOps.remove_tree(bed)
	FileOps.remove_tree(empty)


func test_zip_extraction_is_contained() -> void:
	var dir := _tmp("zip")
	var zip_path := dir.path_join("map.zip")
	var zip := ZIPPacker.new()
	zip.open(zip_path)
	zip.start_file("../escaped.txt")
	zip.write_file("nope".to_utf8_buffer())
	zip.close_file()
	zip.start_file("Map/level.dat")
	zip.write_file(FileAccess.get_file_as_bytes(FIX_121))
	zip.close_file()
	zip.close()
	var out := dir.path_join("out")
	check_eq(WorldImporter.extract_zip(zip_path, out), "", "extracts")
	check(FileAccess.file_exists(out.path_join("Map/level.dat")), "world extracted")
	check(not FileAccess.file_exists(dir.path_join("escaped.txt")), "traversal entry skipped")
	FileOps.remove_tree(dir)


func test_display_name_prefers_meaningful_names() -> void:
	check_eq(WorldImporter.display_name({"name": "Skyblock", "world_dir": "/x/sb"}), "Skyblock", "level name")
	check_eq(WorldImporter.display_name({"name": "world", "world_dir": "/tmp/import-1/Adventure Map"}), "Adventure Map", "generic name -> folder")
	check_eq(WorldImporter.display_name({"name": "world", "world_dir": "/tmp/_temp/import-2026-abc"}), "world", "staging folder never used")


func test_unique_level_names() -> void:
	var dir := _tmp("names")
	check_eq(WorldImporter.unique_level_name(dir, "Skyblock: Classic!"), "Skyblock_Classic", "sanitised")
	DirAccess.make_dir_recursive_absolute(dir.path_join("Skyblock_Classic"))
	check_eq(WorldImporter.unique_level_name(dir, "Skyblock: Classic!"), "Skyblock_Classic_2", "unique")
	check_eq(WorldImporter.unique_level_name(dir, "plugins"), "imported_world", "reserved folder avoided")
	FileOps.remove_tree(dir)
