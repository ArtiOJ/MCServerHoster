extends TestCase


func test_builds_start_commands() -> void:
	var area := Chunky.start_commands({"world": "world", "mode": Chunky.Mode.AREA, "shape": "circle", "center": Chunky.Center.COORDINATES, "x": 100, "z": -50, "radius": 2000})
	check_eq(area.commands, ["chunky world world", "chunky quiet 2", "chunky pattern region", "chunky shape circle", "chunky center 100 -50", "chunky radius 2000", "chunky start"], "an area")
	var rect := Chunky.start_commands({"world": "world", "mode": Chunky.Mode.AREA, "shape": "rectangle", "center": Chunky.Center.SPAWN, "radius": 1000, "radius_z": 500})
	check(rect.commands.has("chunky spawn") and rect.commands.has("chunky radius 1000 500"), "two radii, around spawn")
	var border := Chunky.start_commands({"world": "world_nether", "mode": Chunky.Mode.BORDER})
	check_eq(border.commands, ["chunky world world_nether", "chunky quiet 2", "chunky pattern region", "chunky worldborder", "chunky start"], "the world border")
	var existing := Chunky.start_commands({"world": "world", "mode": Chunky.Mode.EXISTING})
	check(existing.commands.has("chunky pattern world") and existing.commands.has("chunky radius 30000000"), "existing chunks only: the world pattern over the whole world")
	for bad in [{"world": "world; op me", "mode": 0, "shape": "square", "radius": 10}, {"world": "", "mode": 0},
			{"world": "world", "mode": 0, "shape": "blob", "radius": 10}, {"world": "world", "mode": 0, "shape": "square", "radius": 0},
			{"world": "world", "mode": 0, "shape": "square", "radius": 40000000}]:
		check(not Chunky.start_commands(bad).ok, "refused: %s" % bad)


func test_builds_trim_commands() -> void:
	var outside := Chunky.trim_commands({"world": "world", "shape": "square", "center": Chunky.Center.SPAWN, "radius": 500})
	check_eq(outside.commands.slice(-2), ["chunky trim", "chunky confirm"], "outside uses the selection, then confirms")
	var inside := Chunky.trim_commands({"world": "world", "shape": "ellipse", "center": Chunky.Center.COORDINATES, "x": 5, "z": 6, "radius": 100, "radius_z": 50, "inside": true})
	check(inside.commands.has("chunky trim world ellipse 5 6 100 50 inside"), "inside spells the area out: %s" % [inside.commands])
	check(not Chunky.trim_commands({"world": "world", "shape": "square", "center": Chunky.Center.SPAWN, "radius": 100, "inside": true}).ok, "inside needs coordinates")


func test_follows_progress() -> void:
	var tasks := {}
	check(Chunky.track(tasks, "[07:06:20 INFO]: [Chunky] Task started in world for the square region centered at 0, 0 with radius 160."), "started")
	check(not Chunky.track(tasks, "[07:06:23 INFO]: [Chunky] Task running for world. Processed: 111 chunks (25.17%), ETA: 0:00:03, Rate: 99.6 cps, Current: 1, -1"), "progress isn't a state change")
	check(tasks.world.state == "running" and tasks.world.processed == 111 and is_equal_approx(tasks.world.percent, 25.17) and tasks.world.eta == "0:00:03", "progress read: %s" % tasks.world)
	check(Chunky.track(tasks, "[07:06:25 INFO]: [Chunky] Task stopped for world."), "stopped")
	check_eq(tasks.world.state, "paused", "a stopped task can continue")
	Chunky.track(tasks, "[07:06:40 INFO]: [Chunky] Task running for world_nether. Processed: 4 regions (100.00%)")
	check_eq(tasks.world_nether.unit, "regions", "the world pattern counts regions")
	check(Chunky.track(tasks, "[07:06:41 INFO]: [Chunky] Task finished for world. Processed: 441 chunks (100.00%), Total time: 0:00:03"), "finished")
	check(tasks.world.state == "finished" and tasks.world.total_time == "0:00:03", "finished read")
	check(not Chunky.track(tasks, "[07:06:41 INFO]: Done (3.2s)! For help, type \"help\""), "other lines ignored")
	check(Chunky.track(tasks, "[07:07:00 INFO]: [Chunky] Task cancelled for world_nether.") and not tasks.has("world_nether"), "a cancelled task disappears")
	check(not Chunky.track(tasks, "[07:07:01 INFO]: [Chunky] Task stopped for world_nether.") and not tasks.has("world_nether"), "and its thread stopping doesn't bring it back")


func test_names_worlds_like_paper() -> void:
	var dir := ProjectSettings.globalize_path("user://test-chunky-%d" % Time.get_ticks_usec())
	for d in ["overworld", "the_nether", "islands"]:
		DirAccess.make_dir_recursive_absolute(dir.path_join("survival/dimensions/minecraft").path_join(d))
	var names := Chunky.worlds(dir, "survival").map(func(w: Dictionary) -> String: return w.name)
	check_eq(names, ["survival", "survival_nether", "survival_minecraft_islands"], "overworld, nether, extra dimension (no end yet)")
	FileOps.remove_tree(dir)
	check_eq(Chunky.worlds(dir, "world").map(func(w: Dictionary) -> String: return w.name), ["world", "world_nether", "world_the_end"], "not generated yet: the usual three")


func test_switches_force_load() -> void:
	var dir := ProjectSettings.globalize_path("user://test-chunky-%d" % Time.get_ticks_usec())
	check(not Chunky.set_force_load(dir, false), "off without a config: Chunky's default, nothing written")
	check(Chunky.set_force_load(dir, true), "on: written")
	var config := dir.path_join("plugins/Chunky/config.yml")
	_write(config, "version: 2\nforce-load-existing-chunks: false\nsilent: false\n")
	check(Chunky.set_force_load(dir, true) and not Chunky.set_force_load(dir, true), "changed once, then already on")
	check_eq(FileAccess.get_file_as_string(config), "version: 2\nforce-load-existing-chunks: true\nsilent: false\n", "only that line changes")
	_write(dir.path_join("plugins/Chunky/tasks/world.properties"), "world=world\npattern=csv\ncsv=world\n")
	_write(dir.path_join("plugins/Chunky/tasks/world_nether.properties"), "world=world_nether\npattern=region\n")
	check(Chunky.task_loads_existing(dir, "world") and not Chunky.task_loads_existing(dir, "world_nether"), "a saved existing-chunks task is recognised")
	FileOps.remove_tree(dir)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	FileAccess.open(path, FileAccess.WRITE).store_string(text)
