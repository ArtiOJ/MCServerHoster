extends Node
## End-to-end test for importing existing servers: a Paper server started outside the
## manager is imported in place (auto re-attach, read-only without RCON, SIGTERM stop,
## then managed restart), a copy-mode import, and a vanilla → Paper switch.
## Usage: godot --headless --path . res://tests/integration/server_import_test.tscn -- --no-autostart --profile=sit --root=<scratch dir>

var _failures := PackedStringArray()
var _scratch := ""


func _ready() -> void:
	_scratch = ProjectSettings.globalize_path("user://server-import-test")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			_scratch = arg.get_slice("=", 1)
	FileOps.remove_path(_scratch)
	AppSettings.servers_root = _scratch.path_join("managed")
	AppSettings.server_dirs = PackedStringArray()
	var java := JavaRuntimes.best_for(21)
	var cached := _cached_paper_jar("1.21.11")
	_check(java != null and cached != "", "Java 21 and a cached Paper 1.21.11 jar are available")
	if java == null or cached == "":
		return _finish()

	# --- An existing Paper server, running outside the manager -----------------
	var port := ServerManager.allocate_game_port()
	var dir := _scratch.path_join("existing/My Paper Server")
	_make_server(dir, cached, "paper-1.21.11-132.jar", port, "My Existing Server")
	var pid := OS.create_process("/bin/sh", ["-c", "cd \"$0\" && exec \"$1\" -Xmx1G -Dterminal.jline=false -jar paper-1.21.11-132.jar --nogui > console.log 2>&1 < /dev/null", dir, java.executable])
	await _wait_for(func() -> bool: return not PlatformBackend.is_port_free(port), 120.0)
	_check(not PlatformBackend.is_port_free(port), "external server is up")

	var a := ServerImporter.analyze(dir)
	_check(a.software == "paper" and a.mc_version == "1.21.11" and a.build == 132, "detected Paper 1.21.11 #132 (%s %s #%d)" % [a.software, a.mc_version, a.build])
	_check(a.ram_max_mb == 2048 and a.port == port and not a.rcon_enabled, "start script memory, port, no RCON")
	_check(a.running_pid == pid, "running process found (%d)" % a.running_pid)

	var res: Dictionary = await ServerManager.import_existing_server(dir, {"analysis": a, "display_name": "My Paper Server", "mode": "in_place", "port": port, "ram_max_mb": 2048})
	_check(res.ok, "imported in place: %s" % res.get("error", ""))
	if not res.ok:
		return _finish()
	var inst: ServerInstance = res.instance
	await _wait_for(func() -> bool: return inst.process.is_attached(), 10.0)
	_check(inst.process.is_attached() and inst.is_online(), "auto re-attached to the running server")
	_check(inst.is_read_only(), "read-only console without RCON")
	_check(DirAccess.dir_exists_absolute(dir.path_join(".manager")) and inst.config.jar_file == "paper-1.21.11-132.jar", "only .manager added; jar name kept")

	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)
	_check(inst.state == ServerInstance.State.STOPPED, "stopped via SIGTERM fallback (state %s)" % inst.state_name())

	_check(inst.start() == OK, "start under management")
	await _wait_for(func() -> bool: return inst.is_online() and inst.rcon.is_ready(), 120.0)
	var props := inst.get_properties()
	_check(inst.rcon.is_ready() and props.get_bool("enable-rcon"), "RCON enabled under management")
	_check(props.get_value("motd") == "My Existing Server" and props.get_int("server-port") == port, "original motd and port kept")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)

	# --- Copy mode ---------------------------------------------------------------
	var dir2 := _scratch.path_join("existing/copy-me")
	_make_server(dir2, cached, "server.jar", ServerManager.allocate_game_port(), "Copied")
	var a2 := ServerImporter.analyze(dir2)
	var res2: Dictionary = await ServerManager.import_existing_server(dir2, {"analysis": a2, "display_name": "Copied Server", "mode": "copy"})
	_check(res2.ok, "copy-mode import: %s" % res2.get("error", ""))
	if res2.ok:
		var copied: ServerInstance = res2.instance
		_check(copied.config.directory.begins_with(AppSettings.servers_root), "copy lives in the servers folder")
		_check(not DirAccess.dir_exists_absolute(dir2.path_join(".manager")), "original folder untouched")
		ServerManager.delete_server(copied.config.id, true, true)

	# --- Vanilla → Paper ---------------------------------------------------------
	var vanilla_url: String = await _vanilla_server_url("1.21.11")
	if vanilla_url == "":
		print("SKIP vanilla → Paper switch (Mojang version manifest unavailable)")
	else:
		var dir3 := _scratch.path_join("existing/vanilla")
		DirAccess.make_dir_recursive_absolute(dir3)
		_check(await _download(vanilla_url, dir3.path_join("server.jar")), "downloaded the vanilla server jar")
		_make_server(dir3, "", "", ServerManager.allocate_game_port(), "Vanilla world")
		var a3 := ServerImporter.analyze(dir3)
		_check(a3.software == "vanilla" and a3.mc_version == "1.21.11" and a3.needs_paper_switch, "detected vanilla 1.21.11")
		var res3: Dictionary = await ServerManager.import_existing_server(dir3, {"analysis": a3, "display_name": "Was Vanilla", "mode": "in_place", "switch_to_paper": true})
		_check(res3.ok, "vanilla import with Paper switch: %s" % res3.get("error", ""))
		if res3.ok:
			var v: ServerInstance = res3.instance
			_check(v.config.jar_file == "paper.jar" and v.config.paper_build > 0, "now runs Paper build #%d" % v.config.paper_build)
			_check(FileAccess.file_exists(v.config.meta_dir().path_join("jars/server.jar")), "old vanilla jar kept in .manager/jars")
			v.start()
			await _wait_for(func() -> bool: return v.is_online(), 180.0)
			_check(v.is_online(), "switched server boots")
			v.stop()
			await _wait_for(func() -> bool: return not v.is_process_alive(), 60.0)
			ServerManager.delete_server(v.config.id, true, true)

	ServerManager.delete_server(inst.config.id, true, true)
	FileOps.remove_path(_scratch)
	_finish()


