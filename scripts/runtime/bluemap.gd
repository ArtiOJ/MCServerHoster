class_name BlueMap
extends RefCounted
## BlueMap (3D map plugin) for the BlueMap tab: its config files (HOCON), console commands
## and their replies, and where it keeps the rendered map. Verified with BlueMap 5.29 on
## Paper 26.3: commands answer over RCON (with § colours). Nothing renders until core.conf
## has accept-download: true (BlueMap then downloads Minecraft's client jar for the block
## models and textures) and BlueMap is reloaded. A map's data (the "file" storage) lives in
## <storage root>/<map>/: settings.json, textures.json<ext>, tiles/0 (hires models,
## .prbm<ext>, 32×32 blocks each), tiles/1..3 (lowres PNGs: colour on top, height and
## block light below), live/players.json and live/markers.json. Chunks without light data
## (WorldPainter exports, for one) are skipped unless the map ignores missing light; Chunky's
## "Load existing chunks" gives them light.

const PLUGIN_NAME := "BlueMap"
const MODRINTH_ID := "swbUV1cr"
const CONFIG_DIR := "plugins/BlueMap"
const DEFAULT_PORT := 8100
## Map config keys the map settings edit: key -> type ("string", "int", "float", "bool",
## "color", "pos").
const MAP_FIELDS := {
	"name": "string", "sorting": "int", "start-pos": "pos", "sky-color": "color", "void-color": "color",
	"sky-light": "float", "ambient-light": "float", "remove-caves-below-y": "int",
	"cave-detection-ocean-floor": "int", "cave-detection-uses-block-light": "bool",
	"min-inhabited-time": "int", "render-edges": "bool", "edge-light-strength": "int",
	"enable-perspective-view": "bool", "enable-flat-view": "bool", "enable-free-flight-view": "bool",
	"enable-hires": "bool", "ignore-missing-light-data": "bool",
}
## Defaults BlueMap uses for keys a map config leaves out.
const MAP_DEFAULTS := {
	"sorting": 0, "start-pos": {"x": 0, "z": 0}, "sky-color": "#7dabff", "void-color": "#000000",
	"sky-light": 1.0, "ambient-light": 0.0, "remove-caves-below-y": 55, "cave-detection-ocean-floor": 10000,
	"cave-detection-uses-block-light": false, "min-inhabited-time": 0, "render-edges": true,
	"edge-light-strength": 15, "enable-perspective-view": true, "enable-flat-view": true,
	"enable-free-flight-view": true, "enable-hires": true, "ignore-missing-light-data": false,
}
## Changing these needs the map rendered again (Force update).
const RERENDER_FIELDS: PackedStringArray = [
	"remove-caves-below-y", "cave-detection-ocean-floor", "cave-detection-uses-block-light",
	"min-inhabited-time", "render-edges", "edge-light-strength", "enable-hires", "ignore-missing-light-data",
]
## The keys of one render-mask box.
const MASK_KEYS: PackedStringArray = ["min-x", "max-x", "min-y", "max-y", "min-z", "max-z", "subtract"]
## Settings of core.conf, plugin.conf and webserver.conf the tab edits: name -> [file, key,
## type, default].
const SETTINGS := {
	"render-thread-count": ["core.conf", "render-thread-count", "int", 1],
	"update-cooldown": ["core.conf", "update-cooldown", "int", 60],
	"full-update-interval": ["core.conf", "full-update-interval", "int", 1440],
	"player-render-limit": ["plugin.conf", "player-render-limit", "int", -1],
	"live-player-markers": ["plugin.conf", "live-player-markers", "bool", true],
	"webserver-enabled": ["webserver.conf", "enabled", "bool", true],
	"webserver-port": ["webserver.conf", "port", "int", 8100],
}
## Seconds between BlueMap's writes of live players and markers to the map storage, where
## the viewer reads them (BlueMap's default, 0, serves them only through its web server).
const LIVE_INTERVALS := {"write-players-interval": 3, "write-markers-interval": 10}
## Render actions on a map and their commands.
const MAP_ACTIONS := {
	"update": "update", "fix-edges": "fix-edges", "force-update": "force-update",
	"freeze": "freeze", "unfreeze": "unfreeze", "purge": "purge",
}
## File-name suffixes of BlueMap's storage compressions (LZ4 can't be read here).
const COMPRESSIONS := {"gzip": ".gz", "deflate": ".deflate", "zstd": ".zst", "none": ""}

