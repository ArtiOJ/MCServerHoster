extends Node
## BlueMap from the BlueMap tab's operations on a real Paper server: install, the download
## consent, render status, the rendered files the viewer reads (decoded like the viewer
## does), maps for more dimensions, map settings and render areas, render actions, render
## threads, BlueMap's settings and removing a map. Needs network access (Modrinth, Mojang).
## Usage: godot --headless --path . res://tests/integration/bluemap_test.tscn -- --no-autostart --profile=bm --root=<dir> [--version=26.3]

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://bluemap-test-servers")
	var version := "26.3"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--version="):
			version = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "BlueMap Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 2048, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "view-distance": "4", "level-seed": "42"},
	})
	_check(created.ok, "create server")
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance
	var dir := inst.config.directory
	var status: Dictionary = await inst.call_op("bluemap_status")
	_check(status.ok and not status.installed and status.note != "", "not installed yet")
	var installed: Dictionary = await inst.call_op("plugin_install_modrinth", {"project_id": BlueMap.MODRINTH_ID})
	_check(installed.ok and BlueMap.installed_info(dir).installed, "installed from Modrinth: %s" % installed.get("error", ""))
	var jar: String = installed.get("installed", [{}])[0].get("file", "") if not installed.get("installed", []).is_empty() else ""
	_check(jar.contains("paper"), "the Paper build: %s" % jar)
	status = await inst.call_op("bluemap_status")
	_check(status.installed and not status.accepted and not status.configs, "asks for the download consent")
	var accepted: Dictionary = await inst.call_op("bluemap_accept")
	_check(accepted.ok and BlueMap.download_accepted(dir) and not accepted.reloaded, "accepted before the first start")

	await _boot(inst)
	# A server without players fully generates almost nothing, and BlueMap renders only full
	# chunks: load an area the way a visiting player (or Chunky) would.
	await inst.rcon.execute("forceload add -48 -48 47 47")
	await get_tree().create_timer(15.0).timeout
	await inst.rcon.execute("forceload remove all")
	await inst.rcon.execute("save-all flush")
	await _wait_status(inst, func(s: Dictionary) -> bool: return s.loaded and s.maps.size() >= 3, 180.0)
	status = await inst.call_op("bluemap_status")
	var ids: Array = status.maps.map(func(m: Dictionary) -> String: return m.id)
	_check(status.loaded and ids.has("world") and ids.has("world_the_nether") and ids.has("world_the_end"), "loaded with BlueMap's maps: %s (%s)" % [ids, status.note])
	_check(status.settings.get("render-thread-count") != null and int(status.port) > 0, "settings read: %s, web port %d" % [status.settings, status.port])

	# The first render of the spawn area.
	await _wait_status(inst, func(s: Dictionary) -> bool: return _map(s, "world").get("state") == "updated" and _has_hires(dir), 600.0)
	status = await inst.call_op("bluemap_status")
	var world := _map(status, "world")
	_check(world.state == "updated" and world.viewable and world.suffix == ".gz", "world rendered: %s" % world)
	var players_file := dir.path_join("bluemap/web/maps/world/live/players.json")
	var written := FileAccess.get_modified_time(players_file) if FileAccess.file_exists(players_file) else 0
	await get_tree().create_timer(5.0).timeout
	_check(FileAccess.file_exists(players_file) and FileAccess.get_modified_time(players_file) > written, "live players written to the map storage for the viewer")

	# What the viewer reads, decoded like the viewer does.
	var hires_path := _first_hires(dir)
	var files: Dictionary = await inst.call_op("bluemap_files", {"map": "world", "items": [
		{"path": "settings.json", "mtime": -1}, {"path": "textures.json.gz", "mtime": -1},
		{"path": "tiles/1/x0/z0.png", "mtime": -1}, {"path": hires_path, "mtime": -1},
		{"path": "../../server.properties", "mtime": -1}, {"path": "rstate/x0/z0.tiles.dat", "mtime": -1},
		{"path": "tiles/0/x9/9/9/z9/9/9.prbm.gz", "mtime": -1}]})
	_check(files.ok and files.files.has("settings.json") and files.files.has(hires_path) and files.files.has("tiles/1/x0/z0.png"), "the viewer's files: %s" % [files.get("files", {}).keys()])
	_check(files.missing.has("../../server.properties") and files.missing.has("rstate/x0/z0.tiles.dat") and files.missing.size() == 3, "nothing outside the map, missing tiles reported: %s" % [files.get("missing")])
	if files.ok and files.files.has(hires_path):
		var mtime: int = files.files[hires_path].mtime
		var again: Dictionary = await inst.call_op("bluemap_files", {"map": "world", "items": [{"path": hires_path, "mtime": mtime}]})
		_check(again.ok and again.files.is_empty() and again.missing.is_empty(), "an unchanged tile isn't sent again")
		var tex := Prbm.textures(Prbm.decompress(Marshalls.base64_to_raw(files.files["textures.json.gz"].data), ".gz"))
		_check(tex.ok and tex.atlas.get_width() == Prbm.ATLAS_COLUMNS * Prbm.TEXTURE_SIZE and not tex.transparent.is_empty(), "textures: %d rows, %d transparent" % [tex.get("atlas", Image.new()).get_height() / 16, tex.get("transparent", {}).size()])
		var tile := Prbm.parse(Prbm.decompress(Marshalls.base64_to_raw(files.files[hires_path].data), ".gz"))
		_check(tile.ok and tile.count > 0 and not tile.groups.is_empty(), "hires tile parsed: %d vertices, %d groups" % [tile.get("count", 0), tile.get("groups", []).size()])
		if tile.ok:
			var parts := Prbm.surfaces(tile, tex.get("transparent", {}), tex.get("cutout", {}))
			var total := 0
			for p in parts:
				if not p.is_empty():
					total += p.count
					_check(p.vertices is PackedVector3Array and p.vertices.size() == p.count and p.uvs.size() == p.count
							and p.images.color.get_width() == Prbm.DATA_WIDTH, "surface arrays line up (%d vertices)" % p.count)
			_check(total <= tile.count and total > 0, "every vertex in a surface")
		var img := Image.new()
		_check(img.load_png_from_buffer(Marshalls.base64_to_raw(files.files["tiles/1/x0/z0.png"].data)) == OK and img.get_height() == img.get_width() * 2, "lowres tile: %s" % img.get_size())

	# Another map: a second Nether map, added and then removed.
	var saved: Dictionary = await inst.call_op("bluemap_map_save", {"map": "nether2", "dimension": "minecraft:the_nether", "values": {"name": "Nether two"}})
	_check(saved.ok and saved.created and saved.reloaded, "map added: %s" % saved.get("error", ""))
	await _wait_status(inst, func(s: Dictionary) -> bool: return s.loaded and not _map(s, "nether2").is_empty(), 60.0)
	status = await inst.call_op("bluemap_status")
	_check(_map(status, "nether2").get("name") == "Nether two" and _map(status, "nether2").get("dimension") == "minecraft:the_nether", "BlueMap has the new map")
	var bad: Dictionary = await inst.call_op("bluemap_map_save", {"map": "x", "dimension": "minecraft:nowhere"})
	_check(not bad.ok, "unknown dimensions refused")
	bad = await inst.call_op("bluemap_map_save", {"map": "../core", "dimension": "minecraft:overworld"})
	_check(not bad.ok, "bad map names refused")

	# Map settings and render areas.
	saved = await inst.call_op("bluemap_map_save", {"map": "world", "values": {"name": "Overworld", "sky-color": "#112233", "ambient-light": 0.3, "remove-caves-below-y": 40},
			"masks": [{"min-x": -64, "max-x": 64, "min-z": -64, "max-z": 64}, {"min-y": 100, "subtract": true}]})
	_check(saved.ok and not saved.created and saved.rerender, "settings saved (caves change needs a re-render)")
	var got: Dictionary = await inst.call_op("bluemap_map_get", {"map": "world"})
	_check(got.ok and got.map.values.name == "Overworld" and got.map.values["sky-color"] == "#112233" and is_equal_approx(got.map.values["ambient-light"], 0.3), "settings read back")
	_check(got.ok and got.map.masks.ok and _ints(got.map.masks.boxes) == [{"min-x": -64, "max-x": 64, "min-z": -64, "max-z": 64}, {"subtract": true, "min-y": 100}], "render areas read back: %s" % [got.map.get("masks")])
	var text := BlueMap.read_config(dir, "maps/world.conf")
	_check(text.contains("# The path to the save folder") and text.contains("marker-sets"), "BlueMap's comments and other keys kept")
	await _wait_status(inst, func(s: Dictionary) -> bool: return s.loaded, 60.0)

	# Render actions.
	for spec in [["update", "world", {"x": 0, "z": 0, "radius": 40}], ["fix-edges", "world", {}], ["force-update", "world", {"x": 0, "z": 0, "radius": 16}], ["freeze", "world_the_end", {}]]:
		var res: Dictionary = await inst.call_op("bluemap_action", {"action": spec[0], "map": spec[1], "area": spec[2]})
		_check(res.ok, "%s %s: %s" % [spec[0], spec[1], res.get("error", res.get("reply", ""))])
	status = await inst.call_op("bluemap_status")
	_check(_map(status, "world_the_end").get("frozen", false), "frozen shows: %s" % _map(status, "world_the_end"))
	var res: Dictionary = await inst.call_op("bluemap_action", {"action": "unfreeze", "map": "world_the_end"})
	status = await inst.call_op("bluemap_status")
	_check(res.ok and not _map(status, "world_the_end").get("frozen", true), "unfrozen")
	res = await inst.call_op("bluemap_action", {"action": "purge", "map": "nether2"})
	_check(res.ok, "render deleted: %s" % res.get("error", ""))
	res = await inst.call_op("bluemap_action", {"action": "update", "map": "nowhere"})
	_check(not res.ok, "unknown maps refused")
	res = await inst.call_op("bluemap_troubleshoot", {"map": "world", "x": 0, "z": 0})
	_check(res.ok and str(res.text).contains("Troubleshooting"), "troubleshoot: %s" % str(res.get("text", res.get("error", ""))).replace("\n", " | "))

	# Render threads and tasks.
	res = await inst.call_op("bluemap_control", {"action": "stop"})
	status = await inst.call_op("bluemap_status")
	_check(res.ok and status.threads == "stopped", "render threads stopped: %s" % status.threads)
	res = await inst.call_op("bluemap_control", {"action": "start"})
	status = await inst.call_op("bluemap_status")
	_check(res.ok and status.threads in ["running", "idle"], "started again: %s" % status.threads)
	res = await inst.call_op("bluemap_control", {"action": "cancel"})
	_check(res.ok, "cancel waiting tasks: %s" % res.get("reply", res.get("error", "")))

	# BlueMap's settings.
	res = await inst.call_op("bluemap_settings_save", {"values": {"render-thread-count": 2, "webserver-port": 8123, "player-render-limit": 5, "live-player-markers": false}})
	_check(res.ok and res.reloaded, "settings saved and BlueMap reloaded")
	await _wait_status(inst, func(s: Dictionary) -> bool: return s.loaded, 60.0)
	status = await inst.call_op("bluemap_status")
	_check(int(status.settings["render-thread-count"]) == 2 and int(status.port) == 8123 and int(status.settings["player-render-limit"]) == 5 and not status.settings["live-player-markers"], "settings read back: %s" % status.settings)
	res = await inst.call_op("bluemap_settings_save", {"values": {"webserver-port": 80}})
	_check(not res.ok, "privileged web ports refused")
	res = await inst.call_op("bluemap_live", {"map": "world", "markers_mtime": -1})
	_check(res.ok and res.players is Array and res.has("markers"), "live players and markers")

	# Removing a map removes its render.
	var storage := BlueMap.map_storage(dir, "nether2")
	res = await inst.call_op("bluemap_map_delete", {"map": "nether2"})
	status = await inst.call_op("bluemap_status")
	_check(res.ok and _map(status, "nether2").is_empty() and not FileAccess.file_exists(BlueMap.config_path(dir, "maps/nether2.conf"))
			and not DirAccess.dir_exists_absolute(storage.root), "map removed with its files")

	await _stop(inst)
	status = await inst.call_op("bluemap_status")
	_check(status.ok and not status.ready and _map(status, "world").get("viewable", false), "rendered maps still viewable while stopped")
	if _failures.is_empty():
		ServerManager.delete_server(inst.config.id, true, true)
	_finish()


