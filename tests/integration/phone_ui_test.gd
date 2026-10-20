extends Node
## Drives the phone app's main scene at a phone's screen size, connected over remote access
## to servers this test hosts (one server-admin key, one system-admin key), and saves
## screenshots of the computer list, every server tab and the dialogs, checking that each
## fits the screen's width. Must run with a display (not --headless).
## Usage: godot --path . res://tests/integration/phone_ui_test.tscn -- --no-autostart --profile=phui --root=<dir> --shots=<dir> [--no-start]

const PHONE_SCENE := preload("res://scenes/phone/phone_main.tscn")
const PORT := 25993

var _shots := ""
var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://phone-ui-test-servers")
	var start := true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--shots="):
			_shots = arg.get_slice("=", 1)
		elif arg == "--no-start":
			start = false
	DirAccess.make_dir_recursive_absolute(_shots)
	OS.low_processor_usage_mode = false
	AppSettings.server_dirs = PackedStringArray()
	AppSettings.servers_root = root
	_clean_profile_files()

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
	RemoteAccess.set_computer_name("Brian's PC")
	RemoteAccess.set_enabled(true, PORT)
	var alice := RemoteAccess.create_grant("Alice", RemoteProtocol.Role.SERVER_ADMIN, PackedStringArray([survival.config.id]))
	var bob := RemoteAccess.create_grant("Bob", RemoteProtocol.Role.SYSTEM_ADMIN, PackedStringArray())
	if start:
		survival.start()
		await _wait_for(func() -> bool: return survival.is_online() and survival.tps >= 0.0, 240.0)

	# From here on this process is "the phone": its own servers stay out of sight.
	AppSettings.phone = true
	var phone: PhoneMain = PHONE_SCENE.instantiate()
	add_child(phone)
	await _frames(10)
	_check(get_window().size == PhoneMain.DESKTOP_PHONE_SIZE, "window sized like a phone (%s)" % str(get_window().size))
	var width := get_viewport().get_visible_rect().size.x
	_check(phone.get_node("%EmptyBox").visible, "empty list explains how to add a computer")
	await _shot("01_empty")
	phone._open_add_computer()
	(phone.get_node("%CodeEdit") as TextEdit).text = "not an invite"
	phone._add_computer()
	_check((phone.get_node("%AddError") as Label).visible, "bad invite explained")
	await _shot("02_add_bad")
	await _check_dialog(phone.get_node("%AddComputerDialog"), width)
	(phone.get_node("%CodeEdit") as TextEdit).text = RemoteAccess.invite_for(bob)
	(phone.get_node("%AddressEdit") as LineEdit).text = "127.0.0.1"
	phone._add_computer()
	_check(not phone.get_node("%AddComputerDialog").visible, "good invite closes the dialog")
	var alice_link: RemoteLink = RemoteHosts.add_from_invite(RemoteAccess.invite_for(alice), "127.0.0.1").link
	var bob_link: RemoteLink = null
	for l in RemoteHosts.links():
		if l != alice_link:
			bob_link = l
	await _wait_for(func() -> bool: return alice_link.is_online() and bob_link.is_online() and bob_link.get_handles().size() == 2, 20.0)
	await get_tree().create_timer(2.0).timeout
	var cards: VBoxContainer = phone.get_node("%CardList")
	_check(cards.get_child_count() == 2 and not phone.get_node("%EmptyBox").visible, "both computers listed")
	var counts := []
	for card in cards.get_children():
		counts.append(card.get_node("%ServerList").get_child_count())
	counts.sort()
	_check(counts == [1, 2], "server admin sees one server, system admin both (%s)" % str(counts))
	_check(phone.get_node("%Home").get_combined_minimum_size().x <= width, "computer list fits")
	await _shot("03_home")

	# Every tab of a server, as its system admin.
	var bob_survival: ServerHandle = null
	for h in bob_link.get_handles():
		if h.config.display_name == "Survival":
			bob_survival = h
	phone.show_server(bob_survival.key())
	await get_tree().create_timer(1.5).timeout
	var view: ServerView = phone.get_node("%ServerView")
	var tabs := view.tabs()
	_check(not tabs.tabs_visible and view.get_node("TabStrip").visible, "tabs picked from the strip")
	var n := 10
	for i in tabs.get_tab_count():
		if tabs.is_tab_hidden(i):
			continue
		var tab_name := str(tabs.get_child(i).name)
		phone.open_tab(tab_name)
		await get_tree().create_timer(2.0 if tab_name != "Console" else 3.0).timeout
		var w := view.get_combined_minimum_size().x
		_check(w <= width, "%s tab fits (%d of %d)" % [tab_name, w, width])
		if w > width:
			_report_wide(view, width)
		await _shot("%02d_tab_%s" % [n, tab_name.to_lower()])
		n += 1
		if tab_name == "Plugins":
			var plugins: PluginsTab = tabs.get_child(i)
			for integration in ["LuckPerms", "Chunky", "BlueMap"]:
				plugins.open_integration(integration)
				await get_tree().create_timer(2.0).timeout
				w = view.get_combined_minimum_size().x
				_check(w <= width, "%s menu fits (%d of %d)" % [integration, w, width])
				if w > width:
					_report_wide(view, width)
				await _shot("%02d_menu_%s" % [n, integration.to_lower()])
				n += 1
				plugins.close_integration()

	# The header's menu and dialogs.
	phone.open_tab("Overview")
	await _frames(4)
	for pair in [["%UpdateDialog", "update"], ["%DeleteServerDialog", "delete"], ["%DuplicateServerDialog", "duplicate"], ["%ImportWorldDialog", "import_world"]]:
		var dialog: Window = phone.get_node(pair[0])
		dialog.open(bob_survival)
		await get_tree().create_timer(1.5).timeout
		await _check_dialog(dialog, width)
		await _shot("%02d_dialog_%s" % [n, pair[1]])
		n += 1
		dialog.hide()
	var wizard: NewServerWizard = phone.get_node("%NewServerWizard")
	phone._on_computer_action(bob_link, ComputerCard.MenuItem.NEW_SERVER)
	await get_tree().create_timer(1.0).timeout
	await _check_dialog(wizard, width)
	await _shot("%02d_dialog_wizard" % n)
	n += 1
	wizard.hide()
	for pair in [[ComputerCard.MenuItem.PREFERENCES, "%AppSettingsDialog", "preferences"], [ComputerCard.MenuItem.ACCESS_KEYS, "%RemoteDialog", "access_keys"],
			[ComputerCard.MenuItem.IMPORT_SERVER, "%ImportServerDialog", "import_server"], [ComputerCard.MenuItem.ADDRESS, "%AddressDialog", "address"],
			[ComputerCard.MenuItem.REMOVE, "%RemoveDialog", "remove"]]:
		phone._on_computer_action(bob_link, pair[0])
		await get_tree().create_timer(1.5).timeout
		var dialog: Window = phone.get_node(pair[1])
		await _check_dialog(dialog, width)
		await _shot("%02d_dialog_%s" % [n, pair[2]])
		n += 1
		dialog.hide()

	# A server-admin server.
	phone.show_home()
	var alice_survival: RemoteServer = alice_link.remote_servers()[0]
	phone.show_server(alice_survival.key())
	await get_tree().create_timer(1.5).timeout
	_check(view.get_combined_minimum_size().x <= width, "server-admin view fits")
	await _shot("%02d_server_admin" % n)
	n += 1
	phone.show_home()
	await _frames(4)

	# Touch: holding a finger shows the tooltip without pressing; a tap still presses.
	var add_button: Button = phone.get_node("%AddButton")
	var add_dialog: Window = phone.get_node("%AddComputerDialog")
	var presses := [0]
	add_button.pressed.connect(func() -> void: presses[0] += 1)
	var at := add_button.get_global_rect().get_center()
	_touch(0, at, true)
	await get_tree().create_timer(0.8).timeout
	var bubble: Node = phone.get_node_or_null("TouchTip")
	_check(bubble != null and _tip_text(bubble) == add_button.tooltip_text, "holding a button shows its tooltip")
	await _shot("%02d_long_press" % n)
	n += 1
	_touch(0, at, false)
	await _frames(4)
	_check(presses[0] == 0 and not add_dialog.visible, "lifting the finger after the tooltip doesn't press")
	_touch(0, at, true)
	await _frames(2)
	_touch(0, at, false)
	await _frames(4)
	_check(presses[0] == 1 and add_dialog.visible, "a tap presses")
	add_dialog.hide()
	await get_tree().create_timer(1.5).timeout
	_check(not is_instance_valid(bubble), "tooltip goes away")

	# Inside a dialog too.
	phone._open_add_computer()
	await get_tree().create_timer(0.5).timeout
	var address: Control = phone.get_node("%AddressEdit")
	at = address.get_global_rect().get_center() + Vector2(add_dialog.position)
	_touch(0, at, true)
	await get_tree().create_timer(0.8).timeout
	bubble = add_dialog.get_node_or_null("TouchTip")
	_check(bubble != null and _tip_text(bubble) == address.tooltip_text and add_dialog.size.y < get_viewport().get_visible_rect().size.y, "holding a field in a dialog shows its tooltip")
	await _shot("%02d_long_press_dialog" % n)
	n += 1
	_touch(0, at, false)
	await get_tree().create_timer(1.5).timeout
	_check(not is_instance_valid(bubble), "dialog tooltip goes away")
	add_dialog.hide()

	# Swiping scrolls the console like the rest of the app.
	phone.show_server(bob_survival.key())
	phone.open_tab("Console")
	await get_tree().create_timer(1.5).timeout
	var output: RichTextLabel = tabs.get_child(tabs.current_tab).get_node("%Output")
	var bar := output.get_v_scroll_bar()
	if bar.visible:
		bar.value = bar.max_value
		var before := bar.value
		var start_at := output.get_global_rect().get_center()
		_touch(0, start_at, true)
		for i in 10:
			_drag(0, start_at + Vector2(0, 20 * (i + 1)), Vector2(0, 20))
			await _frames(1)
		_touch(0, start_at + Vector2(0, 200), false)
		_check(bar.value < before - 100, "swiping down scrolls the console back (%d -> %d)" % [before, bar.value])
	else:
		print("SKIP console swipe: too few lines to scroll")
	phone.show_home()

	survival.stop()
	await _wait_for(func() -> bool: return not survival.is_process_alive(), 60.0)
	for l in RemoteHosts.links():
		RemoteHosts.remove(l)
	RemoteAccess.set_enabled(false)
	for i in ServerManager.get_instances().duplicate():
		ServerManager.delete_server(i.config.id, true, true)
	_clean_profile_files()
	print("\nPhone UI test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _check_dialog(dialog: Window, width: float) -> void:
	await _frames(3)
	_check(dialog.visible and dialog.size.x <= width and dialog.get_contents_minimum_size().x <= dialog.size.x + 1,
			"%s fits (%d wide, needs %d, screen %d)" % [dialog.name, dialog.size.x, dialog.get_contents_minimum_size().x, width])
	if dialog.get_contents_minimum_size().x > dialog.size.x + 1:
		for child in dialog.get_children():
			if child is Control:
				_report_wide(child, dialog.size.x - 16)


## Prints the deepest visible controls wider than [param width] (to see what to fix).
func _report_wide(node: Node, width: float, depth := 0) -> void:
	if depth > 30:
		return
	for child in node.get_children():
		if child is Control and child.visible and (child as Control).get_combined_minimum_size().x > width:
			var deeper := false
			for c in child.get_children():
				if c is Control and c.visible and (c as Control).get_combined_minimum_size().x > width:
					deeper = true
			if not deeper:
				print("   wide: %s (%s) %d" % [child.get_path(), child.get_class(), (child as Control).get_combined_minimum_size().x])
			else:
				_report_wide(child, width, depth + 1)


func _tip_text(tip: Node) -> String:
	return (tip.get_child(0).get_child(0) as Label).text


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	Input.parse_input_event(e)


func _drag(index: int, pos: Vector2, relative: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	e.relative = relative
	Input.parse_input_event(e)


func _clean_profile_files() -> void:
	for f in ["remote-access.json", "remote-hosts.json", "remote-host.key", "remote-host.crt"]:
		DirAccess.remove_absolute(AppSettings.profile_path(f))


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	await _frames(6)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shots.path_join(shot_name + ".png"))


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