static var _re_colour := RegEx.create_from_string("§x(§[0-9A-Fa-f]){6}|§.")
static var _re_id := RegEx.create_from_string("^[A-Za-z0-9_\\-]{1,64}$")
static var _re_key := RegEx.create_from_string("^\\s*(\"[^\"]+\"|[A-Za-z0-9_.\\-]+)\\s*[:=]?\\s*(.*)$")
static var _re_web_path := RegEx.create_from_string("^(settings\\.json|textures\\.json(\\.gz|\\.deflate|\\.zst)?|live/(players|markers)\\.json|assets/[A-Za-z0-9_\\-/.]+\\.(png|svg|jpg)|tiles/0/x-?(\\d/)+z-?(\\d/)*\\d\\.prbm(\\.gz|\\.deflate|\\.zst)?|tiles/[1-9]/x-?(\\d/)+z-?(\\d/)*\\d\\.png)$")


static func installed_info(server_dir: String) -> Dictionary:
	return ServerOps.installed_plugin(server_dir, PLUGIN_NAME)


static func config_path(server_dir: String, file: String) -> String:
	return server_dir.path_join(CONFIG_DIR).path_join(file)


static func read_config(server_dir: String, file: String) -> String:
	return FileAccess.get_file_as_string(config_path(server_dir, file))


## Writes a config file. Returns "" or an error.
static func write_config(server_dir: String, file: String, text: String) -> String:
	var path := config_path(server_dir, file)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not write %s (%s)." % [file, error_string(FileAccess.get_open_error())]
	f.store_string(text)
	return ""


## Whether BlueMap has created its configs (it does on its first start).
static func has_configs(server_dir: String) -> bool:
	return FileAccess.file_exists(config_path(server_dir, "core.conf"))


static func download_accepted(server_dir: String) -> bool:
	return conf_get(read_config(server_dir, "core.conf"), "accept-download", false) == true


## Makes BlueMap write live players and markers to the map storage (see LIVE_INTERVALS).
## Returns true when plugin.conf changed (it applies on BlueMap's next reload).
static func ensure_live_files(server_dir: String) -> bool:
	var text := read_config(server_dir, "plugin.conf")
	var changed := false
	for key in LIVE_INTERVALS:
		if int(conf_get(text, key, 0)) <= 0:
			text = conf_set(text, key, LIVE_INTERVALS[key])
			changed = true
	return changed and write_config(server_dir, "plugin.conf", text) == ""


# --- HOCON (the subset BlueMap's configs use) -------------------------------------------

## The top-level entries of a config: [{key, first, last}] (line indices; a value may span
## several lines when it opens braces or brackets).
static func conf_entries(text: String) -> Array:
	var out := []
	var lines := text.split("\n")
	var depth := 0
	var current: Dictionary = {}
	for i in lines.size():
		var line := _strip_comment(lines[i])
		if depth == 0 and line.strip_edges() != "":
			var m := _re_key.search(line)
			if m != null:
				current = {"key": m.get_string(1).trim_prefix("\"").trim_suffix("\""), "first": i, "last": i}
				out.append(current)
		depth = maxi(depth + _depth_change(line), 0)
		if not current.is_empty():
			current.last = i
			if depth == 0:
				current = {}
	return out


## The value of top-level [param key] (bool, int, float, String, or {x, z} for a
## one-line object), or [param default].
static func conf_get(text: String, key: String, default: Variant = null) -> Variant:
	var raw: Variant = conf_raw(text, key)
	return default if raw == null else parse_value(str(raw))


## The text of the value of top-level [param key] (null when it isn't set).
static func conf_raw(text: String, key: String) -> Variant:
	var lines := text.split("\n")
	for e in conf_entries(text):
		if e.key == key:
			var parts := PackedStringArray()
			for i in range(e.first, e.last + 1):
				parts.append(_strip_comment(lines[i]))
			var m := _re_key.search(parts[0])
			parts[0] = m.get_string(2) if m != null else ""
			return "\n".join(parts).strip_edges()
	return null


