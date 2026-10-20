extends Node
## Drives the real main scene's BlueMap tab: install BlueMap and accept the download with
## the tab's buttons, start the server, look at the rendered map in the viewer (3D, flat,
## free flight), use the Renders page (render actions, map settings, adding a map), and
## look at the map again as a remote server admin. Saves screenshots along the way.
## Must run with a display (not --headless). Needs network access (Modrinth, Mojang).
## Usage: godot --path . res://tests/integration/bluemap_ui_test.tscn -- --no-autostart --profile=bmui --root=<dir> --shots=<dir>

const MAIN_SCENE := preload("res://scenes/main/main.tscn")
const PORT := 25994

var _shots := ""
var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://bluemap-ui-test-servers")
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
		"ram_max_mb": 2048, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "view-distance": "4", "level-seed": "42"},
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
	plugins.open_integration("BlueMap")
	var tab: BlueMapTab = plugins.integration_page("BlueMap")
	await _wait_for(func() -> bool: return tab.get_node("%InstallButton").visible, 10.0)
	_check(tab.get_node("%InstallButton").visible and tab.get_node("%Notice").visible, "offers to install BlueMap")
	await _shot("80_bluemap_not_installed")

	tab.get_node("%InstallButton").pressed.emit()
	await _wait_for(func() -> bool: return tab.get_node("%ConsentCard").visible, 90.0)
	_check(BlueMap.installed_info(inst.config.directory).installed and tab.get_node("%ConsentCard").visible, "installed; asks for the download consent")
	await _shot("81_bluemap_consent")
	tab.get_node("%AcceptButton").pressed.emit()
	await _wait_for(func() -> bool: return not tab.get_node("%ConsentCard").visible, 20.0)
	_check(BlueMap.download_accepted(inst.config.directory) and tab.get_node("%MapPage").visible, "accepted; the map page shows")

	# The menu lives in Plugins: a button on the plugin's row, or Open when it's selected.
	_check(not tabs.has_node("BlueMap") and not tabs.has_node("Chunky") and not tabs.has_node("Permissions"), "no tabs of their own")
	plugins.close_integration()
	await _wait_for(func() -> bool: return _row(plugins, "BlueMap") != null, 15.0)
	var row_item := _row(plugins, "BlueMap")
	_check(row_item != null and row_item.get_button_count(0) == 1, "BlueMap's row has an open button")
	if row_item != null:
		row_item.select(0)
	await _frames(2)
	_check(plugins.get_node("%OpenButton").visible and plugins.get_node("%OpenButton").text == "Open BlueMap", "Open BlueMap offered for the selected plugin")
	await _shot("81b_plugins_list")
	plugins.get_node("%OpenButton").pressed.emit()
	await _frames(5)
	_check(tab.is_visible_in_tree() and not plugins.get_node("%VBox").visible, "the BlueMap menu opens in Plugins")

	inst.start()
	await _wait_for(func() -> bool: return inst.is_online() and inst.rcon.is_ready(), 240.0)
	# Without players almost nothing is fully generated; load an area like a visitor would.
	await inst.rcon.execute("forceload add -48 -48 47 47")
	await get_tree().create_timer(15.0).timeout
	await inst.rcon.execute("forceload remove all")
	await inst.rcon.execute("save-all flush")
	await _wait_for(func() -> bool:
		if not tab._busy:
			tab.refresh()
		var w := _map(tab._state, "world")
		return w.get("state") == "updated" and w.get("viewable", false) and DirAccess.dir_exists_absolute(inst.config.directory.path_join("bluemap/web/maps/world/tiles/0")), 600.0)
	await _frames(30)
	var viewer: BlueMapViewer = tab.get_node("%Viewer")
	# BlueMap notices changed chunks after its update cooldown; the viewer picks up new tiles
	# as they are written.
	await _wait_for(func() -> bool:
		if not tab._busy:
			tab.refresh()
		return viewer._tiles.values().any(func(t: Dictionary) -> bool: return t.lod == 0), 240.0)
	await _wait_tiles(viewer)
	_check(tab._shown_map == "world" and viewer._tiles.size() > 0, "the rendered map shows: %d tiles" % viewer._tiles.size())
	_check(viewer._tiles.values().any(func(t: Dictionary) -> bool: return t.lod == 0), "with full 3D blocks near the centre")
	await _shot("82_bluemap_map_3d")
	viewer._distance = 70.0
	viewer._angle = 1.0
	viewer._yaw = 0.7
	await _wait_tiles(viewer)
	await _shot("83_bluemap_map_close")
	viewer.set_view(BlueMapViewer.View.FLAT)
	viewer._distance = 250.0
	await _wait_tiles(viewer)
	_check(viewer._camera.projection == Camera3D.PROJECTION_ORTHOGONAL, "flat view is top-down")
	await _shot("84_bluemap_map_flat")
	viewer.set_view(BlueMapViewer.View.FREE)
	await _wait_tiles(viewer)
	await _shot("85_bluemap_map_free")
	viewer.set_view(BlueMapViewer.View.PERSPECTIVE)
	# Dragging moves the map; the wheel zooms.
	var before: Vector3 = viewer._target
	_drag(viewer, MOUSE_BUTTON_LEFT, Vector2(120, 0))
	_check(absf(viewer._target.x - before.x) > 1.0 or absf(viewer._target.z - before.z) > 1.0, "dragging moves the map")
	var distance: float = viewer._distance
	_wheel(viewer, MOUSE_BUTTON_WHEEL_UP)
	_check(viewer._distance < distance, "the wheel zooms in")
	var yaw: float = viewer._yaw
	_drag(viewer, MOUSE_BUTTON_RIGHT, Vector2(80, 0))
	_check(not is_equal_approx(viewer._yaw, yaw), "right-drag turns")

	# Renders page.
	tab.get_node("%ManagePageButton").button_pressed = true
	await _frames(5)
	_check(tab.get_node("%ManagePage").visible and tab.get_node("%MapList").get_child_count() >= 3, "renders page lists the maps")
	await _shot("86_bluemap_renders")
	tab._on_map_action("update", _map(tab._state, "world"))
	await _wait_idle(tab)
	tab._on_map_action("freeze", _map(tab._state, "world_the_end"))
	await _wait_idle(tab)
	_check(_map(tab._state, "world_the_end").get("frozen", false), "freeze from the Render menu")
	tab._on_map_action("unfreeze", _map(tab._state, "world_the_end"))
	await _wait_idle(tab)
	tab._edit_map("world")
	await _wait_for(func() -> bool: return tab.get_node("%MapDialog").visible, 10.0)
	_check((tab._map_fields["name"] as LineEdit).text != "", "map settings open")
	(tab._map_fields["name"] as LineEdit).text = "Main world"
	(tab._map_fields["ambient-light"] as SpinBox).value = 0.25
	tab.get_node("%AddMaskButton").pressed.emit()
	await _frames(2)
	var row: Node = tab.get_node("%MaskList").get_child(0)
	(row.get_node("min-x") as LineEdit).text = "-200"
	(row.get_node("max-x") as LineEdit).text = "200"
	await _shot("87_bluemap_map_settings")
	tab.get_node("%MapDialog").confirmed.emit()
	tab.get_node("%MapDialog").hide()
	await _wait_idle(tab)
	var got: Dictionary = await inst.call_op("bluemap_map_get", {"map": "world"})
	_check(got.map.values.name == "Main world" and got.map.masks.boxes.size() == 1 and int(got.map.masks.boxes[0].get("min-x", 0)) == -200
			and int(got.map.masks.boxes[0].get("max-x", 0)) == 200, "map settings saved from the dialog: %s" % [got.map.masks])
	tab._on_map_action("troubleshoot", _map(tab._state, "world"))
	await _frames(2)
	tab._troubleshoot()
	await _wait_for(func() -> bool: return tab.get_node("%TroubleResult").text not in ["", "Checking…"], 20.0)
	_check(tab.get_node("%TroubleResult").text != "", "troubleshoot answers: %s" % tab.get_node("%TroubleResult").text.replace("\n", " | "))
	await _shot("88_bluemap_troubleshoot")
	tab.get_node("%TroubleDialog").hide()
	var popup: PopupMenu = tab.get_node("%AddMapButton").get_popup()
	_check(popup.item_count >= 3, "Add map offers the dimensions")
	tab._on_add_map(1)
	await _wait_for(func() -> bool: return tab.get_node("%MapDialog").visible, 10.0)
	tab.get_node("%MapDialog").confirmed.emit()
	tab.get_node("%MapDialog").hide()
	await _wait_idle(tab)
	_check(tab._state.maps.size() == 4, "a second Nether map added: %s" % [tab._state.maps.map(func(m: Dictionary) -> String: return m.id)])

	# As a remote server admin.
	tab.get_node("%MapPageButton").button_pressed = true
	RemoteAccess.set_computer_name("Brian's PC")
	RemoteAccess.set_enabled(true, PORT)
	var alice := RemoteAccess.create_grant("Alice", RemoteProtocol.Role.SERVER_ADMIN, PackedStringArray([inst.config.id]))
	var link: RemoteLink = RemoteHosts.add_from_invite(RemoteAccess.invite_for(alice), "127.0.0.1").link
	await _wait_for(func() -> bool: return link.is_online() and not link.remote_servers().is_empty(), 20.0)
	var remote: RemoteServer = link.remote_servers()[0]
	main.show_server(remote.key())
	tabs.current_tab = _tab(tabs, "Plugins")
	plugins.open_integration("BlueMap")
	await _wait_for(func() -> bool: return tab.handle == remote and tab._shown_map != "", 30.0)
	await _wait_tiles(viewer)
	_check(tab.handle == remote and viewer._tiles.size() > 0, "a remote server admin sees the map: %d tiles" % viewer._tiles.size())
	await _shot("89_bluemap_remote")
	var res: Dictionary = await remote.call_op("bluemap_action", {"action": "update", "map": "world"})
	_check(res.ok, "a remote server admin renders: %s" % res.get("error", ""))
	RemoteHosts.remove(link)
	RemoteAccess.set_enabled(false, PORT)

	main.show_server(inst.config.id)
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 90.0)
	tab.refresh()
	await _wait_for(func() -> bool: return tab.handle == inst and not tab._state.get("ready", true), 20.0)
	await _wait_tiles(viewer)
	_check(viewer._tiles.size() > 0, "the map still shows while the server is stopped")
	await _shot("90_bluemap_stopped")
	if _failures.is_empty():
		ServerManager.delete_server(inst.config.id, true, true)
	print("\nBlueMap UI test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _row(plugins: PluginsTab, plugin_name: String) -> TreeItem:
	var root: TreeItem = (plugins.get_node("%PluginTree") as Tree).get_root()
	if root == null:
		return null
	for item in root.get_children():
		if str(item.get_metadata(1)) == plugin_name:
			return item
	return null


func _map(state: Dictionary, id: String) -> Dictionary:
	for m in state.get("maps", []):
		if m.id == id:
			return m
	return {}


func _drag(viewer: Control, button: MouseButton, delta: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	viewer._gui_input(down)
	var move := InputEventMouseMotion.new()
	move.relative = delta
	viewer._gui_input(move)
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	viewer._gui_input(up)


func _wheel(viewer: Control, button: MouseButton) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = true
	viewer._gui_input(e)


func _wait_tiles(viewer: BlueMapViewer) -> void:
	await _frames(20)
	await _wait_for(func() -> bool: return viewer._ready_to_draw and viewer._in_flight.is_empty() and viewer._jobs.is_empty() and not viewer._fetching, 60.0)
	await _frames(10)


func _wait_idle(tab: BlueMapTab) -> void:
	await _frames(2)
	await _wait_for(func() -> bool: return not tab._busy, 60.0)
	tab.refresh()
	await _wait_for(func() -> bool: return not tab._busy, 10.0)
	await _frames(20)


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
