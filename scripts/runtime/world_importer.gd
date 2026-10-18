class_name WorldImporter
extends RefCounted
## Imports a Minecraft Java world (a downloaded map, a singleplayer save or another
## server's world) into a server, from a .zip or a folder.
##
## Layouts (verified by booting real Paper 1.21.11 and 26.3):
##   SINGLEPLAYER - vanilla save: nether/end live in DIM-1/ and DIM1/ inside the world folder.
##   SPLIT        - Bukkit/Paper before 26: <level>/, <level>_nether/DIM-1/, <level>_the_end/DIM1/.
##   DIMENSIONS   - Minecraft/Paper 26+: <level>/dimensions/minecraft/<dimension>/.
## Normalisation depends on the target server (both paths verified with real Paper):
##   Paper before 26.1 - SPLIT, sibling folders named after the target level-name.
##   Paper 26.1+       - SINGLEPLAYER: Minecraft's own upgrade turns it into DIMENSIONS on
##                       first start. (A SPLIT world whose nether/end folders lack their own
##                       level.dat crashes Paper 26's legacy importer, so it is not used.)
## DIMENSIONS worlds are copied as they are.

enum Layout { SINGLEPLAYER, SPLIT, DIMENSIONS }
enum Mode { REPLACE, ADD }

const LAYOUT_NAMES: PackedStringArray = ["Singleplayer save", "Bukkit/Paper (separate nether and end folders)", "Minecraft 26+ (dimensions folder)"]
const GAME_MODES: PackedStringArray = ["survival", "creative", "adventure", "spectator"]
const DIFFICULTIES: PackedStringArray = ["peaceful", "easy", "normal", "hard"]
const SEARCH_DEPTH := 4
## Files that must not be carried over: Paper recreates them, and stale copies cause
## "world already loaded" UUID clashes or lock errors.
const DROP_FILES: PackedStringArray = ["session.lock", "uid.dat"]
const IGNORED_DIRS: PackedStringArray = ["__MACOSX", ".git"]
## First Minecraft version that stores worlds in the DIMENSIONS layout.
const DIMENSIONS_SINCE := "26.1"


## Inspects [param source] (.zip or folder). Zips are extracted to a staging folder,
## which [method cleanup] deletes. [param server_version] enables the version check.
## Returns {ok, error, warnings, name, version, data_version, layout, game_mode, difficulty,
## hardcore, dimensions, size_bytes, world_dir, nether_src, end_src, staging, source, resource_pack}.
static func analyze(owner: Node, source: String, server_version := "") -> Dictionary:
	var result := {
		"ok": false, "error": "", "warnings": PackedStringArray(), "source": source, "staging": "",
		"name": "", "version": "", "data_version": 0, "layout": Layout.SINGLEPLAYER,
		"game_mode": "", "difficulty": "", "hardcore": false, "dimensions": PackedStringArray(),
		"size_bytes": 0, "world_dir": "", "nether_src": "", "end_src": "", "resource_pack": false,
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
	if candidates.is_empty():
		result.error = "This is a Bedrock Edition world. Paper servers run Java Edition and cannot load Bedrock worlds." if bedrock \
				else "No Minecraft world was found (there is no level.dat in it)."
		cleanup(result)
		return result
	var world_dir := pick_world(candidates)
	if candidates.size() > 1:
		var others := Array(candidates).filter(func(c: String) -> bool:
			return c != world_dir and not c.ends_with("_nether") and not c.ends_with("_the_end"))
		if not others.is_empty():
			result.warnings.append("Found %d worlds; importing \"%s\"." % [others.size() + 1, world_dir.get_file()])
	result.world_dir = world_dir
	_detect_layout(world_dir, result)
	_read_level(world_dir.path_join("level.dat"), result)

	if server_version != "" and result.version != "":
		var cmp := Fmt.compare_versions(result.version, server_version)
		if cmp > 0:
			result.error = "This world was saved in Minecraft %s, but the server runs %s. Minecraft cannot load worlds from newer versions; update the server first." % [result.version, server_version]
		elif cmp < 0:
			result.warnings.append("Saved in %s; it will be upgraded to %s on first start. Upgraded worlds can't be opened in %s again." % [result.version, server_version, result.version])
	elif result.version == "":
		result.warnings.append("The world's Minecraft version is unknown (very old save?). It will be upgraded on first start.")
	if result.layout != Layout.DIMENSIONS and server_version != "" and uses_dimensions_layout(server_version):
		result.warnings.append("On its first start Paper converts the world to the 26+ storage format; it pauses for 30 seconds before doing so.")
	if result.layout == Layout.DIMENSIONS and server_version != "" and not uses_dimensions_layout(server_version) and result.error == "":
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
static func import_into(inst: ServerInstance, analysis: Dictionary, mode: Mode, apply_settings: bool, on_status := Callable()) -> Dictionary:
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
	if mode == Mode.ADD:
		level = unique_level_name(dir, display_name(analysis))
	else:
		var existing := inst.backups.world_dirs(dir)
		if not existing.is_empty():
			report.call("Saving a safety backup of the current world before replacing it…")
			if await inst.backups.create_backup(false, dir, "pre-import") == "":
				return {"ok": false, "error": "The safety backup failed, so the current world was left untouched."}
	inst.mark_installing(true)
	if mode == Mode.REPLACE:
		# Permanently remove the old world folders (the safety backup above keeps a copy).
		for w in inst.backups.world_dirs(dir):
			var path := dir.path_join(w)
			await FileOps.run_async(inst, func() -> Error: return FileOps.remove_tree(path))
	report.call("Importing \"%s\" as world folder \"%s\"…" % [display_name(analysis), level])
	var version := inst.config.mc_version
	var err: Error = await FileOps.run_async(inst, func() -> Error: return place_world(analysis, dir, level, version))
	inst.mark_installing(false)
	if err != OK:
		return {"ok": false, "error": "Copying the world failed: %s" % error_string(err)}

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
	report.call("World \"%s\" imported. It will be prepared on the next start." % display_name(analysis))
	return {"ok": true, "level_name": level}


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
			if IGNORED_DIRS.has(sub) or sub in ["region", "DIM-1", "DIM1", "dimensions", "playerdata", "players", "data", "datapacks", "entities", "poi"]:
				continue
			queue.append([dir.path_join(sub), item[1] + 1])
	return out


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


static func _detect_layout(world_dir: String, result: Dictionary) -> void:
	var dims := PackedStringArray()
	if DirAccess.dir_exists_absolute(world_dir.path_join("dimensions")):
		result.layout = Layout.DIMENSIONS
		var base := world_dir.path_join("dimensions/minecraft")
		for pair in [["overworld", "Overworld"], ["the_nether", "Nether"], ["the_end", "End"]]:
			if DirAccess.dir_exists_absolute(base.path_join(pair[0]).path_join("region")):
				dims.append(pair[1])
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
