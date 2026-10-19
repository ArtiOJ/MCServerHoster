class_name WorldManager
extends RefCounted
## Lists, switches, exports, resets and deletes the worlds inside a server folder,
## and manages the active world's datapacks. Layouts follow WorldImporter:
##   SPLIT      - Paper before 26: <name>/, <name>_nether/DIM-1/, <name>_the_end/DIM1/
##   DIMENSIONS - Paper 26+: <name>/dimensions/minecraft/<dimension>/
##   SINGLEPLAYER - DIM-1/DIM1 inside the world folder (as imported, before first start)

## Files a server recreates and that must not travel with an exported world.
const SKIP_FILES: PackedStringArray = ["session.lock", "uid.dat"]
## Per-player data kept by "Keep player data" when a world is reset.
const PLAYER_DIRS: PackedStringArray = ["playerdata", "players", "stats", "advancements"]
const NETHER_SUFFIX := "_nether"
const END_SUFFIX := "_the_end"
const DATAPACKS_DIR := "datapacks"

static var _re_pack_entry := RegEx.create_from_string("\\[([^\\]]+?)(?: \\(([^)]*)\\))?\\]")


# --- Discovery (thread-safe) --------------------------------------------------

## Worlds in [param server_dir]. [param active_level] is server.properties level-name; it is
## always listed (as not yet generated when its folder has no level.dat).
## [param with_size] walks the folders, which is slow for big worlds.
## Each entry: {name, folder, folders, version, seed, game_mode, last_played, size_bytes,
## active, generated, layout, dimensions, datapacks_dir}.
static func list_worlds(server_dir: String, active_level: String, with_size := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dirs := DirAccess.get_directories_at(server_dir)
	for d in dirs:
		if not FileAccess.file_exists(server_dir.path_join(d).path_join("level.dat")):
			continue
		# <name>_nether / <name>_the_end belong to <name> when that world exists.
		var base := _split_base(d)
		if base != "" and FileAccess.file_exists(server_dir.path_join(base).path_join("level.dat")):
			continue
		out.append(read_world(server_dir, d, active_level, with_size))
	if active_level != "" and not out.any(func(w: Dictionary) -> bool: return w.folder == active_level):
		# A brand-new world exists on disk before its first save writes level.dat.
		if _has_world_data(server_dir.path_join(active_level)):
			var unsaved := read_world(server_dir, active_level, active_level, with_size)
			unsaved.unsaved = true
			out.append(unsaved)
			return _sorted(out)
		var placeholder := _empty_world(active_level)
		placeholder.active = true
		placeholder.datapacks_dir = server_dir.path_join(active_level).path_join(DATAPACKS_DIR)
		out.append(placeholder)
	return _sorted(out)


static func _sorted(worlds: Array[Dictionary]) -> Array[Dictionary]:
	worlds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.active != b.active:
			return a.active
		return str(a.folder).naturalnocasecmp_to(str(b.folder)) < 0)
	return worlds


## True when [param dir] already holds world data (region files or dimensions) even
## though level.dat has not been written yet.
static func _has_world_data(dir: String) -> bool:
	for sub in ["region", "dimensions", "entities", "poi"]:
		if DirAccess.dir_exists_absolute(dir.path_join(sub)):
			return true
	return false


## Details of the world stored in [param folder] (a folder name inside [param server_dir]).
static func read_world(server_dir: String, folder: String, active_level := "", with_size := true) -> Dictionary:
	var w := _empty_world(folder)
	var dir := server_dir.path_join(folder)
	w.generated = true
	w.active = folder == active_level
	w.datapacks_dir = dir.path_join(DATAPACKS_DIR)
	var analysis := WorldImporter.detect_layout(dir)
	w.layout = analysis.layout
	w.dimensions = analysis.dimensions
	var folders := PackedStringArray([folder])
	for suffix in [NETHER_SUFFIX, END_SUFFIX]:
		if DirAccess.dir_exists_absolute(server_dir.path_join(folder + suffix)):
			folders.append(folder + suffix)
	w.folders = folders
	var data: Dictionary = Nbt.read_file(dir.path_join("level.dat")).get("Data", {})
	w.name = str(data.get("LevelName", folder))
	w.version = str(Nbt.dig(data, ["Version", "Name"], ""))
	var mode := int(data.get("GameType", -1))
	w.game_mode = WorldImporter.GAME_MODES[mode] if mode >= 0 and mode < WorldImporter.GAME_MODES.size() else ""
	w.last_played = int(data.get("LastPlayed", 0)) / 1000
	w.seed = read_seed(dir, data)
	w.enabled_packs = PackedStringArray(Nbt.dig(data, ["DataPacks", "Enabled"], []))
	w.disabled_packs = PackedStringArray(Nbt.dig(data, ["DataPacks", "Disabled"], []))
	if with_size:
		var total := 0
		for f in folders:
			total += WorldImporter.dir_size(server_dir.path_join(f))
		w.size_bytes = total
	return w


