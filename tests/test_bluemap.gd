extends TestCase

const MAP_CONF := """##  BlueMap  ##
# The path to the save folder of the world to render.
world: "world"
dimension: "minecraft:the_nether"
name: "world (the_nether)" # shown in the menu
sorting: 100
start-pos: { x: 0, z: 0 }
sky-color: "#290000"
ambient-light: 0.6
render-mask: [
  {
  }
  {
    subtract: true
    min-y: 90
    max-y: 127
  }
]
render-edges: true
marker-sets: {
  # see the wiki
}
"""


func test_reads_and_writes_hocon() -> void:
	check_eq(BlueMap.conf_get(MAP_CONF, "name"), "world (the_nether)", "quoted string, comment after it ignored")
	check_eq(BlueMap.conf_get(MAP_CONF, "sorting"), 100, "int")
	check_eq(BlueMap.conf_get(MAP_CONF, "ambient-light"), 0.6, "float")
	check_eq(BlueMap.conf_get(MAP_CONF, "render-edges"), true, "bool")
	check_eq(BlueMap.conf_get(MAP_CONF, "start-pos"), {"x": 0, "z": 0}, "one-line object")
	check_eq(BlueMap.conf_get(MAP_CONF, "min-y", "none"), "none", "keys inside blocks aren't top-level")
	var keys := BlueMap.conf_entries(MAP_CONF).map(func(e: Dictionary) -> String: return e.key)
	check_eq(keys, ["world", "dimension", "name", "sorting", "start-pos", "sky-color", "ambient-light", "render-mask", "render-edges", "marker-sets"], "top-level keys")
	var changed := BlueMap.conf_set(MAP_CONF, "render-mask", [{"min-x": -100, "max-x": 100}])
	check_eq(BlueMap.parse_masks(BlueMap.conf_raw(changed, "render-mask")).boxes, [{"min-x": -100, "max-x": 100}], "a multi-line value replaced whole")
	check_eq(BlueMap.conf_get(changed, "render-edges"), true, "the keys after it survive")
	changed = BlueMap.conf_set(changed, "accept-download", true)
	check(changed.ends_with("accept-download: true\n"), "a missing key is added")
	check_eq(BlueMap.conf_get(BlueMap.conf_set(MAP_CONF, "name", "Nether \"hot\""), "name"), "Nether \"hot\"", "strings escaped")


func test_reads_render_masks() -> void:
	var masks := BlueMap.parse_masks(BlueMap.conf_raw(MAP_CONF, "render-mask"))
	check(masks.ok, "box masks understood")
	check_eq(masks.boxes, [{"subtract": true, "min-y": 90, "max-y": 127}], "an empty box is no limit; the subtracted box is kept")
	check(not BlueMap.parse_masks("[\n  {\n    type: \"circle\"\n    radius: 10\n  }\n]").ok, "other mask types are left alone")
	check(BlueMap.parse_masks("[\n  {\n    #min-x: -4000\n  }\n]").ok, "the default (commented) template")
	var text := BlueMap.apply_map_values(MAP_CONF, {"name": "Hell", "sky-light": 3, "sky-color": "red", "bogus": 1},
			[{"min-x": "-50", "max-x": 50, "min-y": "", "subtract": false}])
	check_eq(BlueMap.conf_get(text, "name"), "Hell", "name set")
	check_eq(BlueMap.conf_get(text, "sky-light"), 1, "light clamped to 0..1")
	check_eq(BlueMap.conf_get(text, "sky-color"), "#290000", "an invalid colour is ignored")
	check_eq(BlueMap.conf_get(text, "bogus", "unset"), "unset", "unknown keys ignored")
	check_eq(BlueMap.parse_masks(BlueMap.conf_raw(text, "render-mask")).boxes, [{"min-x": -50, "max-x": 50}], "empty limits dropped")


