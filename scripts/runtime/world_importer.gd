class_name WorldImporter
extends RefCounted
## Imports a Minecraft Java world (a downloaded map, a singleplayer save or another
## server's world) into a server, from a .zip or a folder.
##
## Layouts (verified by booting real Paper 1.21.11 and 26.3):
##   SINGLEPLAYER - vanilla save: nether/end live in DIM-1/ and DIM1/ inside the world folder.
##   SPLIT        - Bukkit/Paper before 26: <level>/, <level>_nether/DIM-1/, <level>_the_end/DIM1/.
##   DIMENSIONS   - Minecraft/Paper 26+: <level>/dimensions/minecraft/<dimension>/.
##   DIMENSION    - one Minecraft 26+ dimension on its own (e.g. a Paper world such as
##                  dimensions/minecraft/<name>/), usually without a level.dat. It becomes the
##                  overworld of a world, or an extra dimension of the current world (Mode.DIMENSION).
##                  Its world_gen_settings.dat keeps the seed and Paper's level_overrides.dat the
##                  spawn; the generator travels as a small datapack, because Minecraft only takes
##                  dimension generators from the world preset or datapacks (verified with Paper 26.3).
## Normalisation depends on the target server (both paths verified with real Paper):
##   Paper before 26.1 - SPLIT, sibling folders named after the target level-name.
##   Paper 26.1+       - SINGLEPLAYER: Minecraft's own upgrade turns it into DIMENSIONS on
##                       first start. (A SPLIT world whose nether/end folders lack their own
##                       level.dat crashes Paper 26's legacy importer, so it is not used.)
## DIMENSIONS worlds are copied as they are.

enum Layout { SINGLEPLAYER, SPLIT, DIMENSIONS, DIMENSION }
## REPLACE_KEEP replaces the world but carries the dimensions added to it (anything besides
## the overworld, Nether and End, with the datapacks defining them) into the new one.
enum Mode { REPLACE, ADD, DIMENSION, REPLACE_KEEP }

const LAYOUT_NAMES: PackedStringArray = ["Singleplayer save", "Bukkit/Paper (separate nether and end folders)", "Minecraft 26+ (dimensions folder)", "Minecraft 26+ (single dimension)"]
const GAME_MODES: PackedStringArray = ["survival", "creative", "adventure", "spectator"]
const DIFFICULTIES: PackedStringArray = ["peaceful", "easy", "normal", "hard"]
const SEARCH_DEPTH := 4
## Files that must not be carried over: Paper recreates them, and stale copies cause
## "world already loaded" UUID clashes or lock errors.
const DROP_FILES: PackedStringArray = ["session.lock", "uid.dat"]
## Paper 26+ keeps a world's UUID here (the successor of uid.dat).
const PAPER_UUID_FILE := "data/paper/metadata.dat"
## What a dimension folder may still carry from the world it was copied from before a server
## used it as a dimension (seen in real downloads: a whole singleplayer save, with Paper's
## newer dimension data written next to it). Left out, since the server never read them.
const DIMENSION_LEFTOVERS: PackedStringArray = ["level.dat", "level.dat_old", "dimensions", "players", "playerdata"]
## Folders inside a world or dimension that never hold another world.
const WORLD_DATA_DIRS: PackedStringArray = ["region", "DIM-1", "DIM1", "playerdata", "players", "data", "datapacks", "entities", "poi"]
const IGNORED_DIRS: PackedStringArray = ["__MACOSX", ".git"]
## First Minecraft version that stores worlds in the DIMENSIONS layout.
const DIMENSIONS_SINCE := "26.1"
## Datapack format range for generated packs: 1.21.9 introduced min/max_format, and every
## 26.x server is well inside the range.
const PACK_MIN_FORMAT := 88
const PACK_MAX_FORMAT := 999
const VANILLA_DIMENSIONS: PackedStringArray = ["overworld", "the_nether", "the_end"]
## Vanilla generators, used when a dimension's world_gen_settings.dat can't be read.
const DEFAULT_GENERATORS := {
	"overworld": {"type": "minecraft:noise", "settings": "minecraft:overworld",
			"biome_source": {"type": "minecraft:multi_noise", "preset": "minecraft:overworld"}},
	"the_nether": {"type": "minecraft:noise", "settings": "minecraft:nether",
			"biome_source": {"type": "minecraft:multi_noise", "preset": "minecraft:nether"}},
	"the_end": {"type": "minecraft:noise", "settings": "minecraft:end", "biome_source": {"type": "minecraft:the_end"}},
}
const DIMENSION_LABELS := {"overworld": "Overworld", "the_nether": "Nether", "the_end": "End"}
## Lowest and highest block of the overworld; a spawn outside them can't be teleported to.
const MIN_BUILD_Y := -64
const MAX_BUILD_Y := 319
## Most chunks [method find_landing] decodes before giving up.
const LANDING_SCAN_CHUNKS := 4096
const AIR_BLOCKS: PackedStringArray = ["minecraft:air", "minecraft:cave_air", "minecraft:void_air"]
## Vertical range [min_y, height] of the vanilla dimension types. A dimension saved with
## another range (worlds made taller by a datapack or plugin) gets its own dimension type,
## or Minecraft would drop every block outside the normal range when loading it.
const VANILLA_RANGES := {"minecraft:overworld": [-64, 384], "minecraft:the_nether": [0, 256], "minecraft:the_end": [0, 256]}
## Chunks [method dimension_range] reads: a few from each region file, at most this many.
const RANGE_SAMPLES_PER_REGION := 4
const RANGE_SAMPLES := 96
## Namespace of the dimension types written by the importer, so they never replace one.
const TYPE_NAMESPACE := "server_manager"