## [param text] with top-level [param key] set to [param value] (encoded; see [method encode]),
## replacing the old value (all its lines) or adding the key at the end.
static func conf_set(text: String, key: String, value: Variant) -> String:
	var line := "%s: %s" % [key if _re_id.search(key) != null else JSON.stringify(key), encode(value)]
	var lines := text.split("\n")
	for e in conf_entries(text):
		if e.key == key:
			var out := PackedStringArray()
			out.append_array(lines.slice(0, e.first))
			out.append(line)
			out.append_array(lines.slice(e.last + 1))
			return "\n".join(out)
	return text + ("" if text == "" or text.ends_with("\n") else "\n") + line + "\n"


## HOCON text for a value: strings quoted, {x, z} as a one-line object, arrays of boxes as
## a render mask.
static func encode(value: Variant) -> String:
	if value is bool:
		return "true" if value else "false"
	if value is int:
		return str(value)
	if value is float:
		return str(int(value)) if value == floorf(value) and absf(value) < 1e15 else str(value)
	if value is Dictionary:
		var parts := PackedStringArray()
		for k in value:
			parts.append("%s: %s" % [k, encode(value[k])])
		return "{ %s }" % ", ".join(parts)
	if value is Array:
		return encode_masks(value)
	return JSON.stringify(str(value))


static func parse_value(raw: String) -> Variant:
	var s := raw.strip_edges()
	if s == "true" or s == "false":
		return s == "true"
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	if s.begins_with("\""):
		var parsed: Variant = JSON.parse_string(s)
		return str(parsed) if parsed != null else s.trim_prefix("\"").trim_suffix("\"")
	if s.begins_with("{") and s.ends_with("}") and not s.contains("\n"):
		var out := {}
		for part in s.substr(1, s.length() - 2).split(","):
			var m := _re_key.search(part)
			if m != null and m.get_string(2) != "":
				out[m.get_string(1)] = parse_value(m.get_string(2))
		return out
	return s


## A render-mask value as boxes: {ok, boxes: [{min-x, ..., subtract}]}; ok is false when it
## holds anything the box editor doesn't know (other mask types), which is then kept as is.
static func parse_masks(raw: Variant) -> Dictionary:
	if raw == null or str(raw).strip_edges() in ["", "[]"]:
		return {"ok": true, "boxes": []}
	var s := str(raw).strip_edges()
	if not s.begins_with("[") or not s.ends_with("]"):
		return {"ok": false, "boxes": []}
	var boxes := []
	var depth := 0
	var current: Dictionary = {}
	for line in s.substr(1, s.length() - 2).split("\n"):
		for part in _strip_comment(line).replace(",", "\n").split("\n"):
			var t := part.strip_edges()
			while t.begins_with("{"):
				if depth > 0:
					return {"ok": false, "boxes": []}
				depth += 1
				current = {}
				t = t.substr(1).strip_edges()
			var closes := t.ends_with("}")
			t = t.trim_suffix("}").strip_edges()
			if t != "":
				if depth != 1:
					return {"ok": false, "boxes": []}
				var m := _re_key.search(t)
				if m == null or not MASK_KEYS.has(m.get_string(1)):
					return {"ok": false, "boxes": []}
				current[m.get_string(1)] = parse_value(m.get_string(2))
			if closes:
				depth -= 1
				if not current.is_empty():
					boxes.append(current)
				current = {}
	return {"ok": depth == 0, "boxes": boxes}


static func encode_masks(boxes: Array) -> String:
	var parts := PackedStringArray()
	for box in boxes:
		if not box is Dictionary:
			continue
		var lines := PackedStringArray()
		for k in MASK_KEYS:
			if box.has(k) and box[k] != null:
				lines.append("    %s: %s" % [k, encode(box[k])])
		parts.append("  {\n%s\n  }" % "\n".join(lines) if not lines.is_empty() else "  {\n  }")
	return "[\n%s\n]" % "\n".join(parts) if not parts.is_empty() else "[\n  {\n  }\n]"


static func _strip_comment(line: String) -> String:
	var in_string := false
	for i in line.length():
		var c := line[i]
		if c == "\"" and (i == 0 or line[i - 1] != "\\"):
			in_string = not in_string
		elif not in_string and (c == "#" or (c == "/" and i + 1 < line.length() and line[i + 1] == "/")):
			return line.substr(0, i)
	return line


