extends Node
## Remote access end to end, with this app as both host and client over 127.0.0.1 and a
## real Paper server: certificate bootstrap and pinning, roles, live state and console,
## commands, settings, icon, every tab's operations with uploads and downloads, permission
## refusals, system-admin preferences, keys, server import and delete, revocation, a wrong
## key, and a host certificate change.
## Usage: godot --headless --path . res://tests/integration/remote_test.tscn -- --no-autostart --profile=remote --root=<dir>

const PORT := 25991

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://remote-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	_clean_profile_files()
	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var made := []
	for n in ["Remote Test A", "Remote Test B"]:
		var created: Dictionary = await ServerManager.create_server({
			"name": n, "version": version, "build": latest.build, "version_info": vinfo,
			"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
			"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
		})
		made.append(created.instance)
	var a: ServerInstance = made[0]
	var b: ServerInstance = made[1]

	# --- Host side ---------------------------------------------------------------------
	RemoteAccess.set_enabled(true, PORT)
	_check(RemoteAccess.is_listening(), "listening on %d" % PORT)
	var alice := RemoteAccess.create_grant("Alice", RemoteProtocol.Role.SERVER_ADMIN, PackedStringArray([a.config.id]))
	var bob := RemoteAccess.create_grant("Bob", RemoteProtocol.Role.SYSTEM_ADMIN, PackedStringArray())
	var out: Array = []
	OS.execute("stat", ["-c", "%a", ProjectSettings.globalize_path(AppSettings.profile_path("remote-access.json"))], out)
	_check(str(out[0]).strip_edges() == "600", "keys file is private")

	# --- Server admin ----------------------------------------------------------------------
	var added: Dictionary = RemoteHosts.add_from_invite(RemoteAccess.invite_for(alice), "127.0.0.1")
	_check(added.ok, "invite accepted")
	var link: RemoteLink = added.link
	await _wait_for(func() -> bool: return link.is_online() or link.status == RemoteLink.Status.DENIED, 20.0)
	_check(link.is_online(), "Alice connected: " + link.error)
	_check(link.cert_pem.begins_with("-----BEGIN CERTIFICATE-----"), "host certificate pinned")
	_check(link.role == RemoteProtocol.Role.SERVER_ADMIN, "role is server admin")
	_check(link.label == RemoteAccess.computer_name, "computer name shown")
	var ids := link.remote_servers().map(func(s: RemoteServer) -> String: return s.remote_id)
	_check(ids == [a.config.id], "Alice sees only her server: %s" % str(ids))
	_check(RemoteHosts.server_admin_servers().size() == 1, "listed under remote servers")
	var ra: RemoteServer = link.remote_servers()[0]
	_check(ra.config.display_name == "Remote Test A" and ra.config.rcon_password == "", "config mirrored without the RCON password")
	_check(not FileAccess.file_exists(ra.config.properties_path()), "remote config has no local folder")
	_check(ra.folder_path() == a.config.directory, "host folder shown")

	# Live state and console
	ra.start()
	await _wait_for(func() -> bool: return ra.state == ServerHandle.State.RUNNING, 200.0)
	_check(a.state == ServerInstance.State.RUNNING and ra.state == ServerHandle.State.RUNNING, "started remotely; state mirrored")
	_check(_console_has(a, "Alice (remote) started the server."), "start audited in the host console")
	_check(_console_has(ra, "Done ("), "console streamed to the client")
	await _wait_for(func() -> bool: return ra.can_send_commands() and ra.cpu_history().size() > 0, 15.0)
	_check(ra.process_id() == a.process_id(), "PID mirrored")
	_check(ra.cpu_history().size() > 0 and ra.rss_bytes() > 0, "resource stats mirrored")
	_check(ra.send_command("say hello from afar"), "command accepted")
	await _wait_for(func() -> bool: return _console_has(ra, "hello from afar") and _console_has(a, "(Alice, remote)"), 10.0)
	_check(_console_has(a, "> say hello from afar   (Alice, remote)"), "command echoed with the sender's name")
	_check(_console_has(ra, "[Server] hello from afar") or _console_has(ra, "[Not Secure] [Server] hello from afar"), "server output reaches the client")

	# Settings
	var snap: Dictionary = await ra.settings_snapshot()
	_check(snap.ok and snap.values.has("motd"), "settings readable")
	var saved: Dictionary = await ra.save_settings({"motd": "Remote MOTD", "max-players": "7"})
	_check(saved.ok and saved.restart_needed, "settings saved: %s" % saved.get("error", ""))
	var props := ServerProperties.load_file(a.config.properties_path())
	_check(props.get_value("motd") == "Remote MOTD" and props.get_value("max-players") == "7", "written on the host")
	_check(_console_has(a, "Alice (remote) changed 2 settings"), "settings change audited")
	var bad: Dictionary = await ra.save_settings({"server-port": "1234"})
	_check(not bad.ok and props.get_int("server-port", 0) == a.config.port, "managed key refused")
	bad = await ra.save_settings({"made-up-key": "1"})
	_check(not bad.ok, "unknown key refused")
	var raw: Dictionary = await ra.read_config_file("server.properties")
	_check(raw.ok and str(raw.text).contains("motd=Remote MOTD"), "raw file readable")
	var escape: Dictionary = await ra.read_config_file("../../../../etc/passwd")
	_check(not escape.ok, "paths outside the config files refused")

	# Icon
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color.ORANGE)
	_check(await ra.set_icon_png(img.save_png_to_buffer()) == OK, "icon uploaded")
	_check(ServerIcon.info(a.config.directory).valid, "icon saved on the host")
	await _wait_for(func() -> bool: return ra.icon_texture() != null, 10.0)
	_check(ra.icon_texture() != null and ra.icon_texture().get_width() == 64, "icon shown on the client")
	var too_big := Image.create(100, 100, false, Image.FORMAT_RGBA8)
	_check(await ra.set_icon_png(too_big.save_png_to_buffer()) != OK, "wrong-size icon refused")

	# Refusals
	var res: Dictionary = await link.request("delete", a.config.id)
	_check(not res.ok and str(res.error).contains("does not allow"), "server admin cannot delete")
	res = await link.request("start", b.config.id)
	_check(not res.ok and b.state == ServerInstance.State.STOPPED, "server admin cannot touch other servers")
	res = await link.request("create_server", "", {"spec": {"name": "x", "version": version, "build_id": int(latest.build.id)}})
	_check(not res.ok, "server admin cannot create servers")
	res = await link.request("nonsense", a.config.id)
	_check(not res.ok, "unknown operation refused")

	# Tabs while running: logs, plugins (restart notice), backups with download
	var areas := {}
	ra.data_changed.connect(func(area: StringName) -> void: areas[area] = true)
	var logs: Dictionary = await ra.call_op("logs_list")
	_check(logs.ok and not logs.entries.is_empty(), "logs listed remotely")
	var log_text: Dictionary = await ra.call_op("log_read", {"id": logs.entries[0].id})
	_check(log_text.ok and str(log_text.text).contains("Done ("), "log read remotely")
	var jar := _make_plugin_jar("RemoteHello", "1.2.3")
	var installed: Dictionary = await ra.call_op("plugin_install", {"files": [jar]})
	_check(installed.ok and Array(installed.installed) == ["RemoteHello.jar"], "plugin uploaded: %s" % installed.get("error", ""))
	_check(FileAccess.file_exists(a.config.directory.path_join("plugins/RemoteHello.jar")), "plugin stored on the host")
	var plugins: Dictionary = await ra.call_op("plugins_list")
	_check(plugins.ok and plugins.plugins.size() == 1 and plugins.plugins[0].name == "RemoteHello" and plugins.plugins[0].version == "1.2.3", "plugin listed with its name and version")
	_check(plugins.restart_needed, "restart notice while running")
	await _wait_for(func() -> bool: return areas.has(&"plugins"), 5.0)
	_check(areas.has(&"plugins"), "plugin change pushed to the client")
	var not_jar := _scratch("notes.txt")
	FileAccess.open(not_jar, FileAccess.WRITE).store_string("hi")
	var refused: Dictionary = await ra.call_op("plugin_install", {"files": [not_jar]})
	_check(not refused.ok and not FileAccess.file_exists(a.config.directory.path_join("plugins/notes.txt")), "non-jar upload refused")
	var sneaky: Dictionary = await link.request("plugin_install", a.config.id, {"files": ["/etc/hostname"]})
	_check(sneaky.get("installed", []).is_empty() and not FileAccess.file_exists(a.config.directory.path_join("plugins/hostname")), "host paths from the client are ignored")
	sneaky = await link.request("plugin_install", a.config.id, {"uploads": ["madeup"]})
	_check(not sneaky.ok, "unknown upload id refused")
	var made_backup: Dictionary = await ra.call_op("backup_create", {"full": false})
	_check(made_backup.ok, "backup made remotely: %s" % made_backup.get("error", ""))
	var backups: Dictionary = await ra.call_op("backups_list")
	_check(backups.ok and backups.backups.size() == 1, "backup listed")
	var copy_path := _scratch("backup-copy.zip")
	var copied: Dictionary = await ra.call_op("backup_file", {"name": backups.backups[0].name, "dest": copy_path})
	var host_copy := a.backups.backup_dir().path_join(str(backups.backups[0].name))
	_check(copied.ok and FileAccess.get_sha256(copy_path) == FileAccess.get_sha256(host_copy), "backup downloaded intact")
	var leftover := DirAccess.get_directories_at(AppSettings.servers_root.path_join("_temp"))
	_check(Array(leftover).any(func(d: String) -> bool: return d.begins_with("remote-")), "uploads staged for the session")

	ra.stop()
	await _wait_for(func() -> bool: return ra.state == ServerHandle.State.STOPPED and not a.is_process_alive(), 60.0)
	_check(a.state == ServerInstance.State.STOPPED and ra.state == ServerHandle.State.STOPPED, "stopped remotely")

	# Tabs while stopped: player lists, worlds and datapacks, resources, automation, network
	var listed: Dictionary = await ra.call_op("list_add", {"kind": "whitelist", "value": "Steve"})
	_check(listed.ok and PlayerLists.read(a.config.directory, PlayerLists.Kind.WHITELIST).size() == 1, "whitelist edited remotely: %s" % listed.get("error", ""))
	var lists: Dictionary = await ra.call_op("lists_get")
	_check(lists.ok and lists.mode == "files" and lists.lists.whitelist.size() == 1, "lists read remotely")
	var worlds: Dictionary = await ra.call_op("worlds_list", {"sizes": true})
	_check(worlds.ok and worlds.worlds.size() == 1 and worlds.worlds[0].active and worlds.worlds[0].generated, "worlds listed remotely")
	var export_path := _scratch("export.zip")
	var exported: Dictionary = await ra.call_op("world_export", {"folder": "world", "dest": export_path})
	var reader := ZIPReader.new()
	_check(exported.ok and reader.open(export_path) == OK and Array(reader.get_files()).any(func(f: String) -> bool: return f.ends_with("level.dat")), "world exported and downloaded: %s" % exported.get("error", ""))
	reader.close()
	var pack_dir := _scratch("CoolPack")
	DirAccess.make_dir_recursive_absolute(pack_dir.path_join("data"))
	FileAccess.open(pack_dir.path_join("pack.mcmeta"), FileAccess.WRITE).store_string('{"pack": {"pack_format": 48, "description": "Remote pack"}}')
	var pack: Dictionary = await ra.call_op("datapack_add", {"files": [pack_dir]})
	_check(pack.ok and FileAccess.file_exists(a.config.directory.path_join("world/datapacks/CoolPack.zip")), "datapack folder uploaded as a zip: %s" % pack.get("error", ""))
	var analysis: Dictionary = await ra.call_op("world_import_analyze", {"files": [export_path]})
	_check(analysis.ok and analysis.valid and str(analysis.version) != "", "uploaded world analysed: %s" % analysis.get("error", ""))
	var imported: Dictionary = await ra.call_op("world_import", {"token": analysis.get("token", ""), "mode": 1, "apply": false})
	_check(imported.ok, "world imported remotely: %s" % imported.get("error", ""))
	worlds = await ra.call_op("worlds_list", {"sizes": false})
	_check(worlds.ok and worlds.worlds.size() == 2, "imported world listed")
	var extra := ""
	for w in worlds.worlds:
		if not w.active:
			extra = w.folder
	var removed: Dictionary = await ra.call_op("world_delete", {"folder": extra})
	_check(removed.ok and not DirAccess.dir_exists_absolute(a.config.directory.path_join(extra)), "world deleted remotely")
	var info: Dictionary = await ra.call_op("resources_info")
	_check(info.ok and int(info.cores) == OS.get_processor_count(), "host facts for the Resources tab")
	var cfg_saved: Dictionary = await ra.call_op("config_save", {"changes": {"ram_max_mb": 2048, "auto_restart": false}})
	await _wait_for(func() -> bool: return ra.config.ram_max_mb == 2048, 5.0)
	_check(cfg_saved.ok and a.config.ram_max_mb == 2048 and not a.config.auto_restart and ra.config.ram_max_mb == 2048, "resources and automation saved remotely")
	var java_change: Dictionary = await ra.call_op("config_save", {"changes": {"java_path": "/bin/sh"}})
	_check(not java_change.ok and a.config.java_path == "", "server admin cannot change the Java executable")
	java_change = await ra.call_op("config_save", {"changes": {"extra_jvm_args": "-javaagent:x.jar"}})
	_check(not java_change.ok and a.config.extra_jvm_args == "", "server admin cannot change JVM arguments")
	var rule := EventRule.from_template(EventRule.templates()[0][1])
	rule.trigger = EventRule.Trigger.TIME
	rule.action = EventRule.Action.START
	rule.wake_computer = true
	var with_rule: Dictionary = await ra.call_op("config_save", {"changes": {"events": [rule.to_dict()]}})
	_check(with_rule.ok and a.config.events.size() == 1 and not a.config.events[0].wake_computer, "server admin's events can't wake the computer")
	var net: Dictionary = await ra.call_op("network_info")
	_check(net.ok and net.stale_rules.is_empty() and int(net.port) == a.config.port, "network status readable")
	for op in ["upnp_set", "firewall_allow"]:
		var denied: Dictionary = await ra.call_op(op, {"on": true})
		_check(not denied.ok and str(denied.error).contains("does not allow"), "server admin cannot use %s" % op)
	var prefs: Dictionary = await link.call_host_op("prefs_get")
	_check(not prefs.ok, "server admin cannot read the host's preferences")

	# --- System admin ---------------------------------------------------------------------
	var bob_added: Dictionary = RemoteHosts.add_from_invite(RemoteAccess.invite_for(bob), "127.0.0.1")
	var bob_link: RemoteLink = bob_added.link
	await _wait_for(func() -> bool: return bob_link.is_online() or bob_link.status == RemoteLink.Status.DENIED, 20.0)
	_check(bob_link.is_system_admin(), "Bob connected as system admin: " + bob_link.error)
	_check(bob_link.get_handles().size() == 2, "Bob sees every server")
	_check(RemoteHosts.server_admin_servers().size() == 1, "system-admin servers are not in the remote list")
	await _wait_for(func() -> bool: return not bob_link.host_stats().is_empty(), 5.0)
	_check(int(bob_link.host_stats().get("cores", 0)) == OS.get_processor_count(), "host stats for the dashboard")
	var b_id := b.config.id
	var b_dir := b.config.directory
	var rb := bob_link.find_handle("%s/%s" % [bob_link.link_id, b_id])
	_check(rb != null and rb.supports(ServerHandle.FEATURE_DELETE), "delete offered to a system admin")
	_check(not ra.supports(ServerHandle.FEATURE_DELETE), "delete not offered to a server admin")
	var del: Dictionary = await bob_link.delete_handle(rb, true, true) if rb != null else {"ok": false, "error": "no handle"}
	_check(del.ok, "deleted remotely: %s" % del.get("error", ""))
	_check(ServerManager.get_instance(b_id) == null and not DirAccess.dir_exists_absolute(b_dir), "gone on the host")
	await _wait_for(func() -> bool: return bob_link.get_handles().size() == 1, 5.0)
	_check(bob_link.get_handles().size() == 1, "removed on the client")

	# Waking: the host only offers it when connection wake-up is set up and on (not in tests);
	# a link that knows the Wi-Fi MAC wakes the computer with magic packets and keeps knocking.
	_check(RemoteAccess.recently_active(), "remote requests keep the host awake for a while")
	_check(bob_link.wake_mac == "" and not bob_link.can_wake(), "no wake-up offered while connection wake-up is off")
	var wake_info := PowerManager.remote_wake_info()
	_check(not wake_info.ready and wake_info.mac == "", "host reports wake-up as unavailable")

	# Computer-wide: preferences, Java, access keys, importing a server (uploaded)
	var host_prefs: Dictionary = await bob_link.call_host_op("prefs_get")
	_check(host_prefs.ok and int(host_prefs.values.default_ram_mb) == AppSettings.default_ram_mb, "system admin reads the preferences")
	var old_ram := AppSettings.default_ram_mb
	var prefs_saved: Dictionary = await bob_link.call_host_op("prefs_save", {"changes": {"default_ram_mb": 3072}})
	_check(prefs_saved.ok and AppSettings.default_ram_mb == 3072, "system admin changes the preferences")
	await bob_link.call_host_op("prefs_save", {"changes": {"default_ram_mb": old_ram}})
	var odd: Dictionary = await bob_link.call_host_op("prefs_save", {"changes": {"ui_scale": 3.0}})
	_check(not odd.ok, "display-only preferences stay per computer")
	var access: Dictionary = await bob_link.call_host_op("access_get")
	_check(access.ok and access.grants.size() == 2, "system admin sees the access keys")
	var carol: Dictionary = await bob_link.call_host_op("grant_create", {"name": "Carol", "role": RemoteProtocol.Role.SERVER_ADMIN, "servers": [a.config.id]})
	_check(carol.ok and RemoteProtocol.parse_invite(str(carol.invite)).ok and RemoteAccess.find_grant(str(carol.id)) != null, "system admin creates a key")
	var carol_gone: Dictionary = await bob_link.call_host_op("grant_revoke", {"id": carol.get("id", "")})
	_check(carol_gone.ok and RemoteAccess.find_grant(str(carol.get("id", ""))) == null, "system admin revokes a key")
	var upload_dir := _scratch("Uploaded Server")
	DirAccess.make_dir_recursive_absolute(upload_dir)
	for f in [a.config.jar_file, "server.properties", "eula.txt"]:
		DirAccess.copy_absolute(a.config.directory.path_join(f), upload_dir.path_join(f))
	var progress := []
	var server_analysis: Dictionary = await bob_link.call_host_op("server_import_analyze", {"files": [upload_dir]}, func(text: String, _f: float) -> void: progress.append(text))
	_check(server_analysis.ok and server_analysis.can_import and server_analysis.uploaded and server_analysis.mc_version == version, "uploaded server analysed: %s" % server_analysis.get("error", ""))
	_check(progress.any(func(t: String) -> bool: return t.begins_with("Uploading")), "upload progress reported")
	var import_port := ServerManager.allocate_game_port()
	var server_import: Dictionary = await bob_link.call_host_op("server_import", {"token": server_analysis.get("token", ""), "options": {"display_name": "Uploaded Server", "port": import_port, "accept_eula": true}})
	var uploaded := ServerManager.get_instance(str(server_import.get("server", "")))
	_check(server_import.ok and uploaded != null and uploaded.config.directory.begins_with(AppSettings.servers_root) and uploaded.config.port == import_port, "uploaded server imported: %s" % server_import.get("error", ""))
	await _wait_for(func() -> bool: return bob_link.get_handles().size() == 2, 5.0)
	_check(bob_link.get_handles().size() == 2, "imported server appears for the system admin")
	if uploaded != null:
		ServerManager.delete_server(uploaded.config.id, true, true)

	# --- Revocation ---------------------------------------------------------------------------
	RemoteAccess.revoke_grant(alice)
	await _wait_for(func() -> bool: return link.status == RemoteLink.Status.DENIED, 30.0)
	_check(link.status == RemoteLink.Status.DENIED, "revoked key cannot reconnect: " + link.error)
	_check(RemoteAccess.sessions().size() == 1, "only Bob's session remains")

	# --- Host certificate changes: the client fetches the new one (verified) and reconnects ---
	for f in ["remote-host.key", "remote-host.crt"]:
		DirAccess.remove_absolute(AppSettings.profile_path(f))
	RemoteAccess._key = null
	var old_pem := bob_link.cert_pem
	RemoteAccess.set_enabled(false)
	RemoteAccess.set_enabled(true, PORT)
	bob_link.connect_now()
	await _wait_for(func() -> bool: return bob_link.is_online() and bob_link.cert_pem != old_pem, 30.0)
	_check(bob_link.is_online() and bob_link.cert_pem != old_pem, "re-pinned the new certificate: " + bob_link.error)

	# --- A wrong secret is refused and repeated failures block the address -------------------
	var forged := RemoteProtocol.make_invite({"name": "x", "addresses": ["127.0.0.1"], "port": PORT, "key": bob.id, "secret": RemoteProtocol.new_secret()})
	var forged_link: RemoteLink = RemoteHosts.add_from_invite(forged, "127.0.0.1").get("link")
	_check(forged_link == null, "same key id twice is refused")
	RemoteHosts.remove(link)
	var bad_alice := RemoteProtocol.make_invite({"name": "x", "addresses": ["127.0.0.1"], "port": PORT, "key": "notakey123", "secret": RemoteProtocol.new_secret()})
	var bad_link: RemoteLink = RemoteHosts.add_from_invite(bad_alice, "127.0.0.1").link
	await _wait_for(func() -> bool: return bad_link.status == RemoteLink.Status.DENIED, 20.0)
	_check(bad_link.status == RemoteLink.Status.DENIED, "unknown key denied: " + bad_link.error)
	var sleepy: RemoteLink = RemoteHosts.add_from_invite(RemoteProtocol.make_invite({"name": "Sleepy", "addresses": ["127.0.0.1"], "port": PORT + 7, "key": "sleepykey1", "secret": RemoteProtocol.new_secret()}), "127.0.0.1").link
	sleepy.wake_mac = "02:00:00:00:00:01"
	await _wait_for(func() -> bool: return sleepy.status == RemoteLink.Status.OFFLINE, 15.0)
	_check(sleepy.can_wake(), "an offline computer that allows it can be woken")
	var attempts := [0]
	sleepy.status_changed.connect(func() -> void:
		if sleepy.status == RemoteLink.Status.CONNECTING:
			attempts[0] += 1)
	sleepy.wake()
	_check(sleepy.is_waking() and sleepy.status_text() == "Waking up…", "waking: magic packets sent, connecting")
	await get_tree().create_timer(8.0).timeout
	_check(attempts[0] >= 3, "keeps knocking every few seconds while waking (%d attempts in 8 s)" % attempts[0])
	RemoteHosts.remove(sleepy)
	for i in RemoteAccess.FAILURE_LIMIT:
		bad_link.connect_now()
		await _wait_for(func() -> bool: return bad_link.status != RemoteLink.Status.CONNECTING, 20.0)
	_check(RemoteAccess.is_blocked("127.0.0.1"), "address blocked after repeated failures")

	# --- Clean up -------------------------------------------------------------------------------
	for l in RemoteHosts.links():
		RemoteHosts.remove(l)
	RemoteAccess.set_enabled(false)
	await _wait_for(func() -> bool: return RemoteAccess.sessions().is_empty(), 10.0)
	await get_tree().create_timer(1.0).timeout
	var temp := AppSettings.servers_root.path_join("_temp")
	_check(not Array(DirAccess.get_directories_at(temp)).any(func(d: String) -> bool: return d.begins_with("remote-") or d.begins_with("import-")), "transfer folders cleaned up")
	ServerManager.delete_server(a.config.id, true, true)
	FileOps.remove_path(_scratch(""))
	_clean_profile_files()
	print("\nRemote test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


## A file or folder path in this test's scratch folder (the "client" side).
func _scratch(name: String) -> String:
	var dir := AppSettings.servers_root.get_base_dir().path_join("remote-test-client")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(name) if name != "" else dir


func _make_plugin_jar(plugin_name: String, plugin_version: String) -> String:
	var path := _scratch(plugin_name + ".jar")
	var zip := ZIPPacker.new()
	zip.open(path)
	zip.start_file("plugin.yml")
	zip.write_file(("name: %s\nversion: %s\nmain: test.Main\n" % [plugin_name, plugin_version]).to_utf8_buffer())
	zip.close_file()
	zip.close()
	return path


func _console_has(h: ServerHandle, text: String) -> bool:
	for e in h.console_lines:
		if str(e.plain).contains(text):
			return true
	return false


func _clean_profile_files() -> void:
	for f in ["remote-access.json", "remote-hosts.json", "remote-host.key", "remote-host.crt"]:
		DirAccess.remove_absolute(AppSettings.profile_path(f))


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