## Inspects [param source] (.zip or folder). Zips are extracted to a staging folder,
## which [method cleanup] deletes. [param server_version] enables the version check.
## Returns {ok, error, warnings, name, version, data_version, layout, game_mode, difficulty,
## hardcore, dimensions, size_bytes, world_dir, nether_src, end_src, staging, source, resource_pack,
## dimension_type, generator, spawn, dimension_choices}. dimension_type/generator/spawn describe
## a single dimension; dimension_choices lists the 26+ dimensions that can be added to a world
## (see [method _dimension_choice]).
static func analyze(owner: Node, source: String, server_version := "") -> Dictionary:
	var result := {
		"ok": false, "error": "", "warnings": PackedStringArray(), "source": source, "staging": "",
		"name": "", "version": "", "data_version": 0, "layout": Layout.SINGLEPLAYER,
		"game_mode": "", "difficulty": "", "hardcore": false, "dimensions": PackedStringArray(),
		"size_bytes": 0, "world_dir": "", "nether_src": "", "end_src": "", "resource_pack": false,
		"dimension_type": "", "generator": {}, "spawn": [], "dimension_choices": [],
	}
	var root := source
	if FileAccess.file_exists(source):
		var ext := source.get_extension().to_lower()
		if ext == "mcworld" or ext == "mctemplate":
			result.error = "This is a Bedrock Edition world. Paper servers run Java Edition and cannot load Bedrock worlds."
			return result
		if ext != "zip":
			result.error = "Choose a .zip file or a world folder."
			return result
		var staging := AppSettings.servers_root.path_join("_temp").path_join("import-%s-%s" % [Fmt.file_stamp(int(Time.get_unix_time_from_system())), Fmt.random_token(4).to_lower()])
		result.staging = staging
		var err: String = await FileOps.run_async(owner, func() -> String: return extract_zip(source, staging))
		if err != "":
			result.error = err
			cleanup(result)
			return result
		root = staging
	elif not DirAccess.dir_exists_absolute(source):
		result.error = "%s does not exist." % source
		return result

	var bedrock := _find_bedrock(root, 0)
	var candidates := find_level_dirs(root)
	var world_dir := ""
	if candidates.is_empty():
		var dims := find_dimension_dirs(root)
		if dims.is_empty():
			result.error = "This is a Bedrock Edition world. Paper servers run Java Edition and cannot load Bedrock worlds." if bedrock \
					else "No Minecraft world was found (there is no level.dat or dimension in it)."
			cleanup(result)
			return result
		world_dir = pick_dimension(dims)
		if dims.size() > 1:
			result.warnings.append("Found %d dimensions without their world; importing \"%s\"." % [dims.size(), world_dir.get_file()])
	else:
		world_dir = pick_world(candidates)
		if candidates.size() > 1:
			var others := Array(candidates).filter(func(c: String) -> bool:
				return c != world_dir and not c.ends_with("_nether") and not c.ends_with("_the_end"))
			if not others.is_empty():
				result.warnings.append("Found %d worlds; importing \"%s\"." % [others.size() + 1, world_dir.get_file()])
	result.world_dir = world_dir
	if is_dimension_dir(world_dir):
		_read_dimension(world_dir, result)
	else:
		_detect_layout(world_dir, result)
		_read_level(world_dir.path_join("level.dat"), result)
	result.dimension_choices = _list_dimension_choices(world_dir, result)

	if server_version != "" and result.version != "":
		var cmp := Fmt.compare_versions(result.version, server_version)
		if cmp > 0:
			result.error = "This world was saved in Minecraft %s, but the server runs %s. Minecraft cannot load worlds from newer versions; update the server first." % [result.version, server_version]
		elif cmp < 0:
			result.warnings.append("Saved in %s; it will be upgraded to %s on first start. Upgraded worlds can't be opened in %s again." % [result.version, server_version, result.version])
	elif result.version == "" and result.layout != Layout.DIMENSION:
		result.warnings.append("The world's Minecraft version is unknown (very old save?). It will be upgraded on first start.")
	var modern: bool = result.layout == Layout.DIMENSIONS or result.layout == Layout.DIMENSION
	if not modern and server_version != "" and uses_dimensions_layout(server_version):
		result.warnings.append("On its first start Paper converts the world to the 26+ storage format; it pauses for 30 seconds before doing so.")
	if modern and server_version != "" and not uses_dimensions_layout(server_version) and result.error == "":
		result.error = "This world uses the Minecraft 26+ storage layout, which %s cannot load. Use a 26.x server." % server_version
	if result.dimensions.is_empty():
		result.warnings.append("The world has no saved terrain yet; it will be generated from its seed.")
	if FileAccess.file_exists(world_dir.path_join("resources.zip")):
		result.resource_pack = true
		result.warnings.append("The map includes a resource pack (resources.zip). Servers can only send packs from a web link: upload it somewhere and set it in Settings → Resource pack.")
	# Nether/end folders inside the world folder are already counted with it.
	var dirs := [world_dir]
	for d in [result.nether_src, result.end_src]:
		if d != "" and not (d as String).begins_with(world_dir + "/"):
			dirs.append(d)
	result.size_bytes = await FileOps.run_async(owner, func() -> int:
		var total := 0
		for d in dirs:
			total += dir_size(d)
		return total)
	result.ok = result.error == ""
	return result


## Imports an analysed world into [param inst] (which must be stopped).
## [param on_status] receives progress text. Returns {ok, error, level_name}.
## [param dimension_index] picks the entry of dimension_choices that Mode.DIMENSION adds.
## [param keep_server_conflicts]: with Mode.REPLACE_KEEP, an added dimension whose name the
## imported world also has keeps the server's version (else the imported one is used).
static func import_into(inst: ServerInstance, analysis: Dictionary, mode: Mode, apply_settings: bool, on_status := Callable(), dimension_index := 0, keep_server_conflicts := true) -> Dictionary:
	var report := func(text: String) -> void:
		inst.log_system(text)
		if on_status.is_valid():
			on_status.call(text)
	if not analysis.get("ok", false):
		return {"ok": false, "error": analysis.get("error", "Nothing to import.")}
	if inst.is_busy() or inst.is_process_alive():
		return {"ok": false, "error": "Stop the server before importing a world."}
	if inst.is_temporary():
		return {"ok": false, "error": "Keep or discard the pending temporary copy first."}
	var dir := inst.config.directory
	var props := ServerProperties.load_file(inst.config.properties_path())
	var level := props.get_value("level-name", "world")
	if mode == Mode.DIMENSION:
		return await _add_dimension(inst, analysis, dir.path_join(level), report, dimension_index)
	if analysis.layout == Layout.DIMENSION:
		var custom := custom_dimension_type(dir, analysis.dimension_choices[0])
		if not custom.ok:
			return custom
	if mode == Mode.ADD:
		level = unique_level_name(dir, display_name(analysis))
	else:
		var existing := inst.backups.world_dirs(dir)
		if not existing.is_empty():
			report.call("Saving a safety backup of the current world before replacing it…")
			if await inst.backups.create_backup(false, dir, "pre-import") == "":
				return {"ok": false, "error": "The safety backup failed, so the current world was left untouched."}
	inst.mark_installing(true)
	# Added dimensions wait outside the world folder while it is replaced.
	var kept := []
	var holding := ""
	if mode == Mode.REPLACE_KEEP:
		var conflicts := dimension_conflicts(dir.path_join(level), analysis)
		kept = added_dimensions(dir.path_join(level)).filter(func(d: Dictionary) -> bool:
			return keep_server_conflicts or not conflicts.has(d.key))
		if not kept.is_empty():
			holding = dir.path_join(".manager").path_join("kept-dimensions-" + Fmt.file_stamp(int(Time.get_unix_time_from_system())))
			report.call("Keeping %s…" % ", ".join(kept.map(func(d: Dictionary) -> String: return d.key)))
			var held: Error = await FileOps.run_async(inst, func() -> Error: return hold_dimensions(kept, dir.path_join(level), holding))
			if held != OK:
				inst.mark_installing(false)
				return {"ok": false, "error": "Setting the added dimensions aside failed (%s); nothing was replaced. Anything already moved is in %s." % [error_string(held), holding]}
	if mode == Mode.REPLACE or mode == Mode.REPLACE_KEEP:
		# Permanently remove the old world folders (the safety backup above keeps a copy).
		for w in inst.backups.world_dirs(dir):
			var path := dir.path_join(w)
			await FileOps.run_async(inst, func() -> Error: return FileOps.remove_tree(path))
	report.call("Importing \"%s\" as world folder \"%s\"…" % [display_name(analysis), level])
	var version := inst.config.mc_version
	var err: Error = await FileOps.run_async(inst, func() -> Error: return place_world(analysis, dir, level, version))
	if err == OK and holding != "":
		report.call("Putting the kept dimensions into the new world…")
		var target := dir.path_join(level)
		err = await FileOps.run_async(inst, func() -> Error: return restore_dimensions(kept, holding, target))
		if err != OK:
			inst.mark_installing(false)
			return {"ok": false, "error": "The world was imported, but putting the kept dimensions back failed (%s). They are in %s." % [error_string(err), holding]}
	inst.mark_installing(false)
	if err != OK:
		return {"ok": false, "error": "Copying the world failed: %s%s" % [error_string(err), (". The kept dimensions are in %s." % holding) if holding != "" else ""]}

	props = ServerProperties.load_file(inst.config.properties_path())
	props.set_value("level-name", level)
	if apply_settings:
		if analysis.game_mode != "":
			props.set_value("gamemode", analysis.game_mode)
		if analysis.difficulty != "":
			props.set_value("difficulty", analysis.difficulty)
		props.set_value("hardcore", bool(analysis.hardcore))
	props.save_file(inst.config.properties_path())
	# Game rule values the manager knew belong to the old world.
	inst.config.known_gamerules.clear()
	inst.save_config()
	report.call("World \"%s\" imported%s. It will be prepared on the next start." % [display_name(analysis),
			(", keeping %s" % ", ".join(kept.map(func(d: Dictionary) -> String: return d.key))) if not kept.is_empty() else ""])
	return {"ok": true, "level_name": level, "kept": kept.map(func(d: Dictionary) -> String: return d.key)}