static func _depth_change(line: String) -> int:
	var d := 0
	var in_string := false
	for i in line.length():
		var c := line[i]
		if c == "\"" and (i == 0 or line[i - 1] != "\\"):
			in_string = not in_string
		elif not in_string:
			if c == "{" or c == "[":
				d += 1
			elif c == "}" or c == "]":
				d -= 1
	return d


# --- Maps -------------------------------------------------------------------------------

static func valid_id(id: String) -> bool:
	return _re_id.search(id) != null


static func map_ids(server_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(config_path(server_dir, "maps")):
		return out
	for file in DirAccess.get_files_at(config_path(server_dir, "maps")):
		if file.ends_with(".conf") and valid_id(file.get_basename()):
			out.append(file.get_basename())
	return out


## One map's settings: {id, world, dimension, values: {MAP_FIELDS key: value},
## masks: {ok, boxes}}.
static func map_config(server_dir: String, id: String) -> Dictionary:
	var text := read_config(server_dir, "maps/%s.conf" % id)
	var values := {}
	for key in MAP_FIELDS:
		values[key] = conf_get(text, key, MAP_DEFAULTS.get(key, id if key == "name" else null))
	return {
		"id": id, "world": str(conf_get(text, "world", "")), "dimension": str(conf_get(text, "dimension", "minecraft:overworld")),
		"storage": str(conf_get(text, "storage", "file")), "values": values, "masks": parse_masks(conf_raw(text, "render-mask")),
	}


## [param text] (a map config) with [param values] (MAP_FIELDS keys) and, when given,
## render-mask [param boxes] applied. Unknown keys and badly typed values are ignored.
static func apply_map_values(text: String, values: Dictionary, boxes: Variant = null) -> String:
	for key in values:
		if not MAP_FIELDS.has(key):
			continue
		var v: Variant = _typed(values[key], MAP_FIELDS[key])
		if v != null:
			text = conf_set(text, key, v)
	if boxes is Array:
		var clean := []
		for box in boxes:
			if box is Dictionary:
				var b := {}
				for k in MASK_KEYS:
					if box.get(k) != null and str(box.get(k)) != "":
						b[k] = bool(box[k]) if k == "subtract" else int(box[k])
				if b.get("subtract", false) == false:
					b.erase("subtract")
				clean.append(b)
		text = conf_set(text, "render-mask", clean)
	return text


static func _typed(value: Variant, type: String) -> Variant:
	match type:
		"string":
			return str(value).left(200)
		"int":
			return int(value) if (value is int or value is float or str(value).is_valid_int()) else null
		"float":
			return clampf(float(value), 0.0, 1.0) if (value is int or value is float or str(value).is_valid_float()) else null
		"bool":
			return bool(value) if value is bool else null
		"color":
			var c := str(value)
			return c if RegEx.create_from_string("^#[0-9A-Fa-f]{6}$").search(c) != null else null
		"pos":
			return {"x": int(value.get("x", 0)), "z": int(value.get("z", 0))} if value is Dictionary else null
	return null


## The config of a new map of [param dimension] in the world folder [param world].
static func new_map_text(world: String, dimension: String, name: String, sorting: int) -> String:
	var text := "world: %s\ndimension: %s\nname: %s\nsorting: %d\nstorage: \"file\"\n" % [
			JSON.stringify(world), JSON.stringify(dimension), JSON.stringify(name), sorting]
	if dimension == "minecraft:the_nether":
		text += "sky-color: \"#290000\"\nvoid-color: \"#150000\"\nambient-light: 0.6\nremove-caves-below-y: -10000\n"
		text += "render-mask: [\n  {\n  }\n  {\n    subtract: true\n    min-y: 90\n    max-y: 127\n  }\n]\n"
	elif dimension == "minecraft:the_end":
		text += "sky-color: \"#080010\"\nvoid-color: \"#080010\"\nambient-light: 0.6\nremove-caves-below-y: -10000\n"
	else:
		text += "ambient-light: 0.1\nremove-caves-below-y: 55\ncave-detection-ocean-floor: -5\n"
	return text


## The dimensions of the active world a map can show: [{dimension, label, id}] (id: a free
## suggestion for the map's name).
static func dimensions(server_dir: String, level: String) -> Array:
	var out := [{"dimension": "minecraft:overworld", "label": "Overworld", "id": level},
			{"dimension": "minecraft:the_nether", "label": "Nether", "id": level + "_the_nether"},
			{"dimension": "minecraft:the_end", "label": "End", "id": level + "_the_end"}]
	var root := server_dir.path_join(level).path_join("dimensions")
	var keys := []
	for ns in DirAccess.get_directories_at(root) if DirAccess.dir_exists_absolute(root) else PackedStringArray():
		for d in DirAccess.get_directories_at(root.path_join(ns)):
			keys.append("%s:%s" % [ns, d])
	keys.sort()
	for key in keys:
		if key not in ["minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"]:
			out.append({"dimension": key, "label": key, "id": "%s_%s" % [level, key.get_slice(":", 1)]})
	return out


# --- Where the rendered map is ------------------------------------------------------------

## Where map [param id] is stored: {ok, root (absolute), suffix (of compressed files)} or
## {ok: false, error} for storages the viewer can't read (SQL, LZ4).
static func map_storage(server_dir: String, id: String) -> Dictionary:
	var storage := str(conf_get(read_config(server_dir, "maps/%s.conf" % id), "storage", "file"))
	if not valid_id(storage):
		return {"ok": false, "error": "Unknown storage."}
	var text := read_config(server_dir, "storages/%s.conf" % storage)
	var type := str(conf_get(text, "storage-type", "file")).trim_prefix("bluemap:")
	if type != "file":
		return {"ok": false, "error": "This map is stored in a database (%s); the viewer reads maps stored as files." % type}
	var compression := str(conf_get(text, "compression", "gzip")).trim_prefix("bluemap:")
	if not COMPRESSIONS.has(compression):
		return {"ok": false, "error": "This map's storage uses %s compression, which the viewer can't read. Use gzip in plugins/BlueMap/storages/%s.conf." % [compression, storage]}
	var root := str(conf_get(text, "root", "bluemap/web/maps"))
	if not root.is_absolute_path():
		root = server_dir.path_join(root)
	return {"ok": true, "root": root.simplify_path().path_join(id), "suffix": COMPRESSIONS[compression]}


## The path of a tile below a map's root: hires (lod 0) .prbm<suffix>, lowres .png.
static func tile_path(lod: int, x: int, z: int, suffix := ".gz") -> String:
	return "tiles/%d/%s%s" % [lod, path_from_coords(x, z), ".prbm" + suffix if lod == 0 else ".png"]


## BlueMap's tile path: each digit a folder, "x-1/2/z3" for (-12, 3).
static func path_from_coords(x: int, z: int) -> String:
	return ("x" + _split_number(x) + "z" + _split_number(z)).trim_suffix("/")


static func _split_number(n: int) -> String:
	var out := "-" if n < 0 else ""
	for c in str(absi(n)):
		out += c + "/"
	return out


## Whether [param path] (below a map's root) is a file the viewer may read.
static func valid_web_path(path: String) -> bool:
	return not path.contains("..") and _re_web_path.search(path) != null


# --- Commands and replies -----------------------------------------------------------------

static func plain(text: String) -> String:
	return _re_colour.sub(text, "", true).strip_edges()


## "bluemap" (status): {loaded, loading, threads: "running"|"idle"|"stopped"|"paused"|"",
## thread_count, current: the task being rendered ("" if none)}.
static func parse_status(text: String) -> Dictionary:
	var t := plain(text)
	var out := {"loaded": true, "loading": false, "threads": "", "thread_count": 0, "current": ""}
	if t.contains("BlueMap is still loading"):
		return {"loaded": false, "loading": true, "threads": "", "thread_count": 0, "current": ""}
	if t.contains("BlueMap is not loaded"):
		return {"loaded": false, "loading": false, "threads": "", "thread_count": 0, "current": ""}
	var m := RegEx.create_from_string("render-threads? (?:are|is) (stopped|paused)").search(t)
	if m != null:
		out.threads = m.get_string(1)
	m = RegEx.create_from_string("(\\d+) render-threads? (?:are|is) (idle|running)").search(t)
	if m != null:
		out.thread_count = m.get_string(1).to_int()
		out.threads = m.get_string(2)
	m = RegEx.create_from_string("⛏ (map \\S+ is currently being \\w+)").search(t)
	if m != null:
		out.current = m.get_string(1)
	return out


## "bluemap maps": map id -> {state: "updated"|"rendering"|"purging"|"pending"|"frozen",
## progress (0..1, while rendering), pending (task count), frozen}.
static func parse_maps(text: String) -> Dictionary:
	var out := {}
	var current := ""
	for raw in plain(text).split("\n"):
		var line := raw.strip_edges()
		var m := RegEx.create_from_string("^(✔|❄|⌛|⛏)\\s+(\\S+)$").search(line)
		if m != null:
			current = m.get_string(2)
			out[current] = {"state": {"✔": "updated", "❄": "frozen", "⌛": "pending", "⛏": "rendering"}[m.get_string(1)],
					"progress": 0.0, "pending": 0, "frozen": m.get_string(1) == "❄"}
			continue
		if current == "":
			continue
		m = RegEx.create_from_string("is currently being (updated|purged): ([\\d.]+)%").search(line)
		if m != null:
			out[current].state = "rendering" if m.get_string(1) == "updated" else "purging"
			out[current].progress = m.get_string(2).to_float() / 100.0
		m = RegEx.create_from_string("has a running task: ([\\d.]+)%").search(line)
		if m != null:
			out[current].progress = m.get_string(1).to_float() / 100.0
		m = RegEx.create_from_string("has (\\d+) pending tasks?").search(line)
		if m != null:
			out[current].pending = m.get_string(1).to_int()
		if line.contains("is frozen"):
			out[current].frozen = true
	return out


## "bluemap tasks": [{state: "done"|"running"|"pending", ref, text}] (ref cancels a pending one).
static func parse_tasks(text: String) -> Array:
	var out := []
	for raw in plain(text).split("\n"):
		var line := raw.strip_edges()
		var m := RegEx.create_from_string("^✔ \\(done\\) (.+)$").search(line)
		if m != null:
			out.append({"state": "done", "ref": "", "text": m.get_string(1)})
			continue
		m = RegEx.create_from_string("^(⛏|⌛) \\[([^\\]]+)\\] (.+?)( \\.\\.\\.)?$").search(line)
		if m != null:
			out.append({"state": "running" if m.get_string(1) == "⛏" else "pending", "ref": m.get_string(2), "text": m.get_string(3)})
	return out


## The command for a render action on map [param id]; update, fix-edges and force-update
## take an optional area {x, z, radius}. {ok, command, text} or {ok: false, error}.
static func action_command(action: String, id: String, area := {}) -> Dictionary:
	if not MAP_ACTIONS.has(action):
		return {"ok": false, "error": "Unknown action."}
	if not valid_id(id):
		return {"ok": false, "error": "Unknown map."}
	var command := "bluemap %s %s" % [MAP_ACTIONS[action], id]
	var where := ""
	if action in ["update", "fix-edges", "force-update"] and not area.is_empty():
		var radius := clampi(int(area.get("radius", 0)), 1, 30_000_000)
		var x := clampi(int(area.get("x", 0)), -30_000_000, 30_000_000)
		var z := clampi(int(area.get("z", 0)), -30_000_000, 30_000_000)
		command += " %d %d %d" % [x, z, radius]
		where = " within %d blocks of %d, %d" % [radius, x, z]
	var verb: String = {"update": "update", "fix-edges": "fix the edges of", "force-update": "re-render",
			"freeze": "freeze", "unfreeze": "unfreeze", "purge": "delete the render of"}[action]
	return {"ok": true, "command": command, "text": "%s %s%s" % [verb, id, where]}


## A free webserver port: [param wanted] unless another server's BlueMap uses it.
static func free_port(wanted: int, taken: Array) -> int:
	var port := wanted
	while taken.has(port):
		port += 1
	return port


## The webserver port BlueMap is set to on a server (0 when its webserver is off or unset).
static func webserver_port(server_dir: String) -> int:
	var text := read_config(server_dir, "webserver.conf")
	if text == "" or conf_get(text, "enabled", true) == false:
		return 0
	return int(conf_get(text, "port", DEFAULT_PORT))
