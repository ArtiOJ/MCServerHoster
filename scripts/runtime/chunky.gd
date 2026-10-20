class_name Chunky
extends RefCounted
## Chunky (chunk pre-generation plugin) for the Chunky tab: builds its commands from a task
## description and follows its progress in the server's console. Verified with Chunky 1.5 on
## Paper 26.3: commands answer over RCON; progress is logged once per "quiet" interval as
## "[Chunky] Task running for <world>. Processed: <n> chunks (<p>%), ETA: <h:mm:ss>, Rate:
## <r> cps, Current: <x>, <z>"; the "world" pattern visits only chunks that already exist
## (scanning region files), which is how a map surrounded by void is loaded without
## generating anything new. Worlds are named the Bukkit way (world, world_nether, ...).

const PLUGIN_NAME := "Chunky"
const MODRINTH_ID := "fALzjamp"
const SHAPES: PackedStringArray = ["square", "circle", "rectangle", "ellipse", "diamond", "pentagon", "hexagon", "star", "triangle"]
const SHAPE_NAMES: PackedStringArray = ["Square", "Circle", "Rectangle", "Ellipse", "Diamond", "Pentagon", "Hexagon", "Star", "Triangle"]
## Shapes with separate X and Z radii.
const TWO_RADII: PackedStringArray = ["rectangle", "ellipse"]
enum Mode { AREA, BORDER, EXISTING }
const MODE_NAMES: PackedStringArray = ["Generate an area", "Fill the world border", "Load existing chunks only"]
enum Center { SPAWN, BORDER, COORDINATES }
const CENTER_NAMES: PackedStringArray = ["World spawn", "World border centre", "Coordinates"]
## Chunky's limit (the world's).
const MAX_RADIUS := 30_000_000
## Seconds between progress lines while a task runs.
const PROGRESS_INTERVAL := 2

static var _re_running := RegEx.create_from_string("\\[Chunky\\] Task running for (\\S+)\\. Processed: (\\d+) (chunks|regions) \\(([\\d.]+)%\\)(?:, ETA: ([\\d:]+), Rate: ([\\d.]+) cps, Current: (-?\\d+), (-?\\d+))?")
static var _re_finished := RegEx.create_from_string("\\[Chunky\\] Task finished for (\\S+)\\. Processed: (\\d+) (chunks|regions) \\(([\\d.]+)%\\), Total time: ([\\d:]+)")
static var _re_state := RegEx.create_from_string("\\[Chunky\\] Task (started|stopped|paused|continuing|cancelled) (?:in|for) ([^\\s.]+)")
static var _re_world := RegEx.create_from_string("^[A-Za-z0-9_.\\-]{1,64}$")


static func installed_info(server_dir: String) -> Dictionary:
	return ServerOps.installed_plugin(server_dir, PLUGIN_NAME)


## The worlds Chunky can work on, from the active world's dimensions: [{name, label}], where
## name is the Bukkit world name Paper gives each dimension.
static func worlds(server_dir: String, level: String) -> Array:
	var out := [{"name": level, "label": "Overworld"}]
	var root := server_dir.path_join(level).path_join("dimensions")
	var found := {}
	for ns in DirAccess.get_directories_at(root):
		for d in DirAccess.get_directories_at(root.path_join(ns)):
			found["%s:%s" % [ns, d]] = true
	if found.is_empty() or found.has("minecraft:the_nether") or DirAccess.dir_exists_absolute(server_dir.path_join(level + "_nether")):
		out.append({"name": level + "_nether", "label": "Nether"})
	if found.is_empty() or found.has("minecraft:the_end") or DirAccess.dir_exists_absolute(server_dir.path_join(level + "_the_end")):
		out.append({"name": level + "_the_end", "label": "End"})
	var keys := found.keys()
	keys.sort()
	for key in keys:
		if key in ["minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"]:
			continue
		out.append({"name": "%s_%s" % [level, key.replace(":", "_")], "label": key})
	return out


## The commands for a new task. [param task]: {world, mode (Mode), shape, center (Center),
## x, z, radius, radius_z}. Returns {ok, commands, text} or {ok: false, error}.
static func start_commands(task: Dictionary) -> Dictionary:
	var world := str(task.get("world", ""))
	if _re_world.search(world) == null:
		return {"ok": false, "error": "Choose a world."}
	var commands := ["chunky world " + world, "chunky quiet %d" % PROGRESS_INTERVAL]
	var text := ""
	match int(task.get("mode", Mode.AREA)):
		Mode.EXISTING:
			# The whole world, visiting only chunks that already exist.
			commands.append_array(["chunky pattern world", "chunky shape square", "chunky center 0 0", "chunky radius %d" % MAX_RADIUS])
			text = "load the existing chunks of %s" % world
		Mode.BORDER:
			commands.append_array(["chunky pattern region", "chunky worldborder"])
			text = "fill the world border of %s" % world
		_:
			var selection := selection_commands(task)
			if not selection.ok:
				return selection
			commands.append("chunky pattern region")
			commands.append_array(selection.commands)
			text = "generate %s" % selection.text
	commands.append("chunky start")
	return {"ok": true, "commands": commands, "text": text}