# --- Keeping added dimensions (Mode.REPLACE_KEEP) ---------------------------------------

## The dimensions added to the world in [param world_dir] (Minecraft 26+ layout): every
## dimensions/<namespace>/<name> besides the overworld, Nether and End, with the datapacks
## (folders or zips in datapacks/) that define it. [{key, path, packs: [pack paths]}].
static func added_dimensions(world_dir: String) -> Array:
	var out := []
	var root := world_dir.path_join("dimensions")
	if not DirAccess.dir_exists_absolute(root):
		return out
	var defined := pack_dimensions(world_dir.path_join("datapacks"))
	for ns in DirAccess.get_directories_at(root):
		for id in DirAccess.get_directories_at(root.path_join(ns)):
			var key := "%s:%s" % [ns, id]
			if ns == "minecraft" and VANILLA_DIMENSIONS.has(id):
				continue
			var packs := []
			for pack in defined:
				if (defined[pack] as Array).has(key):
					packs.append(pack)
			out.append({"key": key, "path": root.path_join(ns).path_join(id), "packs": packs})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.key < b.key)
	return out


## The dimensions each datapack in [param datapacks_dir] defines: {pack path: [keys]}
## (from data/<namespace>/dimension/<name>.json, in pack folders and zips).
static func pack_dimensions(datapacks_dir: String) -> Dictionary:
	var out := {}
	if not DirAccess.dir_exists_absolute(datapacks_dir):
		return out
	var re := RegEx.create_from_string("^(?:[^/]+/)?data/([^/]+)/dimension/(.+)\\.json$")
	for name in DirAccess.get_directories_at(datapacks_dir):
		var keys := []
		var data := datapacks_dir.path_join(name).path_join("data")
		for ns in DirAccess.get_directories_at(data) if DirAccess.dir_exists_absolute(data) else PackedStringArray():
			var defs := data.path_join(ns).path_join("dimension")
			for f in DirAccess.get_files_at(defs) if DirAccess.dir_exists_absolute(defs) else PackedStringArray():
				if f.ends_with(".json"):
					keys.append("%s:%s" % [ns, f.get_basename()])
		if not keys.is_empty():
			out[datapacks_dir.path_join(name)] = keys
	for name in DirAccess.get_files_at(datapacks_dir):
		if not name.to_lower().ends_with(".zip"):
			continue
		var zip := ZIPReader.new()
		if zip.open(datapacks_dir.path_join(name)) != OK:
			continue
		var keys := []
		for entry in zip.get_files():
			var m := re.search(entry)
			if m != null:
				keys.append("%s:%s" % [m.get_string(1), m.get_string(2)])
		zip.close()
		if not keys.is_empty():
			out[datapacks_dir.path_join(name)] = keys
	return out


