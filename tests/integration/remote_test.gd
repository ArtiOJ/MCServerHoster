extends Node
## Remote access end to end, with this app as both host and client over 127.0.0.1 and a
## real Paper server: certificate bootstrap and pinning, roles, live state and console,
## commands, settings, icon, permission refusals, system-admin delete, revocation, a wrong
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

	ra.stop()
	await _wait_for(func() -> bool: return ra.state == ServerHandle.State.STOPPED and not a.is_process_alive(), 60.0)
	_check(a.state == ServerInstance.State.STOPPED and ra.state == ServerHandle.State.STOPPED, "stopped remotely")

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
	for i in RemoteAccess.FAILURE_LIMIT:
		bad_link.connect_now()
		await _wait_for(func() -> bool: return bad_link.status != RemoteLink.Status.CONNECTING, 20.0)
	_check(RemoteAccess.is_blocked("127.0.0.1"), "address blocked after repeated failures")

	# --- Clean up -------------------------------------------------------------------------------
	for l in RemoteHosts.links():
		RemoteHosts.remove(l)
	RemoteAccess.set_enabled(false)
	ServerManager.delete_server(a.config.id, true, true)
	_clean_profile_files()
	print("\nRemote test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


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