func test_parses_replies() -> void:
	var status := BlueMap.parse_status("§fBlueMap Status §7>\n §a✔ §e1§a render-thread is §eidle\n §7 └ last active 3 minutes ago")
	check(status.loaded and status.threads == "idle" and status.thread_count == 1, "idle: %s" % status)
	status = BlueMap.parse_status("BlueMap Status >\n ❌ render-threads are stopped\n └ use /bluemap start to start rendering")
	check_eq(status.threads, "stopped", "stopped")
	check(BlueMap.parse_status("⌛ BlueMap is still loading!").loading, "loading")
	check(not BlueMap.parse_status("❌ BlueMap is not loaded!\nCheck your server-console").loaded, "not loaded")
	var maps := BlueMap.parse_maps("BlueMap Maps >\n ⛏ world\n └ is currently being updated: 69.723%\n ⌛ world_the_nether\n └ has 1 pending task\n ❄ world_the_end\n └ is frozen")
	check_eq(maps.world.state, "rendering", "rendering")
	check(is_equal_approx(maps.world.progress, 0.69723), "progress")
	check(maps.world_the_nether.state == "pending" and maps.world_the_nether.pending == 1, "pending")
	check(maps.world_the_end.frozen, "frozen")
	var tasks := BlueMap.parse_tasks("BlueMap Tasks >\n ✔ (done) preparing map 'world' update\n ⛏ [ab12] updating map 'world' ...\n ⌛ [cd34] updating map 'world_the_end'")
	check_eq(tasks, [{"state": "done", "ref": "", "text": "preparing map 'world' update"},
			{"state": "running", "ref": "ab12", "text": "updating map 'world'"},
			{"state": "pending", "ref": "cd34", "text": "updating map 'world_the_end'"}], "tasks")


func test_builds_commands_and_paths() -> void:
	check_eq(BlueMap.action_command("update", "world").command, "bluemap update world", "whole map")
	check_eq(BlueMap.action_command("force-update", "world", {"x": 10, "z": -20, "radius": 50}).command, "bluemap force-update world 10 -20 50", "an area")
	check_eq(BlueMap.action_command("purge", "world", {"x": 1, "z": 1, "radius": 1}).command, "bluemap purge world", "purge takes no area")
	check(not BlueMap.action_command("update", "world; op me").ok, "map names are checked")
	check(not BlueMap.action_command("delete", "world").ok, "unknown actions refused")
	check_eq(BlueMap.path_from_coords(-12, 3), "x-1/2/z3", "BlueMap's tile path")
	check_eq(BlueMap.tile_path(0, 2, -1), "tiles/0/x2/z-1.prbm.gz", "hires")
	check_eq(BlueMap.tile_path(2, -2, 0), "tiles/2/x-2/z0.png", "lowres")
	check(BlueMap.valid_web_path("tiles/0/x-1/2/z3.prbm.gz") and BlueMap.valid_web_path("live/players.json")
			and BlueMap.valid_web_path("textures.json.gz") and BlueMap.valid_web_path("assets/playerheads/0a1b-2c.png"), "map files allowed")
	check(not BlueMap.valid_web_path("../../server.properties") and not BlueMap.valid_web_path("tiles/0/../../x.png")
			and not BlueMap.valid_web_path("rstate/x0/z0.tiles.dat"), "nothing else")
	check_eq(BlueMap.free_port(8100, [8100, 8101, 0]), 8102, "next free web port")


func test_dimensions_and_storage() -> void:
	var dir := ProjectSettings.globalize_path("user://test-bluemap-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir.path_join("survival/dimensions/minecraft/erebor"))
	var dims := BlueMap.dimensions(dir, "survival")
	check_eq(dims.map(func(d: Dictionary) -> String: return d.dimension), ["minecraft:overworld", "minecraft:the_nether", "minecraft:the_end", "minecraft:erebor"], "dimensions")
	check_eq(dims[3].id, "survival_erebor", "suggested map name")
	_write(dir.path_join("plugins/BlueMap/maps/world.conf"), "world: \"survival\"\nstorage: \"file\"\n")
	var st := BlueMap.map_storage(dir, "world")
	check(st.ok and st.root == dir.path_join("bluemap/web/maps/world") and st.suffix == ".gz", "default file storage: %s" % st)
	_write(dir.path_join("plugins/BlueMap/storages/file.conf"), "storage-type: file\nroot: \"maps\"\ncompression: none\n")
	st = BlueMap.map_storage(dir, "world")
	check(st.ok and st.root == dir.path_join("maps/world") and st.suffix == "", "its root and compression: %s" % st)
	_write(dir.path_join("plugins/BlueMap/maps/sql.conf"), "storage: \"sql\"\n")
	_write(dir.path_join("plugins/BlueMap/storages/sql.conf"), "storage-type: sql\n")
	check(not BlueMap.map_storage(dir, "sql").ok, "a database can't be viewed")
	check_eq(BlueMap.map_ids(dir), PackedStringArray(["sql", "world"]) if BlueMap.map_ids(dir)[0] == "sql" else PackedStringArray(["world", "sql"]), "maps listed")
	var conf := BlueMap.new_map_text("survival", "minecraft:the_nether", "Nether", 100)
	check(BlueMap.parse_masks(BlueMap.conf_raw(conf, "render-mask")).boxes.size() == 1, "a new nether map hides the roof")
	FileOps.remove_tree(dir)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	FileAccess.open(path, FileAccess.WRITE).store_string(text)