## The dimensions an analysed world brings besides its overworld, Nether and End (folders
## under dimensions/ and ones its datapacks define), as keys.
static func incoming_dimensions(analysis: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var world_dir: String = analysis.get("world_dir", "")
	if world_dir == "" or analysis.get("layout") == Layout.DIMENSION:
		return out
	for d in added_dimensions(world_dir):
		out.append(d.key)
	for keys in pack_dimensions(world_dir.path_join("datapacks")).values():
		for key in keys:
			if not out.has(key) and not (str(key).begins_with("minecraft:") and VANILLA_DIMENSIONS.has(str(key).get_slice(":", 1))):
				out.append(key)
	return out


## Added dimensions of [param world_dir] that the analysed world has too (by key, or by the
## name of a datapack defining them).
static func dimension_conflicts(world_dir: String, analysis: Dictionary) -> PackedStringArray:
	var incoming := incoming_dimensions(analysis)
	var incoming_packs := []
	var src: String = analysis.get("world_dir", "")
	if src != "" and analysis.get("layout") != Layout.DIMENSION and DirAccess.dir_exists_absolute(src.path_join("datapacks")):
		incoming_packs = Array(DirAccess.get_directories_at(src.path_join("datapacks"))) + Array(DirAccess.get_files_at(src.path_join("datapacks")))
	var out := PackedStringArray()
	for d in added_dimensions(world_dir):
		if incoming.has(d.key) or d.packs.any(func(p: String) -> bool: return incoming_packs.has(p.get_file())):
			out.append(d.key)
	return out


## Moves [param kept] (see added_dimensions) from [param world_dir] into [param holding].
## Thread-safe.
static func hold_dimensions(kept: Array, world_dir: String, holding: String) -> Error:
	for d in kept:
		var rel: String = (d.path as String).trim_prefix(world_dir + "/")
		var err := _move(d.path, holding.path_join(rel))
		if err != OK:
			return err
		for pack in d.packs:
			if FileAccess.file_exists(pack) or DirAccess.dir_exists_absolute(pack):
				err = _move(pack, holding.path_join("datapacks").path_join((pack as String).get_file()))
				if err != OK:
					return err
	return OK


## Moves the held dimensions and their datapacks into the new world [param world_dir],
## replacing what it has under the same names. Removes [param holding]. Thread-safe.
static func restore_dimensions(kept: Array, holding: String, world_dir: String) -> Error:
	for d in kept:
		var rel: String = d.path.substr(d.path.find("/dimensions/") + 1)
		var src := holding.path_join(rel)
		var dst := world_dir.path_join(rel)
		if DirAccess.dir_exists_absolute(dst):
			FileOps.remove_tree(dst)
		var err := _move(src, dst)
		if err != OK:
			return err
		for pack in d.packs:
			var held := holding.path_join("datapacks").path_join((pack as String).get_file())
			if not (FileAccess.file_exists(held) or DirAccess.dir_exists_absolute(held)):
				continue  # Shared with another kept dimension and already moved.
			var target := world_dir.path_join("datapacks").path_join((pack as String).get_file())
			FileOps.remove_path(target)
			err = _move(held, target)
			if err != OK:
				return err
	FileOps.remove_tree(holding)
	return OK


static func _move(src: String, dst: String) -> Error:
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var err := DirAccess.rename_absolute(src, dst)
	if err == OK:
		return OK
	# Another file system: copy, then remove.
	err = FileOps.copy_tree(src, dst) if DirAccess.dir_exists_absolute(src) else DirAccess.copy_absolute(src, dst)
	if err == OK:
		FileOps.remove_path(src)
	return err


## Adds dimension [param index] of [member dimension_choices] to the world in [param world_dir]
## as minecraft:<name>.
static func _add_dimension(inst: ServerInstance, analysis: Dictionary, world_dir: String, report: Callable, index: int) -> Dictionary:
	var choices: Array = analysis.get("dimension_choices", [])
	if choices.is_empty():
		return {"ok": false, "error": "Only dimensions of Minecraft 26+ worlds can be added to a world."}
	if index < 0 or index >= choices.size():
		return {"ok": false, "error": "Choose which dimension to add."}
	var choice: Dictionary = choices[index]
	var id := unique_dimension_id(world_dir, choice.name)
	var key := "minecraft:" + id
	report.call("Adding \"%s\" to world \"%s\" as dimension %s…" % [choice.label, world_dir.get_file(), key])
	var custom := custom_dimension_type(inst.config.directory, choice)
	if not custom.ok:
		return custom
	var type_def: Dictionary = custom.definition
	var move: bool = analysis.get("staging", "") != ""
	var spawn: Array = choice.spawn
	var vertical := [int(choice.get("min_y", 0)), int(choice.get("height", 0))]
	var dest := world_dir.path_join("dimensions/minecraft").path_join(id)
	inst.mark_installing(true)
	var err: Error = await FileOps.run_async(inst, func() -> Error: return place_dimension(choice, world_dir, id, move, type_def))
	if err == OK and not is_usable_spawn(spawn, vertical):
		report.call("Its saved spawn point is unusable; looking for its terrain…")
		var landing: Array = await FileOps.run_async(inst, func() -> Array: return find_landing(dest, choice.type))
		if not landing.is_empty():
			spawn = landing
	inst.mark_installing(false)
	if err != OK:
		return {"ok": false, "error": "Copying the dimension failed: %s" % error_string(err)}
	var command := teleport_command(key, spawn, choice.type, vertical)
	report.call("Dimension %s added; it loads on the next start. In game (as an operator): %s" % [key, command])
	return {"ok": true, "level_name": world_dir.get_file(), "dimension": key, "command": command}


## The command that takes the player running it into [param key]: to [param spawn] when it is
## inside the dimension's [min_y, height] [param vertical] (vanilla when empty), otherwise onto
## the highest block there (or at 0 0) with spreadplayers, below the roof for nether-like
## dimensions ([param type]).
static func teleport_command(key: String, spawn: Array, type := "", vertical := []) -> String:
	if is_usable_spawn(spawn, vertical):
		return "/execute in %s run tp @s %d %d %d" % [key, int(spawn[0]), int(spawn[1]), int(spawn[2])]
	var x := int(spawn[0]) if spawn.size() == 3 else 0
	var z := int(spawn[2]) if spawn.size() == 3 else 0
	var under := " under 120" if type == "minecraft:the_nether" else ""
	return "/execute in %s run spreadplayers %d %d 0 1%s false @s" % [key, x, z, under]


## True when [param spawn] lies inside the dimension's [min_y, height] [param vertical]
## (vanilla overworld when empty or unknown).
static func is_usable_spawn(spawn: Array, vertical := []) -> bool:
	var low := MIN_BUILD_Y
	var high := MAX_BUILD_Y
	if vertical.size() == 2 and int(vertical[1]) > 0:
		low = int(vertical[0])
		high = low + int(vertical[1]) - 1
	return spawn.size() == 3 and int(spawn[1]) >= low and int(spawn[1]) <= high


## A place to stand in the dimension at [param dimension_dir]: the highest column of the
## saved chunk with blocks nearest to 0 0 (void worlds often hold builds far from it), from
## the chunk's height map. Returns [x, y, z], or [] when nothing was found. Thread-safe.
static func find_landing(dimension_dir: String, type := "") -> Array:
	var min_y := 0 if type in ["minecraft:the_nether", "minecraft:the_end"] else MIN_BUILD_Y
	var regions := []
	for f in DirAccess.get_files_at(dimension_dir.path_join("region")):
		var parts := f.split(".")
		if parts.size() == 4 and parts[0] == "r" and parts[3] == "mca":
			regions.append([parts[1].to_int(), parts[2].to_int(), f])
	regions.sort_custom(func(a: Array, b: Array) -> bool: return absi(a[0]) + absi(a[1]) < absi(b[0]) + absi(b[1]))
	var budget := LANDING_SCAN_CHUNKS
	for r in regions:
		var file := FileAccess.open(dimension_dir.path_join("region").path_join(r[2]), FileAccess.READ)
		if file == null:
			continue
		var header := file.get_buffer(4096)
		if header.size() < 4096:
			continue
		# Chunks nearest to the origin first.
		var slots := range(1024)
		slots.sort_custom(func(a: int, b: int) -> bool:
			return absi(r[0] * 32 + a % 32) + absi(r[1] * 32 + a / 32) < absi(r[0] * 32 + b % 32) + absi(r[1] * 32 + b / 32))
		for i: int in slots:
			var sector := (header[i * 4] << 16) | (header[i * 4 + 1] << 8) | header[i * 4 + 2]
			if sector < 2:
				continue
			budget -= 1
			if budget < 0:
				return []
			var spot := _chunk_landing(_read_chunk(file, sector), min_y)
			if not spot.is_empty():
				var cx: int = r[0] * 32 + i % 32
				var cz: int = r[1] * 32 + i / 32
				return [cx * 16 + spot[0], spot[1], cz * 16 + spot[2]]
	return []


## Decodes the chunk stored at [param sector] of a region file ({} when unreadable).
static func _read_chunk(file: FileAccess, sector: int) -> Dictionary:
	file.seek(sector * 4096)
	var head := file.get_buffer(5)
	if head.size() < 5:
		return {}
	var length := (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3]
	if length <= 1 or length > 1 << 24:
		return {}
	var raw := file.get_buffer(length - 1)
	match head[4]:
		1:
			return Nbt.parse(raw)  # gzip, detected by Nbt.
		2:
			return Nbt.parse(raw.decompress_dynamic(1 << 24, FileAccess.COMPRESSION_DEFLATE))
		3:
			return Nbt.parse(raw)
	return {}  # LZ4 or an external .mcc file.


## [local x, y, local z] above the chunk's highest column, or [] when it holds only air.
## [param min_y] is used when the chunk doesn't record its own bottom (yPos).
static func _chunk_landing(chunk: Dictionary, min_y: int) -> Array:
	if chunk.has("yPos"):
		min_y = int(chunk.yPos) * 16
	var solid := false
	for section in chunk.get("sections", []):
		for entry in Nbt.dig(section, ["block_states", "palette"], []):
			if entry is Dictionary and not AIR_BLOCKS.has(str(entry.get("Name", ""))):
				solid = true
				break
		if solid:
			break
	if not solid:
		return []
	# MOTION_BLOCKING: 256 heights relative to the bottom, packed into longs without
	# spanning two; the bits per height grow with the world height (9 for vanilla).
	var heights: Array = Nbt.dig(chunk, ["Heightmaps", "MOTION_BLOCKING"], [])
	var bits := 1
	while bits < 32 and ceili(256.0 / floori(64.0 / bits)) != heights.size():
		bits += 1
	if heights.is_empty() or bits >= 32:
		return []
	var per_long := 64 / bits
	var mask := (1 << bits) - 1
	var best := -1
	var best_index := 0
	for i in 256:
		var h := (int(heights[i / per_long]) >> ((i % per_long) * bits)) & mask
		if h > best:
			best = h
			best_index = i
	if best <= 0:
		return []
	return [best_index % 16, min_y + best, best_index / 16]


## Human-friendly name: the saved LevelName, unless it is a generic one like "world"
## (worlds exported from servers), then the world's folder name.
static func display_name(analysis: Dictionary) -> String:
	var level := str(analysis.get("name", "")).strip_edges()
	var folder := str(analysis.get("world_dir", "")).get_file()
	if level != "" and level.to_lower() not in ["world", "new world"]:
		return level
	if folder != "" and not folder.begins_with("import-"):
		return folder
	return level if level != "" else "world"


## Deletes the staging folder created for a zip. Safe to call more than once.
static func cleanup(analysis: Dictionary) -> void:
	var staging: String = analysis.get("staging", "")
	if staging != "" and DirAccess.dir_exists_absolute(staging):
		FileOps.remove_tree(staging)
	analysis["staging"] = ""


# --- Steps (thread-safe, also used by tests) -------------------------------------

static func uses_dimensions_layout(mc_version: String) -> bool:
	return mc_version != "" and Fmt.compare_versions(mc_version, DIMENSIONS_SINCE) >= 0


## Copies (or moves, from a staging folder) the analysed world into [param server_dir]
## as [param level], in the layout [param target_version] expects. Thread-safe.
static func place_world(analysis: Dictionary, server_dir: String, level: String, target_version: String) -> Error:
	var move: bool = analysis.get("staging", "") != ""
	var world_dir: String = analysis.world_dir
	var target := server_dir.path_join(level)
	if analysis.layout == Layout.DIMENSION:
		return _place_dimension(analysis, target, move, server_dir)
	var err := _transfer(world_dir, target, move)
	if err != OK:
		return err
	if analysis.layout != Layout.DIMENSIONS:
		var inside := uses_dimensions_layout(target_version)
		var nether_target := target.path_join("DIM-1") if inside else server_dir.path_join(level + "_nether").path_join("DIM-1")
		var end_target := target.path_join("DIM1") if inside else server_dir.path_join(level + "_the_end").path_join("DIM1")
		for pair in [[analysis.nether_src, nether_target, "DIM-1"], [analysis.end_src, end_target, "DIM1"]]:
			var src: String = pair[0]
			if src == "":
				continue
			var dst: String = pair[1]
			# Singleplayer saves: the dimension came along inside the world folder.
			var inner := target.path_join(pair[2])
			if inner == dst and src.get_base_dir() == world_dir:
				continue  # Already where it belongs.
			if src.get_base_dir() == world_dir and DirAccess.dir_exists_absolute(inner):
				src = inner
				DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
				err = DirAccess.rename_absolute(src, dst)
			else:
				DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
				err = _transfer(src, dst, move)
			if err != OK:
				return err
	for d in [target, server_dir.path_join(level + "_nether"), server_dir.path_join(level + "_the_end")]:
		for f in DROP_FILES:
			if FileAccess.file_exists(d.path_join(f)):
				DirAccess.remove_absolute(d.path_join(f))
	return OK


## Extracts [param zip_path] into [param dest]. Returns "" or an error message. Thread-safe.
static func extract_zip(zip_path: String, dest: String) -> String:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return "The file is not a readable .zip archive."
	DirAccess.make_dir_recursive_absolute(dest)
	for name in reader.get_files():
		var rel := name.replace("\\", "/")
		if rel.begins_with("/") or rel.contains("../") or rel == ".." or rel.contains(":"):
			continue  # Never write outside the staging folder.
		if rel.begins_with("__MACOSX/"):
			continue
		var target := dest.path_join(rel)
		if rel.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target)
			continue
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f == null:
			reader.close()
			return "Could not extract %s." % rel
		f.store_buffer(reader.read_file(name))
		f.close()
	reader.close()
	return ""