## The world's seed as text ("" when unknown). Minecraft 26+ keeps it in the overworld's
## world_gen_settings.dat; earlier versions in level.dat.
static func read_seed(world_dir: String, level_data := {}) -> String:
	var data := level_data
	if data.is_empty():
		data = Nbt.read_file(world_dir.path_join("level.dat")).get("Data", {})
	var seed: Variant = Nbt.dig(data, ["WorldGenSettings", "seed"])
	if seed == null:
		seed = data.get("RandomSeed")
	if seed == null:
		var gen := Nbt.read_file(world_dir.path_join("dimensions/minecraft/overworld/data/minecraft/world_gen_settings.dat"))
		seed = Nbt.dig(gen, ["data", "seed"])
	return str(seed) if seed != null else ""


# --- Actions --------------------------------------------------------------------

## Why [param inst]'s worlds can't be changed right now ("" when they can).
static func change_blocker(inst: ServerInstance) -> String:
	if inst.is_temporary():
		return "A temporary copy of this server is pending. Keep or discard it first."
	if inst.is_process_alive() or inst.state == ServerInstance.State.INSTALLING:
		return "Stop the server first."
	return ""


## Makes [param folder] the world the server loads (server.properties level-name).
static func set_active(inst: ServerInstance, folder: String) -> String:
	var blocker := change_blocker(inst)
	if blocker != "":
		return blocker
	var props := ServerProperties.load_file(inst.config.properties_path())
	if props.get_value("level-name", "world") == folder:
		return ""
	props.set_value("level-name", folder)
	var err := props.save_file(inst.config.properties_path())
	if err != OK:
		return "Could not save server.properties: %s" % error_string(err)
	# Known game rule values belong to the previous world.
	inst.config.known_gamerules.clear()
	inst.save_config()
	inst.log_system("Active world switched to \"%s\". It loads on the next start." % folder)
	return ""


## Permanently deletes a world that is not the active one.
static func delete_world(inst: ServerInstance, world: Dictionary) -> String:
	var blocker := change_blocker(inst)
	if blocker != "":
		return blocker
	if world.active:
		return "The active world can't be deleted. Switch to another world first, or reset it."
	for f in world.folders:
		var err := FileOps.remove_tree(inst.config.directory.path_join(f))
		if err != OK:
			return "Could not delete %s: %s" % [f, error_string(err)]
	inst.log_system("Deleted world \"%s\"." % world.folder)
	return ""


## Deletes the active world so a fresh one is generated on the next start. A safety
## backup is saved first. [param new_seed]: "" = random, otherwise written as level-seed.
## [param keep_players] carries player inventories, stats and advancements over.
static func reset_world(inst: ServerInstance, world: Dictionary, new_seed: String, keep_players: bool) -> String:
	var blocker := change_blocker(inst)
	if blocker != "":
		return blocker
	if not world.active:
		return "Only the active world can be reset."
	var dir := inst.config.directory
	if world.generated:
		inst.log_system("Saving a safety backup before resetting the world…")
		if await inst.backups.create_backup(false, "", "pre-reset") == "":
			return "The safety backup failed, so the world was left untouched."
	var keep := dir.path_join(".manager").path_join("reset-players-%d" % Time.get_ticks_usec())
	if keep_players and world.generated:
		for sub in PLAYER_DIRS:
			var src := dir.path_join(world.folder).path_join(sub)
			if DirAccess.dir_exists_absolute(src):
				DirAccess.make_dir_recursive_absolute(keep)
				DirAccess.rename_absolute(src, keep.path_join(sub))
	inst.mark_installing(true)
	for f in world.folders:
		var path := dir.path_join(f)
		await FileOps.run_async(inst, func() -> Error: return FileOps.remove_tree(path))
	if DirAccess.dir_exists_absolute(keep):
		var target := dir.path_join(world.folder)
		DirAccess.make_dir_recursive_absolute(target)
		for sub in DirAccess.get_directories_at(keep):
			DirAccess.rename_absolute(keep.path_join(sub), target.path_join(sub))
		FileOps.remove_tree(keep)
	inst.mark_installing(false)
	var props := ServerProperties.load_file(inst.config.properties_path())
	props.set_value("level-seed", new_seed.strip_edges())
	props.save_file(inst.config.properties_path())
	inst.config.known_gamerules.clear()
	inst.save_config()
	inst.log_system("World \"%s\" reset (%s). A new world is generated on the next start." % [world.folder,
			"seed " + new_seed.strip_edges() if new_seed.strip_edges() != "" else "random seed"])
	return ""


