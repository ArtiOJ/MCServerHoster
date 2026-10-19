extends TestCase

const FIX_121 := "res://tests/fixtures/level_1_21_11.dat"
const FIX_263 := "res://tests/fixtures/level_26_3.dat"
const FIX_GEN := "res://tests/fixtures/world_gen_settings_26.dat"
const FIX_OVERRIDES := "res://tests/fixtures/level_overrides_26.dat"


func _root() -> Node:
	return (Engine.get_main_loop() as SceneTree).root


func _tmp(name: String) -> String:
	var dir := ProjectSettings.globalize_path("user://test-world-%s-%d" % [name, Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


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


func test_single_dimension_becomes_the_overworld() -> void:
	# A Paper 26 world like dimensions/minecraft/islands/, downloaded without its level.dat.
	var src := _tmp("dim")
	var dim := src.path_join("islands")
	_touch(dim.path_join("region/r.0.0.mca"))
	_touch(dim.path_join("entities/r.0.0.mca"))
	_touch(dim.path_join("data/minecraft/world_gen_settings.dat"), FIX_GEN)
	_touch(dim.path_join("data/paper/metadata.dat"))
	_touch(dim.path_join("session.lock"))
	_touch(dim.path_join("data/paper/level_overrides.dat"), FIX_OVERRIDES)
	check(WorldImporter.is_dimension_dir(dim), "dimension folder recognised")
	check(not WorldImporter.is_dimension_dir(src), "its parent is not a dimension")
	var a: Dictionary = await WorldImporter.analyze(_root(), dim, "26.3")
	check(a.ok, "dimension ok: " + str(a.error))
	check_eq(a.layout, WorldImporter.Layout.DIMENSION, "single dimension layout")
	check_eq(WorldImporter.display_name(a), "islands", "named after its folder")
	check_eq(a.dimensions, PackedStringArray(["Overworld"]), "becomes the overworld")
	check(a.game_mode == "adventure" and a.difficulty == "hard", "settings from level_overrides.dat (%s/%s)" % [a.game_mode, a.difficulty])
	check_eq(a.spawn, [3251, 77, -4467], "spawn from level_overrides.dat")
	check_eq(Nbt.dig(a.generator, ["settings", "biome"]), "minecraft:the_void", "generator from world_gen_settings.dat")
	var b: Dictionary = await WorldImporter.analyze(_root(), src, "26.3")
	check(b.ok and b.world_dir == dim, "found one level down")
	var old: Dictionary = await WorldImporter.analyze(_root(), dim, "1.21.11")
	check(not old.ok, "blocked on a pre-26 server: " + old.error)
	var out := _tmp("place-dim")
	check_eq(WorldImporter.place_world(a, out, "islands", "26.3"), OK, "place")
	var overworld := out.path_join("islands/dimensions/minecraft/overworld")
	check(FileAccess.file_exists(overworld.path_join("region/r.0.0.mca")), "terrain in the overworld")
	check(FileAccess.file_exists(overworld.path_join("data/paper/level_overrides.dat")), "Paper settings kept")
	check(not FileAccess.file_exists(overworld.path_join("data/paper/metadata.dat")), "world UUID dropped")
	check(not FileAccess.file_exists(overworld.path_join("session.lock")), "session.lock dropped")
	check(FileAccess.file_exists(dim.path_join("region/r.0.0.mca")), "folder source left untouched")
	var pack := _read_json(out.path_join("islands/datapacks/dimension-overworld/data/minecraft/dimension/overworld.json"))
	check_eq(Nbt.dig(pack, ["generator", "type"]), "minecraft:flat", "overworld generator kept by a datapack")

	# Added to an existing world as an extra dimension.
	var world := _tmp("dim-into")
	_touch(world.path_join("world/dimensions/minecraft/overworld/region/r.0.0.mca"))
	_touch(world.path_join("world/dimensions/minecraft/islands/region/r.0.0.mca"))
	check_eq(WorldImporter.unique_dimension_id(world.path_join("world"), "islands"), "islands_2", "dimension name not reused")
	check_eq(WorldImporter.unique_dimension_id(world.path_join("world"), "The End"), "imported_the_end", "vanilla names avoided")
	check_eq(a.dimension_choices.size(), 1, "one dimension to add")
	check_eq(WorldImporter.place_dimension(a.dimension_choices[0], world.path_join("world"), "islands_2"), OK, "place as dimension")
	var added := world.path_join("world/dimensions/minecraft/islands_2")
	check(FileAccess.file_exists(added.path_join("region/r.0.0.mca")) and not FileAccess.file_exists(added.path_join("session.lock")), "dimension copied")
	var def := _read_json(world.path_join("world/datapacks/dimension-islands_2/data/minecraft/dimension/islands_2.json"))
	check_eq(def.get("type"), "minecraft:overworld", "dimension type")
	check_eq(Nbt.dig(def, ["generator", "settings", "features"]), false, "flags written as JSON booleans")
	var layers: Variant = Nbt.dig(def, ["generator", "settings", "layers"], [])
	check(layers is Array and layers.size() == 1 and layers[0].get("block") == "minecraft:air", "void layers kept")
	var meta := _read_json(world.path_join("world/datapacks/dimension-islands_2/pack.mcmeta"))
	check(int(Nbt.dig(meta, ["pack", "min_format"], 0)) > 0, "pack.mcmeta written")
	check_eq(WorldImporter.teleport_command("minecraft:islands_2", a.spawn), "/execute in minecraft:islands_2 run tp @s 3251 77 -4467", "teleport command")
	check_eq(WorldImporter.teleport_command("minecraft:x", []), "/execute in minecraft:x run spreadplayers 0 0 0 1 false @s", "onto the surface without a spawn")
	check_eq(WorldImporter.teleport_command("minecraft:x", [10, -2028, 20]), "/execute in minecraft:x run spreadplayers 10 20 0 1 false @s", "bogus spawn height ignored")
	check_eq(WorldImporter.teleport_command("minecraft:n", [], "minecraft:the_nether"), "/execute in minecraft:n run spreadplayers 0 0 0 1 under 120 false @s", "below the nether roof")
	var listed := WorldImporter.detect_layout(world.path_join("world"))
	check(listed.dimensions.has("islands") and listed.dimensions.has("islands_2"), "extra dimensions listed: %s" % ", ".join(listed.dimensions))
	FileOps.remove_tree(world)

	# A whole dimensions folder without its world: the overworld is chosen.
	var many := _tmp("dims-only")
	for name in ["the_nether", "overworld", "the_end"]:
		_touch(many.path_join("minecraft/%s/region/r.0.0.mca" % name))
		_touch(many.path_join("minecraft/%s/data/minecraft/world_gen_settings.dat" % name))
	var c: Dictionary = await WorldImporter.analyze(_root(), many, "26.3")
	check(c.ok and c.world_dir.get_file() == "overworld", "overworld picked from several dimensions")
	for x in [src, out, many]:
		FileOps.remove_tree(x)


func test_dimension_choices() -> void:
	# A dimension folder that still carries the singleplayer save it was copied from.
	var mixed := _tmp("mixed").path_join("old_map")
	_touch(mixed.path_join("level.dat"), FIX_263)
	_touch(mixed.path_join("dimensions/minecraft/overworld/region/r.0.0.mca"))
	_touch(mixed.path_join("dimensions/minecraft/the_nether/data/minecraft/raids.dat"))
	_touch(mixed.path_join("players/data/x.dat"))
	_touch(mixed.path_join("region/r.0.0.mca"))
	_touch(mixed.path_join("data/minecraft/world_gen_settings.dat"), FIX_GEN)
	var a: Dictionary = await WorldImporter.analyze(_root(), mixed, "26.3")
	check(a.ok and a.layout == WorldImporter.Layout.DIMENSION, "newer dimension data wins over the old save: %s" % WorldImporter.LAYOUT_NAMES[a.layout])
	check(Array(a.warnings).any(func(w: String) -> bool: return w.contains("older save")), "older save mentioned")
	var labels: Array = a.dimension_choices.map(func(c: Dictionary) -> String: return c.label)
	check_eq(labels, ["old_map", "Overworld (older save)"], "choices (the nether has no terrain)")
	check_eq(Nbt.dig(a.dimension_choices[1].generator, ["settings", "biome"]), "minecraft:the_void", "old save's generator from the folder's settings")
	var out := _tmp("mixed-out")
	check_eq(WorldImporter.place_world(a, out, "bt", "26.3"), OK, "place as a world")
	var overworld := out.path_join("bt/dimensions/minecraft/overworld")
	check(FileAccess.file_exists(overworld.path_join("region/r.0.0.mca")), "newer terrain placed")
	for leftover in ["level.dat", "dimensions", "players"]:
		check(not FileAccess.file_exists(overworld.path_join(leftover)) and not DirAccess.dir_exists_absolute(overworld.path_join(leftover)), "%s of the old save left out" % leftover)
	check(not FileAccess.file_exists(out.path_join("bt/level.dat")), "no stale level.dat for the new world")
	check_eq(WorldImporter.place_dimension(a.dimension_choices[1], out.path_join("bt"), "old"), OK, "older save's overworld added")
	check(FileAccess.file_exists(out.path_join("bt/dimensions/minecraft/old/region/r.0.0.mca")), "older terrain placed as its own dimension")

	# A whole 26+ world: any of its dimensions.
	var world := _tmp("world26").path_join("Castle")
	_touch(world.path_join("level.dat"), FIX_263)
	for d in ["overworld", "the_nether", "the_end"]:
		_touch(world.path_join("dimensions/minecraft/%s/region/r.0.0.mca" % d))
	_touch(world.path_join("dimensions/minecraft/the_nether/data/minecraft/world_gen_settings.dat"), FIX_GEN)
	var b: Dictionary = await WorldImporter.analyze(_root(), world, "26.3")
	check(b.ok and b.layout == WorldImporter.Layout.DIMENSIONS, "whole world")
	var by_label := {}
	for c in b.dimension_choices:
		by_label[c.label] = c
	check_eq(by_label.keys(), ["Overworld", "Nether", "End"], "every dimension offered, in order")
	var base := WorldImporter.display_name(b)
	check_eq([by_label.Overworld.name, by_label.Nether.name, by_label.End.name], [base, base + "_nether", base + "_end"], "names from the world")
	check_eq(by_label.Nether.type, "minecraft:the_nether", "nether dimension type")
	check_eq(by_label.Nether.generator.get("settings"), "minecraft:nether", "nether generator (its settings have no nether entry)")
	check_eq(by_label.End.generator.get("settings"), "minecraft:end", "vanilla end generator when nothing is saved")

	# Older layouts can't be added as dimensions.
	var legacy := _tmp("legacy-dims")
	_touch(legacy.path_join("w/level.dat"), FIX_121)
	_touch(legacy.path_join("w/region/r.0.0.mca"))
	var c: Dictionary = await WorldImporter.analyze(_root(), legacy, "26.3")
	check(c.dimension_choices.is_empty(), "no dimension choices for a pre-26 world")
	for x in [mixed.get_base_dir(), out, world.get_base_dir(), legacy]:
		FileOps.remove_tree(x)


func test_dimension_height_and_landing() -> void:
	# One normal-height chunk with only air, one from a taller world (Y -128 to 383) with
	# stone at the bottom; the same dimension can hold both after its height was changed.
	var dim := _tmp("heights")
	_touch(dim.path_join("data/minecraft/world_gen_settings.dat"), FIX_GEN)
	DirAccess.make_dir_recursive_absolute(dim.path_join("region"))
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/fixtures/region_two_heights.mca"), dim.path_join("region/r.0.0.mca"))
	check_eq(WorldImporter.dimension_range(dim), [-128, 512], "widest saved range")
	check_eq(WorldImporter.find_landing(dim), [21, -112, 0], "lands on the first chunk with blocks (10-bit height map)")
	check(WorldImporter.is_usable_spawn([0, -100, 0], [-128, 512]) and not WorldImporter.is_usable_spawn([0, -100, 0]), "spawn checked against the dimension's own height")
	check_eq(WorldImporter.teleport_command("minecraft:t", [0, -100, 0], "", [-128, 512]), "/execute in minecraft:t run tp @s 0 -100 0", "deep spawn kept in a taller dimension")

	var a: Dictionary = await WorldImporter.analyze(_root(), dim, "26.3")
	var choice: Dictionary = a.dimension_choices[0]
	check(Array(a.warnings).any(func(w: String) -> bool: return w.contains("taller than normal (Y -128 to 383)")), "taller height mentioned")
	var server := _tmp("heights-server")
	var missing := WorldImporter.custom_dimension_type(server, choice)
	check(not missing.ok and missing.error.contains("Start the server once"), "needs the server's unpacked jar: " + str(missing.get("error", "")))
	# A stand-in for the jar Paper unpacks into versions/ on first start.
	DirAccess.make_dir_recursive_absolute(server.path_join("versions/26.3"))
	var zip := ZIPPacker.new()
	zip.open(server.path_join("versions/26.3/paper-26.3.jar"))
	zip.start_file("data/minecraft/dimension_type/overworld.json")
	zip.write_file('{"min_y": -64, "height": 384, "logical_height": 384, "coordinate_scale": 1.0, "ambient_light": 0.25}'.to_utf8_buffer())
	zip.close_file()
	zip.close()
	var custom := WorldImporter.custom_dimension_type(server, choice)
	check(custom.ok, "type built from the server's vanilla one")
	var def: Dictionary = custom.definition
	check(def.min_y == -128 and def.height == 512 and def.logical_height == 512, "saved height range: %s" % def)
	check(typeof(def.coordinate_scale) == TYPE_INT and is_equal_approx(def.ambient_light, 0.25), "whole numbers as ints, fractions kept")
	check(WorldImporter.custom_dimension_type(server, {"type": "minecraft:overworld", "min_y": -64, "height": 384}).definition.is_empty(), "no type needed at the normal height")
	var world := _tmp("heights-world")
	check_eq(WorldImporter.place_dimension(choice, world, "deep", false, def), OK, "placed with its type")
	var stem := _read_json(world.path_join("datapacks/dimension-deep/data/minecraft/dimension/deep.json"))
	check_eq(stem.get("type"), "server_manager:deep", "dimension uses its own type")
	check(FileAccess.file_exists(world.path_join("datapacks/dimension-deep/data/server_manager/dimension_type/deep.json")), "type written")
	for x in [dim, server, world]:
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