## Folders under [param root] (up to SEARCH_DEPTH deep) that contain a level.dat, shallowest first.
static func find_level_dirs(root: String) -> PackedStringArray:
	var out := PackedStringArray()
	var queue: Array = [[root, 0]]
	while not queue.is_empty():
		var item: Array = queue.pop_front()
		var dir: String = item[0]
		if FileAccess.file_exists(dir.path_join("level.dat")):
			out.append(dir)
		if item[1] >= SEARCH_DEPTH:
			continue
		for sub in DirAccess.get_directories_at(dir):
			if IGNORED_DIRS.has(sub) or WORLD_DATA_DIRS.has(sub) or sub == "dimensions":
				continue
			queue.append([dir.path_join(sub), item[1] + 1])
	return out


## True for a Minecraft 26+ dimension folder: terrain plus the world_gen_settings.dat that
## 26+ keeps per dimension. A world's own folder never has both at its top (its terrain lives
## in dimensions/), so a folder that also holds level.dat and dimensions/ is a dimension
## with a leftover older save inside (see DIMENSION_LEFTOVERS).
static func is_dimension_dir(dir: String) -> bool:
	return DirAccess.dir_exists_absolute(dir.path_join("region")) and FileAccess.file_exists(dir.path_join("data/minecraft/world_gen_settings.dat"))


## Dimension folders under [param root] (up to SEARCH_DEPTH deep), shallowest first.
static func find_dimension_dirs(root: String) -> PackedStringArray:
	var out := PackedStringArray()
	var queue: Array = [[root, 0]]
	while not queue.is_empty():
		var item: Array = queue.pop_front()
		var dir: String = item[0]
		if is_dimension_dir(dir):
			out.append(dir)
			continue
		if item[1] >= SEARCH_DEPTH:
			continue
		for sub in DirAccess.get_directories_at(dir):
			if not IGNORED_DIRS.has(sub) and not WORLD_DATA_DIRS.has(sub):
				queue.append([dir.path_join(sub), item[1] + 1])
	return out


## The overworld when a whole dimensions folder was given, otherwise the shallowest one.
static func pick_dimension(dims: PackedStringArray) -> String:
	for d in dims:
		if d.get_file() == "overworld":
			return d
	for d in dims:
		if d.get_file() not in ["the_nether", "the_end"]:
			return d
	return dims[0]


## Chooses the main world among candidate folders: a world with matching _nether/_the_end
## siblings wins, otherwise the shallowest one that is not itself a nether/end folder.
static func pick_world(candidates: PackedStringArray) -> String:
	for c in candidates:
		if c.ends_with("_nether") or c.ends_with("_the_end"):
			continue
		if candidates.has(c + "_nether") or candidates.has(c + "_the_end"):
			return c
	for c in candidates:
		if not c.ends_with("_nether") and not c.ends_with("_the_end"):
			return c
	return candidates[0]