# --- Export (thread-safe) ---------------------------------------------------------

## Files to put in a singleplayer-ready zip: [[absolute path, path inside the zip]].
## Split worlds are merged back so the nether and end sit in DIM-1/DIM1 inside the world.
static func export_entries(server_dir: String, world: Dictionary) -> Array:
	var top := WorldImporter.unique_level_name("/nonexistent", str(world.name) if str(world.name).strip_edges() != "" else str(world.folder))
	var entries: Array = []
	_collect(server_dir.path_join(world.folder), top, entries)
	if world.layout != WorldImporter.Layout.DIMENSIONS:
		for pair in [[NETHER_SUFFIX, "DIM-1"], [END_SUFFIX, "DIM1"]]:
			var dim := server_dir.path_join(world.folder + pair[0]).path_join(pair[1])
			if DirAccess.dir_exists_absolute(dim):
				_collect(dim, top.path_join(pair[1]), entries)
	return entries


## Writes the world to [param zip_path]. [param job] is a Dictionary shared with the
## caller: {"mutex": Mutex, "progress": float}. Returns "" or an error message.
static func export_zip(server_dir: String, world: Dictionary, zip_path: String, job: Dictionary) -> String:
	var entries := export_entries(server_dir, world)
	if entries.is_empty():
		return "The world has no files to export."
	var total := 0
	for e in entries:
		var f := FileAccess.open(e[0], FileAccess.READ)
		total += f.get_length() if f != null else 0
	var tmp := zip_path + ".part"
	var zip := ZIPPacker.new()
	var err := zip.open(tmp)
	if err != OK:
		return "Cannot create %s (%s)." % [zip_path.get_file(), error_string(err)]
	var done := 0
	for e in entries:
		var f := FileAccess.open(e[0], FileAccess.READ)
		if f == null:
			continue
		zip.start_file(e[1])
		while f.get_position() < f.get_length():
			var chunk := f.get_buffer(1048576)
			zip.write_file(chunk)
			done += chunk.size()
			if job.has("mutex"):
				(job.mutex as Mutex).lock()
				job.progress = float(done) / maxf(total, 1.0)
				(job.mutex as Mutex).unlock()
		zip.close_file()
	zip.close()
	if FileAccess.file_exists(zip_path):
		DirAccess.remove_absolute(zip_path)
	return "" if DirAccess.rename_absolute(tmp, zip_path) == OK else "Could not write %s." % zip_path