## Shape, centre and radius commands for an area. {ok, commands, text} or {ok: false, error}.
static func selection_commands(task: Dictionary) -> Dictionary:
	var shape := str(task.get("shape", "square"))
	if not SHAPES.has(shape):
		return {"ok": false, "error": "Unknown shape."}
	var radius := int(task.get("radius", 0))
	var radius_z := int(task.get("radius_z", radius))
	if radius < 1 or radius > MAX_RADIUS or (TWO_RADII.has(shape) and (radius_z < 1 or radius_z > MAX_RADIUS)):
		return {"ok": false, "error": "The radius must be between 1 and %d blocks." % MAX_RADIUS}
	var commands := ["chunky shape " + shape]
	var where := ""
	match int(task.get("center", Center.SPAWN)):
		Center.BORDER:
			# worldborder also sets a radius; the one asked for is set after it.
			commands.append("chunky worldborder")
			where = "the world border centre"
		Center.COORDINATES:
			var x := clampi(int(task.get("x", 0)), -MAX_RADIUS, MAX_RADIUS)
			var z := clampi(int(task.get("z", 0)), -MAX_RADIUS, MAX_RADIUS)
			commands.append("chunky center %d %d" % [x, z])
			where = "%d, %d" % [x, z]
		_:
			commands.append("chunky spawn")
			where = "spawn"
	commands.append("chunky radius %d" % radius + (" %d" % radius_z if TWO_RADII.has(shape) else ""))
	var size := "%d × %d" % [radius, radius_z] if TWO_RADII.has(shape) else str(radius)
	return {"ok": true, "commands": commands, "text": "a %s of radius %s blocks around %s in %s" % [shape, size, where, task.get("world", "")]}


## The commands that delete chunks outside (or inside) an area, confirmed. Outside uses the
## selection as set (spawn, border centre or coordinates); inside has to spell the area out in
## the trim command, which takes coordinates only. {ok, commands, text} or {ok: false, error}.
static func trim_commands(task: Dictionary) -> Dictionary:
	var world := str(task.get("world", ""))
	if _re_world.search(world) == null:
		return {"ok": false, "error": "Choose a world."}
	var selection := selection_commands(task)
	if not selection.ok:
		return selection
	var inside := bool(task.get("inside", false))
	var commands := ["chunky world " + world]
	commands.append_array(selection.commands)
	if inside:
		if int(task.get("center", Center.SPAWN)) != Center.COORDINATES:
			return {"ok": false, "error": "Trimming inside an area needs its centre as coordinates."}
		var shape := str(task.get("shape", "square"))
		var radius := int(task.get("radius", 1))
		var second := (" %d" % int(task.get("radius_z", radius))) if TWO_RADII.has(shape) else ""
		commands.append("chunky trim %s %s %d %d %d%s inside" % [world, shape, int(task.x), int(task.z), radius, second])
	else:
		commands.append("chunky trim")
	commands.append("chunky confirm")
	return {"ok": true, "commands": commands, "text": "delete the chunks %s %s" % ["inside" if inside else "outside", selection.text]}


## Updates [param tasks] (world -> state) from one console line. Returns true when a task's
## state changed (started, paused, finished, ...), false for progress or other lines.
static func track(tasks: Dictionary, line: String) -> bool:
	if not line.contains("[Chunky]"):
		return false
	var m := _re_running.search(line)
	if m != null:
		var t: Dictionary = tasks.get(m.get_string(1), {})
		var changed: bool = t.get("state", "") != "running"
		t.merge({"state": "running", "processed": m.get_string(2).to_int(), "unit": m.get_string(3),
				"percent": m.get_string(4).to_float(), "eta": m.get_string(5), "rate": m.get_string(6).to_float(),
				"current": "%s, %s" % [m.get_string(7), m.get_string(8)] if m.get_string(7) != "" else ""}, true)
		tasks[m.get_string(1)] = t
		return changed
	m = _re_finished.search(line)
	if m != null:
		tasks[m.get_string(1)] = {"state": "finished", "processed": m.get_string(2).to_int(), "unit": m.get_string(3),
				"percent": m.get_string(4).to_float(), "total_time": m.get_string(5), "eta": "", "rate": 0.0, "current": ""}
		return true
	m = _re_state.search(line)
	if m != null:
		var world := m.get_string(2)
		if m.get_string(1) == "cancelled":
			tasks.erase(world)  # Gone for good, progress included.
			return true
		var state: String = {"started": "running", "stopped": "paused", "paused": "paused", "continuing": "running"}[m.get_string(1)]
		# Only a start creates a task: a cancelled task's thread still logs "stopped" afterwards.
		if m.get_string(1) != "started" and not tasks.has(world):
			return false
		var t: Dictionary = tasks.get(world, {})
		if m.get_string(1) == "started":
			t = {"processed": 0, "unit": "chunks", "percent": 0.0, "eta": "", "rate": 0.0, "current": ""}
		t.state = state
		tasks[world] = t
		return true
	return false