## A folder name for a new world: readable, filesystem-safe and unused in [param server_dir].
static func unique_level_name(server_dir: String, display_name: String) -> String:
	var base := ""
	for c in display_name.strip_edges():
		base += c if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_" or c == "-" else "_"
	while base.contains("__"):
		base = base.replace("__", "_")
	base = base.trim_prefix("_").trim_suffix("_")
	if base == "" or base.to_lower() in ["plugins", "config", "logs", "cache", "libraries", "versions", "crash-reports"]:
		base = "imported_world"
	var name := base
	var n := 2
	while DirAccess.dir_exists_absolute(server_dir.path_join(name)) or DirAccess.dir_exists_absolute(server_dir.path_join(name + "_nether")) \
			or DirAccess.dir_exists_absolute(server_dir.path_join(name + "_the_end")):
		name = "%s_%d" % [base, n]
		n += 1
	return name


static func dir_size(path: String) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var total := 0
	for f in dir.get_files():
		var file := FileAccess.open(path.path_join(f), FileAccess.READ)
		if file != null:
			total += file.get_length()
	for d in dir.get_directories():
		if not dir.is_link(d):
			total += dir_size(path.path_join(d))
	return total


static func _transfer(src: String, dst: String, move: bool) -> Error:
	if move and DirAccess.rename_absolute(src, dst) == OK:
		return OK
	return FileOps.copy_tree(src, dst)


## Layout of the world in [param world_dir]: {layout, nether_src, end_src, dimensions}.
static func detect_layout(world_dir: String) -> Dictionary:
	var result := {"layout": Layout.SINGLEPLAYER, "nether_src": "", "end_src": "", "dimensions": PackedStringArray()}
	_detect_layout(world_dir, result)
	return result


static func _detect_layout(world_dir: String, result: Dictionary) -> void:
	var dims := PackedStringArray()
	if DirAccess.dir_exists_absolute(world_dir.path_join("dimensions")):
		result.layout = Layout.DIMENSIONS
		var base := world_dir.path_join("dimensions/minecraft")
		for pair in [["overworld", "Overworld"], ["the_nether", "Nether"], ["the_end", "End"]]:
			if DirAccess.dir_exists_absolute(base.path_join(pair[0]).path_join("region")):
				dims.append(pair[1])
		# Extra dimensions (added ones, datapack or plugin worlds) under their own names.
		for d in DirAccess.get_directories_at(base):
			if not VANILLA_DIMENSIONS.has(d) and DirAccess.dir_exists_absolute(base.path_join(d).path_join("region")):
				dims.append(d)
		result.dimensions = dims
		return
	if DirAccess.dir_exists_absolute(world_dir.path_join("region")):
		dims.append("Overworld")
	var name := world_dir.get_file()
	var parent := world_dir.get_base_dir()
	var inner_nether := world_dir.path_join("DIM-1")
	var outer_nether := parent.path_join(name + "_nether").path_join("DIM-1")
	var inner_end := world_dir.path_join("DIM1")
	var outer_end := parent.path_join(name + "_the_end").path_join("DIM1")
	if DirAccess.dir_exists_absolute(inner_nether):
		result.nether_src = inner_nether
	elif DirAccess.dir_exists_absolute(outer_nether):
		result.nether_src = outer_nether
	if DirAccess.dir_exists_absolute(inner_end):
		result.end_src = inner_end
	elif DirAccess.dir_exists_absolute(outer_end):
		result.end_src = outer_end
	var split: bool = result.nether_src.begins_with(parent.path_join(name + "_")) or result.end_src.begins_with(parent.path_join(name + "_"))
	result.layout = Layout.SPLIT if split else Layout.SINGLEPLAYER
	if result.nether_src != "":
		dims.append("Nether")
	if result.end_src != "":
		dims.append("End")
	result.dimensions = dims


## A lone dimension has no level.dat of its own (Paper 26 keeps the per-world settings in
## data/paper/level_overrides.dat), so settings come from there when present.
static func _read_dimension(dir: String, result: Dictionary) -> void:
	result.layout = Layout.DIMENSION
	result.dimensions = PackedStringArray(["Overworld"])
	result.name = dir.get_file()
	result.data_version = int(Nbt.read_file(dir.path_join("data/minecraft/world_gen_settings.dat")).get("DataVersion", 0))
	var own := _dimension_choice(dir, dir.get_file(), dir.get_file(), dir)
	result.generator = own.generator
	result.dimension_type = own.type
	var vertical := [int(own.min_y), int(own.height)]
	var overrides: Dictionary = Nbt.read_file(dir.path_join("data/paper/level_overrides.dat")).get("data", {})
	if not overrides.is_empty():
		var mode := int(overrides.get("game_type", -1))
		result.game_mode = GAME_MODES[mode] if mode >= 0 and mode < GAME_MODES.size() else ""
		var settings: Dictionary = overrides.get("difficulty_settings", {})
		var diff := str(settings.get("difficulty", ""))
		result.difficulty = diff if DIFFICULTIES.has(diff) else ""
		result.hardcore = int(settings.get("hardcore", 0)) != 0
		var pos: Variant = Nbt.dig(overrides, ["spawn", "pos"])
		if pos is Array and (pos as Array).size() == 3:
			result.spawn = pos
	result.warnings.append("This is a single dimension. Add it to the current world, or use it as a world's Overworld (with a new Nether and End).")
	if _is_unusual_height(own):
		result.warnings.append("Its world is %s than normal (Y %d to %d); the import keeps that height." % [_taller_or_shorter(own), own.min_y, own.min_y + own.height - 1])
	if not result.spawn.is_empty() and not is_usable_spawn(result.spawn, vertical):
		result.warnings.append("Its saved spawn point (Y %d) is outside the world. Added as a dimension, the teleport command uses its terrain instead; as a world's Overworld, set a spawn with /setworldspawn after the first start." % int(result.spawn[1]))
	if FileAccess.file_exists(dir.path_join("level.dat")) or DirAccess.dir_exists_absolute(dir.path_join("dimensions")):
		result.warnings.append("It also holds an older save of the world it was copied from (level.dat, dimensions folder); that is left out and only the newer dimension data is imported.")
	if result.version == "":
		result.warnings.append("Its Minecraft version isn't recorded; the server must be the same version or newer.")