static func _collect(dir: String, prefix: String, entries: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if not SKIP_FILES.has(f) and not f.ends_with(".tmp"):
			entries.append([dir.path_join(f), prefix.path_join(f)])
	var access := DirAccess.open(dir)
	for d in DirAccess.get_directories_at(dir):
		if access != null and access.is_link(d):
			continue
		_collect(dir.path_join(d), prefix.path_join(d), entries)


# --- Datapacks ----------------------------------------------------------------------

## Datapacks in [param datapacks_dir]: [{name, id, path, is_zip, description, format, valid}].
## [param id] is the in-game name ("file/<name>").
static func list_datapacks(datapacks_dir: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not DirAccess.dir_exists_absolute(datapacks_dir):
		return out
	for d in DirAccess.get_directories_at(datapacks_dir):
		var meta := FileAccess.get_file_as_string(datapacks_dir.path_join(d).path_join("pack.mcmeta"))
		out.append(_pack_entry(d, datapacks_dir.path_join(d), false, meta))
	for f in DirAccess.get_files_at(datapacks_dir):
		if f.get_extension().to_lower() != "zip":
			continue
		var meta := ""
		var reader := ZIPReader.new()
		if reader.open(datapacks_dir.path_join(f)) == OK:
			if reader.file_exists("pack.mcmeta"):
				meta = reader.read_file("pack.mcmeta").get_string_from_utf8()
			reader.close()
		out.append(_pack_entry(f, datapacks_dir.path_join(f), true, meta))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	return out


## Parses pack.mcmeta into {description, format, valid}. Handles plain-text and JSON-text
## descriptions and both "pack_format" and the newer "min_format"/"max_format".
static func parse_pack_meta(text: String) -> Dictionary:
	var result := {"description": "", "format": "", "valid": false}
	var json := JSON.new()
	if text == "" or json.parse(text) != OK:
		return result
	var data: Variant = json.data
	if not data is Dictionary or not (data as Dictionary).get("pack") is Dictionary:
		return result
	var pack: Dictionary = data.pack
	result.valid = true
	result.description = _text_component(pack.get("description", ""))
	var fmt: Variant = pack.get("pack_format", pack.get("max_format", pack.get("min_format")))
	if fmt is Array and not (fmt as Array).is_empty():
		fmt = fmt[0]
	result.format = str(int(fmt)) if fmt is float or fmt is int else ""
	return result


## Copies a datapack (.zip or folder) into [param datapacks_dir]. Returns "" or an error.
static func add_datapack(datapacks_dir: String, source: String) -> String:
	var is_zip := FileAccess.file_exists(source)
	var name := source.get_file()
	if is_zip:
		if name.get_extension().to_lower() != "zip":
			return "Datapacks are .zip files or folders."
		var reader := ZIPReader.new()
		if reader.open(source) != OK:
			return "%s is not a readable .zip file." % name
		var ok := reader.file_exists("pack.mcmeta")
		reader.close()
		if not ok:
			return "%s has no pack.mcmeta at its top level, so Minecraft won't load it. (Is it a resource pack, or a zip containing the pack folder?)" % name
	elif not FileAccess.file_exists(source.path_join("pack.mcmeta")):
		return "%s has no pack.mcmeta, so it isn't a datapack." % name
	var target := datapacks_dir.path_join(name)
	if FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target):
		return "A datapack called %s is already installed." % name
	DirAccess.make_dir_recursive_absolute(datapacks_dir)
	var err := DirAccess.copy_absolute(source, target) if is_zip else FileOps.copy_tree(source, target)
	return "" if err == OK else "Could not copy %s: %s" % [name, error_string(err)]


## Permanently removes an installed datapack.
static func remove_datapack(pack: Dictionary) -> String:
	var err := DirAccess.remove_absolute(pack.path) if pack.is_zip else FileOps.remove_tree(pack.path)
	return "" if err == OK else "Could not remove %s: %s" % [pack.name, error_string(err)]


## Pack ids from the reply to `datapack list enabled|available`, e.g.
## "There are 2 data pack(s) enabled: [vanilla (built-in)], [file/test (world)]".
static func parse_datapack_list(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var plain := Ansi.strip(text)
	var colon := plain.find(":")
	if colon < 0:
		return out
	for m in _re_pack_entry.search_all(plain.substr(colon + 1)):
		out.append(m.get_string(1).strip_edges())
	return out


## Command that enables or disables a pack in-game.
static func datapack_command(pack_id: String, enable: bool) -> String:
	return "datapack %s \"%s\"" % ["enable" if enable else "disable", pack_id.replace("\\", "\\\\").replace("\"", "\\\"")]


static func _pack_entry(name: String, path: String, is_zip: bool, meta_text: String) -> Dictionary:
	var meta := parse_pack_meta(meta_text)
	return {"name": name, "id": "file/" + name, "path": path, "is_zip": is_zip,
			"description": meta.description, "format": meta.format, "valid": meta.valid}


static func _text_component(value: Variant) -> String:
	if value is String:
		return Ansi.strip(value)
	if value is Dictionary:
		var s := _text_component((value as Dictionary).get("text", ""))
		for extra in (value as Dictionary).get("extra", []):
			s += _text_component(extra)
		return s
	if value is Array:
		var s := ""
		for part in value:
			s += _text_component(part)
		return s
	return str(value) if value != null else ""


static func _empty_world(folder: String) -> Dictionary:
	return {
		"name": folder, "folder": folder, "folders": PackedStringArray([folder]), "version": "", "seed": "",
		"game_mode": "", "last_played": 0, "size_bytes": 0, "active": false, "generated": false,
		"layout": WorldImporter.Layout.SINGLEPLAYER, "dimensions": PackedStringArray(), "datapacks_dir": "",
		"enabled_packs": PackedStringArray(), "disabled_packs": PackedStringArray(), "unsaved": false,
	}


static func _split_base(folder: String) -> String:
	for suffix in [NETHER_SUFFIX, END_SUFFIX]:
		if folder.ends_with(suffix) and folder.length() > suffix.length():
			return folder.left(folder.length() - suffix.length())
	return ""