func _make_server(dir: String, jar_source: String, jar_name: String, port: int, motd: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	if jar_source != "":
		DirAccess.copy_absolute(jar_source, dir.path_join(jar_name))
	var f := FileAccess.open(dir.path_join("start.sh"), FileAccess.WRITE)
	f.store_string("#!/bin/sh\njava -Xms1G -Xmx2G -jar %s --nogui\n" % (jar_name if jar_name != "" else "server.jar"))
	f = FileAccess.open(dir.path_join("server.properties"), FileAccess.WRITE)
	f.store_string("server-port=%d\nmotd=%s\nonline-mode=false\nlevel-type=minecraft\\:flat\nview-distance=4\n" % [port, motd])
	f = FileAccess.open(dir.path_join("eula.txt"), FileAccess.WRITE)
	f.store_string("eula=true\n")


func _cached_paper_jar(version: String) -> String:
	var cache := ProjectSettings.globalize_path(PaperApi.CACHE_DIR)
	for f in DirAccess.get_files_at(cache):
		if f.ends_with(".jar") and ServerImporter.inspect_jar(cache.path_join(f)).mc_version == version:
			return cache.path_join(f)
	return ""


func _vanilla_server_url(version: String) -> String:
	var manifest := await _get_json("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
	for v in manifest.get("versions", []):
		if v.get("id", "") == version:
			var meta := await _get_json(v.url)
			return str(meta.get("downloads", {}).get("server", {}).get("url", ""))
	return ""


func _get_json(url: String) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	if http.request(url) != OK:
		return {}
	var r: Array = await http.request_completed
	http.queue_free()
	var data = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8()) if r[1] == 200 else null
	return data if data is Dictionary else {}


func _download(url: String, path: String) -> bool:
	var http := HTTPRequest.new()
	http.download_file = path
	add_child(http)
	if http.request(url) != OK:
		return false
	var r: Array = await http.request_completed
	http.queue_free()
	return r[0] == HTTPRequest.RESULT_SUCCESS and r[1] == 200


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nServer import test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
