extends Node
## Drives the real main scene's Permissions tab: install LuckPerms, then create a group,
## give it permissions, put a player in it and build a track, through the tab's own
## controls, locally and as a remote server admin. Saves screenshots along the way.
## Must run with a display (not --headless).
## Usage: godot --path . res://tests/integration/permissions_ui_test.tscn -- --no-autostart --profile=pui --root=<dir> --shots=<dir>

const MAIN_SCENE := preload("res://scenes/main/main.tscn")
const PORT := 25993

var _shots := ""
var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://permissions-ui-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--shots="):
			_shots = arg.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(_shots)
	OS.low_processor_usage_mode = false
	AppSettings.server_dirs = PackedStringArray()
	AppSettings.servers_root = root
	for f in ["remote-access.json", "remote-hosts.json", "remote-host.key", "remote-host.crt"]:
		DirAccess.remove_absolute(AppSettings.profile_path(f))
	get_window().size = Vector2i(1440, 900)

	var version := "26.3"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Survival", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4"},
	})
	var inst: ServerInstance = created.instance
	var main: Control = MAIN_SCENE.instantiate()
	add_child(main)
	await _frames(10)
	main.show_server(inst.config.id)
	var view: ServerView = main.get_node("%ServerView")
	var tabs: TabContainer = view.get_node("%Tabs")
	tabs.current_tab = _tab(tabs, "Plugins")
	var plugins: PluginsTab = tabs.get_child(_tab(tabs, "Plugins"))
	plugins.open_integration("LuckPerms")
	var tab: PermissionsTab = plugins.integration_page("LuckPerms")
	await _wait_for(func() -> bool: return tab.get_node("%InstallButton").visible, 10.0)
	_check(tab.get_node("%InstallButton").visible and tab.get_node("%Notice").visible, "offers to install LuckPerms")
	await _shot("70_perms_not_installed")

	tab.get_node("%InstallButton").pressed.emit()
	await _wait_for(func() -> bool: return LuckPerms.installed_info(inst.config.directory).installed, 60.0)
	_check(LuckPerms.installed_info(inst.config.directory).installed, "installed from the tab")
	inst.start()
	await _wait_for(func() -> bool: return inst.is_online() and inst.rcon.is_ready(), 240.0)
	await _wait_for(func() -> bool: return tab._state.get("live", false), 30.0)
	_check(tab._state.get("live", false) and not tab.get_node("%Notice").visible, "live once the server runs")

	# Groups: create one, set weight and prefix, add permissions.
	await _type_and_add(tab, "mod")
	_check(tab._selected == "mod" and tab.get_node("%GroupSettings").visible, "new group selected")
	tab.get_node("%WeightSpin").value = 50
	tab.get_node("%PrefixEdit").text = "&c[Mod] "
	tab.get_node("%SaveGroupButton").pressed.emit()
	await _wait_idle(tab)
	var mod: Variant = LuckPerms.find(tab._state, "group", "mod")
	_check(mod != null and mod.weight == 50 and mod.prefixes.size() == 1, "weight and prefix saved")
	for spec in [["essentials.fly", 0, "", ""], ["essentials.kick", 0, "", ""], ["worldedit.*", 0, "world=world", "7d"], ["essentials.ban", 1, "", ""]]:
		tab.get_node("%NodeEdit").text = spec[0]
		tab.get_node("%ValueOption").select(spec[1])
		tab.get_node("%WhereEdit").text = spec[2]
		tab.get_node("%DurationEdit").text = spec[3]
		tab.get_node("%AddPermButton").pressed.emit()
		await _wait_idle(tab)
	mod = LuckPerms.find(tab._state, "group", "mod")
	_check(mod != null and mod.permissions.size() == 4, "four permissions added (%d)" % (mod.permissions.size() if mod != null else -1))
	# Browse: pick Minecraft's /gamemode permission from the list.
	tab.get_node("%BrowseButton").pressed.emit()
	await _wait_for(func() -> bool: return tab.get_node("%KnownDialog").visible, 20.0)
	tab.get_node("%KnownSearch").text = "gamemode"
	tab._fill_known()
	var known_tree: Tree = tab.get_node("%KnownTree")
	var first := known_tree.get_root().get_first_child() if known_tree.get_root() != null else null
	_check(first != null and first.get_text(0) == "minecraft.command.gamemode", "browse finds Minecraft's /gamemode permission")
	await _shot("71a_perms_browse")
	if first != null:
		first.select(0)
	tab.get_node("%KnownDialog").confirmed.emit()
	tab.get_node("%KnownDialog").hide()
	_check(tab.get_node("%NodeEdit").text == "minecraft.command.gamemode", "picked permission filled in")
	tab.get_node("%NodeEdit").text = ""
	var tree: Tree = tab.get_node("%PermTree")
	tree.get_root().get_child(0).select(0)
	tab.get_node("%ToggleButton").pressed.emit()
	await _wait_idle(tab)
	mod = LuckPerms.find(tab._state, "group", "mod")
	_check(mod != null and mod.permissions.any(func(p: Dictionary) -> bool: return p.node == "essentials.ban" and p.value), "deny toggled to allow")
	tab.get_node("%ParentOption").select(0)
	tab.get_node("%AddParentButton").pressed.emit()
	await _wait_idle(tab)
	await _shot("71_perms_group")

	# Players: find one by name and put them in the group.
	tab.get_node("%SectionBar").current_tab = PermissionsTab.Section.PLAYERS
	await _type_and_add(tab, "Steve")
	_check(LuckPerms.is_uuid(tab._selected), "player found")
	var options: OptionButton = tab.get_node("%ParentOption")
	for i in options.item_count:
		if options.get_item_text(i) == "mod":
			options.select(i)
	tab.get_node("%AddParentButton").pressed.emit()
	await _wait_idle(tab)
	var steve: Variant = LuckPerms.find(tab._state, "user", tab._selected)
	_check(steve != null and steve.parents.any(func(p: Dictionary) -> bool: return p.group == "mod"), "player put in the group")

	# Tracks.
	tab.get_node("%SectionBar").current_tab = PermissionsTab.Section.TRACKS
	await _type_and_add(tab, "staff")
	for group in ["default", "mod"]:
		var picks: OptionButton = tab.get_node("%TrackGroupOption")
		for i in picks.item_count:
			if picks.get_item_text(i) == group:
				picks.select(i)
		tab.get_node("%AppendButton").pressed.emit()
		await _wait_idle(tab)
	var staff: Variant = tab._track("staff")
	_check(staff != null and staff.groups == ["default", "mod"], "track built: %s" % [staff])
	tab.get_node("%TrackGroups").select(1)
	tab.get_node("%UpButton").pressed.emit()
	await _wait_idle(tab)
	staff = tab._track("staff")
	_check(staff != null and staff.groups == ["mod", "default"], "group moved up: %s" % [staff])
	await _shot("73_perms_track")
	tab.get_node("%SectionBar").current_tab = PermissionsTab.Section.PLAYERS
	tab._select(str(steve.uuid) if steve != null else "")
	await _frames(4)
	await _shot("72_perms_player")

	# As a remote server admin.
	RemoteAccess.set_computer_name("Brian's PC")
	RemoteAccess.set_enabled(true, PORT)
	var alice := RemoteAccess.create_grant("Alice", RemoteProtocol.Role.SERVER_ADMIN, PackedStringArray([inst.config.id]))
	var link: RemoteLink = RemoteHosts.add_from_invite(RemoteAccess.invite_for(alice), "127.0.0.1").link
	await _wait_for(func() -> bool: return link.is_online() and not link.remote_servers().is_empty(), 20.0)
	var remote: RemoteServer = link.remote_servers()[0]
	main.show_server(remote.key())
	tabs.current_tab = _tab(tabs, "Plugins")
	plugins.open_integration("LuckPerms")
	await _wait_for(func() -> bool: return tab.handle == remote and tab._state.get("live", false), 30.0)
	_check(tab.handle == remote and LuckPerms.find(tab._state, "group", "mod") != null, "remote server admin sees the groups")
	tab.get_node("%SectionBar").current_tab = PermissionsTab.Section.GROUPS
	await _type_and_add(tab, "helper")
	_check(LuckPerms.find(tab._state, "group", "helper") != null, "remote server admin creates a group")
	await _shot("74_perms_remote")

	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)
	main.show_server(inst.config.id)
	tabs.current_tab = _tab(tabs, "Plugins")
	plugins.open_integration("LuckPerms")
	tab.refresh()
	await _wait_for(func() -> bool: return tab.handle == inst and not tab._state.is_empty() and not tab._state.get("live", true), 20.0)
	_check(tab.get_node("%Notice").visible and tab.get_node("%AddPermButton").disabled, "stopped: read-only with a notice")
	await _shot("75_perms_stopped")
	RemoteHosts.remove(link)
	RemoteAccess.set_enabled(false, PORT)
	if _failures.is_empty():
		ServerManager.delete_server(inst.config.id, true, true)
	print("\nPermissions UI test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _type_and_add(tab: PermissionsTab, text: String) -> void:
	tab.get_node("%NewEdit").text = text
	tab._update_controls()
	tab.get_node("%AddButton").pressed.emit()
	await _wait_idle(tab)


func _wait_idle(tab: PermissionsTab) -> void:
	await _frames(2)
	await _wait_for(func() -> bool: return not tab._busy, 30.0)
	await _frames(2)


func _tab(tabs: TabContainer, name: String) -> int:
	for i in tabs.get_tab_count():
		if str(tabs.get_child(i).name) == name:
			return i
	return 0


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await _frames(6)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shots.path_join(name + ".png"))


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
