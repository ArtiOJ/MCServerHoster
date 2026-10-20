extends Node
## Drives the real main scene connected to itself over remote access (one server-admin key,
## one system-admin key) and saves screenshots of every remote view and dialog, checking
## the interface state along the way. Must run with a display (not --headless).
## Usage: godot --path . res://tests/integration/remote_ui_test.tscn -- --no-autostart --profile=rui --root=<dir> --shots=<dir>

const MAIN_SCENE := preload("res://scenes/main/main.tscn")
const PORT := 25992

var _shots := ""
var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://remote-ui-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--shots="):
			_shots = arg.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(_shots)
	OS.low_processor_usage_mode = false
	AppSettings.server_dirs = PackedStringArray()
	AppSettings.servers_root = root
	_clean_profile_files()
	get_window().size = Vector2i(1440, 900)

	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var made := []
	for spec in [["Survival", Color("3fb97f")], ["Creative Build", Color("5aa9f2")]]:
		var created: Dictionary = await ServerManager.create_server({
			"name": spec[0], "color": spec[1], "version": version, "build": latest.build, "version_info": vinfo,
			"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
			"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
		})
		made.append(created.instance)
	var survival: ServerInstance = made[0]

	var main: Control = MAIN_SCENE.instantiate()
	add_child(main)
	await _frames(10)
	RemoteAccess.set_computer_name("Brian's PC")
	RemoteAccess.set_enabled(true, PORT)
	var alice := RemoteAccess.create_grant("Alice", RemoteProtocol.Role.SERVER_ADMIN, PackedStringArray([survival.config.id]))
	var bob := RemoteAccess.create_grant("Bob", RemoteProtocol.Role.SYSTEM_ADMIN, PackedStringArray())
	var alice_link: RemoteLink = RemoteHosts.add_from_invite(RemoteAccess.invite_for(alice), "127.0.0.1").link
	var bob_link: RemoteLink = RemoteHosts.add_from_invite(RemoteAccess.invite_for(bob), "127.0.0.1").link
	await _wait_for(func() -> bool: return alice_link.is_online() and bob_link.is_online(), 20.0)
	_check(alice_link.is_online() and bob_link.is_online(), "both keys connected")
	survival.start()
	await _wait_for(func() -> bool: return survival.is_online() and survival.tps >= 0.0, 240.0)
	await get_tree().create_timer(3.0).timeout

	# Sidebar: the server-admin server under "Remote servers", the computer switcher for Bob.
	main.show_dashboard()
	var sidebar: Sidebar = main.get_node("%Sidebar")
	var remote_list: VBoxContainer = sidebar.get_node("%RemoteList")
	var host_option: OptionButton = sidebar.get_node("%HostOption")
	_check(remote_list.get_child_count() == 1 and sidebar.get_node("%RemoteCaption").visible, "one server under Remote servers")
	_check(host_option.visible and host_option.item_count == 2, "computer switcher lists this computer and Brian's PC")
	await _shot("50_sidebar_remote")

	# A server-admin server: every tab, with computer-wide controls locked.
	var remote_survival: RemoteServer = alice_link.remote_servers()[0]
	main.show_server(remote_survival.key())
	var view: ServerView = main.get_node("%ServerView")
	var tabs: TabContainer = view.get_node("%Tabs")
	var hidden := PackedStringArray()
	for i in tabs.get_tab_count():
		if tabs.is_tab_hidden(i):
			hidden.append(str(tabs.get_child(i).name))
	_check(hidden.is_empty(), "remote server shows every tab (hidden: %s)" % str(hidden))
	await _wait_for(func() -> bool: return remote_survival.cpu_history().size() > 2, 10.0)
	await _shot("51_remote_overview")
	tabs.current_tab = _tab(tabs, "Console")
	remote_survival.send_command("say Hello from Alice")
	await get_tree().create_timer(1.5).timeout
	await _shot("52_remote_console")
	tabs.current_tab = _tab(tabs, "Settings")
	await get_tree().create_timer(1.5).timeout
	var form: VBoxContainer = tabs.get_child(_tab(tabs, "Settings")).get_node("%FormList")
	_check(form.get_child_count() > 20, "remote settings form filled (%d rows)" % form.get_child_count())
	await _shot("53_remote_settings")
	for pair in [["Plugins", "53a_remote_plugins"], ["Players", "53b_remote_players"], ["Worlds", "53c_remote_worlds"],
			["Backups", "53d_remote_backups"], ["Logs", "53e_remote_logs"], ["Automation", "53f_remote_automation"]]:
		tabs.current_tab = _tab(tabs, pair[0])
		await get_tree().create_timer(2.0).timeout
		await _shot(pair[1])
	tabs.current_tab = _tab(tabs, "Resources")
	await get_tree().create_timer(2.0).timeout
	var resources: Control = tabs.get_child(_tab(tabs, "Resources"))
	_check((resources.get_node("%JavaOption") as OptionButton).disabled and not (resources.get_node("%ExtraArgsEdit") as LineEdit).editable, "server admin can't pick Java or JVM arguments")
	await _shot("53g_remote_resources")
	tabs.current_tab = _tab(tabs, "Network")
	await get_tree().create_timer(3.0).timeout
	var network: Control = tabs.get_child(_tab(tabs, "Network"))
	_check((network.get_node("%UpnpCheck") as CheckButton).disabled, "server admin can't change UPnP")
	await _shot("53h_remote_network")
	tabs.current_tab = _tab(tabs, "Overview")
	var header: ServerHeader = view.get_node("%Header")
	var menu := (header.get_node("%MoreButton") as MenuButton).get_popup()
	_check(menu.is_item_disabled(menu.get_item_index(ServerHeader.MenuItem.DELETE)), "server admin can't delete from the menu")
	_check(menu.is_item_disabled(menu.get_item_index(ServerHeader.MenuItem.OPEN_FOLDER)), "remote folder can't be opened")

	# Switching to the other computer as its system admin.
	main._switch_source(bob_link)
	await get_tree().create_timer(4.5).timeout
	var dashboard: Dashboard = main.get_node("%Dashboard")
	_check(dashboard.get_node("%Cards").get_child_count() == 2, "remote dashboard lists both servers")
	_check(sidebar.get_node("%Caption").text.begins_with("SERVERS ON"), "sidebar names the computer")
	await _shot("54_remote_dashboard")
	var bob_creative: ServerHandle = null
	for h in bob_link.get_handles():
		if h.config.display_name == "Creative Build":
			bob_creative = h
	main.show_server(bob_creative.key())
	await _shot("55_sysadmin_server")
	_check(not menu.is_item_disabled(menu.get_item_index(ServerHeader.MenuItem.DELETE)), "system admin can delete")
	var wizard: NewServerWizard = main.get_node("%NewServerWizard")
	main._open_wizard()
	await _shot("56_remote_wizard")
	_check(wizard.title.contains("Brian's PC"), "wizard creates on the other computer")
	wizard.hide()
	var prefs: AppSettingsDialog = main.get_node("%AppSettingsDialog")
	prefs.open(bob_link)
	await get_tree().create_timer(1.5).timeout
	_check(prefs.title.contains("Brian's PC") and (prefs.get_node("%RootEdit") as LineEdit).text == AppSettings.servers_root, "preferences of the other computer loaded")
	await _shot("57_remote_preferences")
	prefs.hide()
	var share: RemoteDialog = main.get_node("%RemoteDialog")
	share.open(RemoteDialog.TabIndex.SHARE, bob_link)
	await get_tree().create_timer(1.5).timeout
	_check(share.get_node("%GrantList").get_child_count() == 3 and (share.get_node("%EnableCheck") as CheckButton).disabled, "keys of the other computer listed, listener locked")
	await _shot("58_remote_keys")
	share.hide()
	main._switch_source(ServerManager)
	await _frames(4)
	_check(dashboard.get_node("%Cards").get_child_count() == 2 and not host_option.get_item_text(host_option.selected).contains("Brian"), "back on this computer")

	# The Remote access dialog.
	var dialog: RemoteDialog = main.get_node("%RemoteDialog")
	dialog.open(RemoteDialog.TabIndex.SHARE)
	await get_tree().create_timer(0.5).timeout
	_check(dialog.get_node("%GrantList").get_child_count() == 3, "two keys listed")
	await _shot("60_remote_share")
	dialog._open_key_dialog({})
	(dialog.get_node("%PersonEdit") as LineEdit).text = "Charlie"
	dialog._update_key_dialog()
	await _shot("61_new_key")
	dialog.get_node("%KeyDialog").hide()
	dialog._show_invite(alice.name, alice.role, RemoteAccess.invite_for(alice), RemoteAccess.invite_addresses())
	await _shot("62_invite")
	dialog.get_node("%InviteDialog").hide()
	dialog.open(RemoteDialog.TabIndex.CONNECT)
	await _shot("63_remote_connect")
	dialog._open_add_link()
	(dialog.get_node("%CodeEdit") as TextEdit).text = "not an invite"
	dialog._add_link()
	_check((dialog.get_node("%AddError") as Label).text != "", "bad invite explained")
	await _shot("64_add_computer")
	dialog.get_node("%AddLinkDialog").hide()
	dialog.hide()

	# Revoking Alice's key: her server leaves the sidebar and the view returns to the dashboard.
	main.show_server(remote_survival.key())
	var revoked_key := remote_survival.key()
	RemoteAccess.revoke_grant(alice)
	await _wait_for(func() -> bool: return alice_link.status == RemoteLink.Status.DENIED, 20.0)
	await _frames(4)
	await _shot("65_revoked")
	_check(remote_list.get_child_count() == 0 and not sidebar.get_node("%RemoteCaption").visible, "revoked server left the sidebar")
	_check(main._current_id == "" and RemoteHosts.find_server(revoked_key) == null, "view went back to the dashboard")

	survival.stop()
	await _wait_for(func() -> bool: return not survival.is_process_alive(), 60.0)
	for l in RemoteHosts.links():
		RemoteHosts.remove(l)
	RemoteAccess.set_enabled(false)
	for i in ServerManager.get_instances().duplicate():
		ServerManager.delete_server(i.config.id, true, true)
	_clean_profile_files()
	print("\nRemote UI test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _tab(tabs: TabContainer, title: String) -> int:
	for i in tabs.get_tab_count():
		if str(tabs.get_child(i).name) == title:
			return i
	return 0


func _clean_profile_files() -> void:
	for f in ["remote-access.json", "remote-hosts.json", "remote-host.key", "remote-host.crt"]:
		DirAccess.remove_absolute(AppSettings.profile_path(f))


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await _frames(6)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_shots.path_join(name + ".png"))


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