## The 26+ dimensions in [param world_dir] that can be added to a world: the folder itself
## when it is a dimension, then the dimensions/ inside it (a world's own, or the older save
## a dimension folder may carry). Only dimensions with terrain are listed.
static func _list_dimension_choices(world_dir: String, result: Dictionary) -> Array:
	var choices := []
	var lone: bool = result.layout == Layout.DIMENSION
	if lone:
		var own := _dimension_choice(world_dir, display_name(result), display_name(result), world_dir)
		own.spawn = result.spawn
		choices.append(own)
	elif result.layout != Layout.DIMENSIONS:
		return choices
	var base := display_name(result)
	var level: Dictionary = Nbt.read_file(world_dir.path_join("level.dat")).get("Data", {})
	var root := world_dir.path_join("dimensions")
	for ns in DirAccess.get_directories_at(root):
		var names := Array(DirAccess.get_directories_at(root.path_join(ns)))
		# Overworld, Nether, End first, then the rest by name.
		names.sort_custom(func(x: String, y: String) -> bool:
			var ix := VANILLA_DIMENSIONS.find(x) if VANILLA_DIMENSIONS.has(x) else 99
			var iy := VANILLA_DIMENSIONS.find(y) if VANILLA_DIMENSIONS.has(y) else 99
			return ix < iy if ix != iy else x.naturalnocasecmp_to(y) < 0)
		for d: String in names:
			var dir := root.path_join(ns).path_join(d)
			if not DirAccess.dir_exists_absolute(dir.path_join("region")):
				continue
			var label: String = DIMENSION_LABELS.get(d, d) if ns == "minecraft" else "%s:%s" % [ns, d]
			var name: String = d
			if ns == "minecraft" and VANILLA_DIMENSIONS.has(d):
				name = base + {"overworld": "", "the_nether": "_nether", "the_end": "_end"}[d]
			var choice := _dimension_choice(dir, label + (" (older save)" if lone else ""), name, world_dir)
			# A world keeps its spawn in level.dat, with the dimension it is in.
			if choice.spawn.is_empty() and str(Nbt.dig(level, ["spawn", "dimension"], "minecraft:overworld")) == "%s:%s" % [ns, d]:
				var pos: Variant = Nbt.dig(level, ["spawn", "pos"])
				if pos is Array and (pos as Array).size() == 3:
					choice.spawn = pos
			choices.append(choice)
	if not lone:
		for c in choices:
			if _is_unusual_height(c):
				result.warnings.append("This world is %s than normal (Y %d to %d). As a whole world it needs the datapack or plugin that changed its height on the server too; added as a dimension, it keeps that height." % [_taller_or_shorter(c), c.min_y, c.min_y + c.height - 1])
				break
	return choices


static func _is_unusual_height(choice: Dictionary) -> bool:
	var vanilla: Array = VANILLA_RANGES.get(str(choice.get("type", "")), VANILLA_RANGES["minecraft:overworld"])
	return int(choice.get("height", 0)) > 0 and [int(choice.min_y), int(choice.height)] != vanilla


static func _taller_or_shorter(choice: Dictionary) -> String:
	var vanilla: Array = VANILLA_RANGES.get(str(choice.get("type", "")), VANILLA_RANGES["minecraft:overworld"])
	return "taller" if int(choice.height) > int(vanilla[1]) else "shorter"


## One addable dimension: {label, name (for its new id), path, type, generator, spawn}.
## The generator comes from the dimension's world_gen_settings.dat (or [param world_dir]'s,
## where older saves keep it): its own entry for vanilla dimensions, the overworld entry for
## Paper's extra worlds (which are overworld-like); vanilla defaults otherwise.
static func _dimension_choice(dir: String, label: String, name: String, world_dir: String) -> Dictionary:
	var folder := dir.get_file()
	var vanilla := VANILLA_DIMENSIONS.has(folder)
	var choice := {"label": label, "name": name, "path": dir, "spawn": [],
			"type": "minecraft:" + folder if vanilla else "minecraft:overworld",
			"generator": DEFAULT_GENERATORS.get(folder if vanilla else "overworld")}
	for file in [dir.path_join("data/minecraft/world_gen_settings.dat"), world_dir.path_join("data/minecraft/world_gen_settings.dat")]:
		var stems: Variant = Nbt.dig(Nbt.read_file(file, true), ["data", "dimensions"])
		if not stems is Dictionary:
			continue
		var stem: Variant = stems.get("minecraft:" + folder) if vanilla else stems.get("minecraft:overworld")
		if stem is Dictionary and (stem as Dictionary).get("generator") is Dictionary:
			choice.generator = stem.generator
			choice.type = str((stem as Dictionary).get("type", choice.type))
			break
	var pos: Variant = Nbt.dig(Nbt.read_file(dir.path_join("data/paper/level_overrides.dat")), ["data", "spawn", "pos"])
	if pos is Array and (pos as Array).size() == 3:
		choice.spawn = pos
	var vertical := dimension_range(dir)
	choice.min_y = vertical[0]
	choice.height = vertical[1]
	return choice


## [min_y, height] the dimension in [param dir] was saved with ([0, 0] when unknown): the
## widest range among a sample of its chunks, since a dimension whose height changed holds
## chunks of both (a taller type never loses blocks). Chunks keep their lowest section in
## yPos and one section per 16 blocks of height; sections without block_states only hold light.
static func dimension_range(dir: String) -> Array:
	var low := 1 << 30
	var top := -(1 << 30)
	var sampled := 0
	for fname in DirAccess.get_files_at(dir.path_join("region")):
		var file := FileAccess.open(dir.path_join("region").path_join(fname), FileAccess.READ)
		if file == null:
			continue
		var header := file.get_buffer(4096)
		if header.size() < 4096:
			continue
		var taken := 0
		for i in 1024:
			var sector := (header[i * 4] << 16) | (header[i * 4 + 1] << 8) | header[i * 4 + 2]
			if sector < 2:
				continue
			var chunk := _read_chunk(file, sector)
			var blocks := 0
			for section in chunk.get("sections", []):
				if section is Dictionary and (section as Dictionary).has("block_states"):
					blocks += 1
			if chunk.has("yPos") and blocks > 0:
				low = mini(low, int(chunk.yPos) * 16)
				top = maxi(top, int(chunk.yPos) * 16 + blocks * 16)
				taken += 1
				sampled += 1
			if taken >= RANGE_SAMPLES_PER_REGION or sampled >= RANGE_SAMPLES:
				break
		if sampled >= RANGE_SAMPLES:
			break
	return [low, top - low] if sampled > 0 else [0, 0]


## The dimension type [param choice] needs: {ok, definition, error}. The definition is {}
## when a vanilla type fits; otherwise the vanilla one (from the server's own unpacked
## jar, so it matches its version) with the saved height range.
static func custom_dimension_type(server_dir: String, choice: Dictionary) -> Dictionary:
	var height := int(choice.get("height", 0))
	var type := str(choice.get("type", "minecraft:overworld"))
	if not _is_unusual_height(choice):
		return {"ok": true, "definition": {}}
	var base := type.get_slice(":", 1) if type.begins_with("minecraft:") else "overworld"
	var template := _vanilla_dimension_type(server_dir, base)
	if template.is_empty() and base != "overworld":
		template = _vanilla_dimension_type(server_dir, "overworld")
	if template.is_empty():
		return {"ok": false, "definition": {}, "error": "This dimension is %s than a normal world (Y %d to %d). Start the server once so its files are unpacked, then import it again." % [_taller_or_shorter(choice), int(choice.min_y), int(choice.min_y) + height - 1]}
	template.min_y = int(choice.min_y)
	template.height = height
	template.logical_height = height
	return {"ok": true, "definition": template}


## data/minecraft/dimension_type/<name>.json from the server's unpacked Minecraft jar
## (versions/<version>/*.jar, written on first start), or {}.
static func _vanilla_dimension_type(server_dir: String, name: String) -> Dictionary:
	var versions := server_dir.path_join("versions")
	for v in DirAccess.get_directories_at(versions):
		for jar in DirAccess.get_files_at(versions.path_join(v)):
			if not jar.ends_with(".jar"):
				continue
			var reader := ZIPReader.new()
			if reader.open(versions.path_join(v).path_join(jar)) != OK:
				continue
			var path := "data/minecraft/dimension_type/%s.json" % name
			var parsed: Variant = JSON.parse_string(reader.read_file(path).get_string_from_utf8()) if reader.file_exists(path) else null
			reader.close()
			if parsed is Dictionary:
				return _integral(parsed)
	return {}