## Numbers as ints (results come back through JSON).
static func _ints(boxes: Array) -> Array:
	return boxes.map(func(b: Dictionary) -> Dictionary:
		var out := {}
		for k in b:
			out[k] = int(b[k]) if b[k] is float else b[k]
		return out)


func _map(status: Dictionary, id: String) -> Dictionary:
	for m in status.get("maps", []):
		if m.id == id:
			return m
	return {}


func _has_hires(dir: String) -> bool:
	return _first_hires(dir) != ""


## The first hires tile of the world map (path below the map's root), or "".
func _first_hires(dir: String) -> String:
	var root := dir.path_join("bluemap/web/maps/world/")
	var stack := [root.path_join("tiles/0")] if DirAccess.dir_exists_absolute(root.path_join("tiles/0")) else []
	while not stack.is_empty():
		var d: String = stack.pop_back()
		for f in DirAccess.get_files_at(d):
			if f.ends_with(".prbm.gz"):
				return d.path_join(f).trim_prefix(root)
		for sub in DirAccess.get_directories_at(d):
			stack.append(d.path_join(sub))
	return ""


func _wait_status(inst: ServerInstance, cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while Time.get_ticks_msec() < deadline:
		var s: Dictionary = await inst.call_op("bluemap_status")
		if s.ok and cond.call(s):
			return
		await get_tree().create_timer(2.0).timeout


func _boot(inst: ServerInstance) -> void:
	inst.start()
	await _wait_for(func() -> bool: return (inst.is_online() and inst.rcon.is_ready()) or inst.state == ServerInstance.State.CRASHED, 240.0)
	_check(inst.is_online() and inst.rcon.is_ready(), "server boots")


func _stop(inst: ServerInstance) -> void:
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 120.0)


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nBlueMap test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