## Godot parses every JSON number as a float; whole ones go back to ints so integer fields
## are written as Minecraft expects (float fields accept ints).
static func _integral(value: Variant) -> Variant:
	if value is Dictionary:
		var out := {}
		for k in value:
			out[k] = _integral(value[k])
		return out
	if value is Array:
		return (value as Array).map(_integral)
	if value is float and value == roundf(value) and absf(value) < 1e15:
		return int(value)
	return value


## Places a lone dimension as the overworld of the world folder [param target].
## Minecraft writes a fresh level.dat on first start.
## [param server_dir] provides the dimension type template when the dimension's height differs.
static func _place_dimension(analysis: Dictionary, target: String, move: bool, server_dir: String) -> Error:
	var own: Dictionary = analysis.dimension_choices[0] if not analysis.get("dimension_choices", []).is_empty() else {}
	var custom := custom_dimension_type(server_dir, own) if not own.is_empty() else {"ok": true, "definition": {}}
	if not custom.ok:
		return ERR_FILE_NOT_FOUND
	var overworld := target.path_join("dimensions/minecraft/overworld")
	DirAccess.make_dir_recursive_absolute(overworld.get_base_dir())
	var err := _transfer(analysis.world_dir, overworld, move)
	if err != OK:
		return err
	_drop_leftovers(overworld)
	_drop_stale_files([target, overworld])
	# Without it, chunks beyond the imported ones would follow server.properties' level-type
	# (and a taller world would lose everything outside the normal height).
	if not (analysis.generator as Dictionary).is_empty() or not (custom.definition as Dictionary).is_empty():
		return write_dimension_pack(target, "overworld", analysis.dimension_type, analysis.generator, custom.definition)
	return OK


## Copies (or moves, out of a staging folder) the dimension [param choice] (an entry of
## dimension_choices) into the existing world [param world_dir] as minecraft:[param id],
## with the datapack that defines it. Thread-safe.
## [param type_def] is a dimension type for it (see [method custom_dimension_type]), or {}.
static func place_dimension(choice: Dictionary, world_dir: String, id: String, move := false, type_def := {}) -> Error:
	var dest := world_dir.path_join("dimensions/minecraft").path_join(id)
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var err := _transfer(choice.path, dest, move)
	if err != OK:
		return err
	_drop_leftovers(dest)
	_drop_stale_files([dest])
	return write_dimension_pack(world_dir, id, choice.type, choice.generator, type_def)


## Writes datapacks/dimension-<id>/ into [param world_dir], defining minecraft:<id> with
## dimension [param type] and [param generator] (both in datapack JSON form). A non-empty
## [param type_def] is written as server_manager:<id> and used as the type instead.
static func write_dimension_pack(world_dir: String, id: String, type: String, generator: Dictionary, type_def := {}) -> Error:
	var pack := world_dir.path_join("datapacks").path_join("dimension-" + id)
	var defs := pack.path_join("data/minecraft/dimension")
	DirAccess.make_dir_recursive_absolute(defs)
	var meta := {"pack": {"description": "Dimension %s (added by Server Manager)" % id,
			"min_format": PACK_MIN_FORMAT, "max_format": PACK_MAX_FORMAT}}
	if generator.is_empty():
		generator = DEFAULT_GENERATORS.overworld
	if type == "":
		type = "minecraft:overworld"
	var files := [[pack.path_join("pack.mcmeta"), meta]]
	if not type_def.is_empty():
		var types := pack.path_join("data").path_join(TYPE_NAMESPACE).path_join("dimension_type")
		DirAccess.make_dir_recursive_absolute(types)
		files.append([types.path_join(id + ".json"), type_def])
		type = "%s:%s" % [TYPE_NAMESPACE, id]
	files.append([defs.path_join(id + ".json"), {"type": type, "generator": generator}])
	for pair in files:
		var f := FileAccess.open(pair[0], FileAccess.WRITE)
		if f == null:
			return FileAccess.get_open_error()
		f.store_string(JSON.stringify(pair[1], "  "))
	return OK


static func _drop_leftovers(dimension_dir: String) -> void:
	for name in DIMENSION_LEFTOVERS:
		var path := dimension_dir.path_join(name)
		if DirAccess.dir_exists_absolute(path):
			FileOps.remove_tree(path)
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


static func _drop_stale_files(dirs: Array) -> void:
	for f in Array(DROP_FILES) + [PAPER_UUID_FILE]:
		for d in dirs:
			if FileAccess.file_exists(str(d).path_join(f)):
				DirAccess.remove_absolute(str(d).path_join(f))


## A free dimension name in [param world_dir] derived from [param display_name]
## (lowercase letters, digits and _ . - as Minecraft ids allow).
static func unique_dimension_id(world_dir: String, display_name: String) -> String:
	var base := ""
	for c in display_name.strip_edges().to_lower():
		base += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c in ["_", ".", "-"] else "_"
	while base.contains("__"):
		base = base.replace("__", "_")
	base = base.trim_prefix("_").trim_suffix("_")
	if base == "" or VANILLA_DIMENSIONS.has(base):
		base = "imported_" + base if base != "" else "imported"
	var taken := func(name: String) -> bool:
		return DirAccess.dir_exists_absolute(world_dir.path_join("dimensions/minecraft").path_join(name)) \
				or DirAccess.dir_exists_absolute(world_dir.path_join("datapacks/dimension-" + name))
	var id := base
	var n := 2
	while taken.call(id):
		id = "%s_%d" % [base, n]
		n += 1
	return id


static func _read_level(path: String, result: Dictionary) -> void:
	var root := Nbt.read_file(path)
	var data: Dictionary = root.get("Data", {})
	if data.is_empty():
		result.warnings.append("level.dat could not be read; the world may be damaged.")
		return
	result.name = str(data.get("LevelName", ""))
	result.version = str(Nbt.dig(data, ["Version", "Name"], ""))
	result.data_version = int(data.get("DataVersion", 0))
	var mode := int(data.get("GameType", -1))
	result.game_mode = GAME_MODES[mode] if mode >= 0 and mode < GAME_MODES.size() else ""
	var settings: Variant = data.get("difficulty_settings")
	if settings is Dictionary:
		result.difficulty = str((settings as Dictionary).get("difficulty", ""))
		result.hardcore = int((settings as Dictionary).get("hardcore", 0)) != 0
	else:
		var diff := int(data.get("Difficulty", -1))
		result.difficulty = DIFFICULTIES[diff] if diff >= 0 and diff < DIFFICULTIES.size() else ""
		result.hardcore = int(data.get("hardcore", 0)) != 0
	if not DIFFICULTIES.has(result.difficulty):
		result.difficulty = ""


static func _find_bedrock(dir: String, depth: int) -> bool:
	if DirAccess.dir_exists_absolute(dir.path_join("db")) and FileAccess.file_exists(dir.path_join("levelname.txt")):
		return true
	if depth >= SEARCH_DEPTH:
		return false
	for sub in DirAccess.get_directories_at(dir):
		if not IGNORED_DIRS.has(sub) and _find_bedrock(dir.path_join(sub), depth + 1):
			return true
	return false
