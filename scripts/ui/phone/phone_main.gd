class_name PhoneMain
extends Control
## Root of the phone app (iOS, Android). It runs no servers itself: it lists the computers
## added with invite codes, each with the servers its key opens, and shows a server with
## the same tabs as the desktop app, refitted to a narrow touch screen (see PhoneLayout).

## Size of the phone screen tried on a desktop with `-- --phone` (UI units).
const DESKTOP_PHONE_SIZE := Vector2i(390, 844)
## Text size choices offered in the menu: factor relative to the screen's own scale.
const TEXT_SIZES := {"Smaller": 0.9, "Normal": 0.0, "Larger": 1.15}
## Held this long (seconds) without moving, a finger shows the tooltip of what it touches.
const LONG_PRESS_SEC := 0.5
const LONG_PRESS_SLOP := 12.0
const CARD_SCENE := preload("res://scenes/phone/computer_card.tscn")

enum AppMenu { ADD_COMPUTER, TEXT_SIZE = 10 }

## Key of the server shown ("" = the computer list).
var _current_id := ""
var _scale := 1.0
var _safe := Rect2()
var _keyboard := 0.0
var _adapt_queued := false
var _sized_desktop := false
var _has_keyboard := DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD)
## Dialogs set up to be refitted whenever they open -> the height they were designed with.
var _adapted_windows := {}
## Dialogs being refitted right now.
var _fitting := {}
var _temp_queue: Array[ServerHandle] = []
var _link_target: RemoteLink
## Long press: where the finger went down, and since when (ticks msec; 0 = not down,
## -1 = moved, so a swipe).
var _press_pos := Vector2.ZERO
var _press_msec := 0
var _last_pos := Vector2.ZERO
var _touch_pos := Vector2.ZERO
var _bubble_shown := false
var _bubble_hide_msec := 0
## The tooltip shown by a long press (made when needed, inside the dialog it belongs to).
var _bubble: CanvasLayer

@onready var _safe_margin: MarginContainer = %SafeMargin
@onready var _back_button: Button = %BackButton
@onready var _title_label: Label = %TitleLabel
@onready var _add_button: Button = %AddButton
@onready var _app_menu: MenuButton = %AppMenu
@onready var _home: ScrollContainer = %Home
@onready var _card_list: VBoxContainer = %CardList
@onready var _empty_box: VBoxContainer = %EmptyBox
@onready var _add_first_button: Button = %AddFirstButton
@onready var _server_view: ServerView = %ServerView
@onready var _wizard: NewServerWizard = %NewServerWizard
@onready var _delete_dialog: DeleteServerDialog = %DeleteServerDialog
@onready var _update_dialog: UpdateDialog = %UpdateDialog
@onready var _settings_dialog: AppSettingsDialog = %AppSettingsDialog
@onready var _duplicate_dialog: DuplicateServerDialog = %DuplicateServerDialog
@onready var _temp_dialog: TempRunDialog = %TempRunDialog
@onready var _import_server_dialog: ImportServerDialog = %ImportServerDialog
@onready var _import_world_dialog: ImportWorldDialog = %ImportWorldDialog
@onready var _remote_dialog: RemoteDialog = %RemoteDialog
@onready var _add_dialog: ConfirmationDialog = %AddComputerDialog
@onready var _code_edit: TextEdit = %CodeEdit
@onready var _paste_button: Button = %PasteButton
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _add_error: Label = %AddError
@onready var _address_dialog: ConfirmationDialog = %AddressDialog
@onready var _link_address_edit: LineEdit = %LinkAddressEdit
@onready var _remove_dialog: ConfirmationDialog = %RemoveDialog


func _ready() -> void:
	get_tree().auto_accept_quit = true
	get_tree().node_added.connect(_on_node_added)
	for node in find_children("*", "Window", true, false):
		_on_node_added(node)
	_fit_screen()
	get_window().size_changed.connect(_fit_screen)
	_server_view.use_phone_layout()

	_back_button.pressed.connect(show_home)
	_add_button.pressed.connect(_open_add_computer)
	_add_first_button.pressed.connect(_open_add_computer)
	_app_menu.about_to_popup.connect(_fill_app_menu)
	_app_menu.get_popup().id_pressed.connect(_on_app_menu)
	_paste_button.pressed.connect(func() -> void: _code_edit.text = DisplayServer.clipboard_get().strip_edges())
	_add_dialog.get_ok_button().text = "Add"
	_add_dialog.confirmed.connect(_add_computer)
	_address_dialog.confirmed.connect(_save_address)
	_remove_dialog.confirmed.connect(func() -> void:
		if _link_target != null and is_instance_valid(_link_target):
			RemoteHosts.remove(_link_target)
		_link_target = null)

	_server_view.update_requested.connect(_update_dialog.open)
	_server_view.delete_requested.connect(_delete_dialog.open)
	_server_view.duplicate_requested.connect(_duplicate_dialog.open)
	_server_view.temp_decision_requested.connect(_temp_dialog.open)
	_server_view.import_world_requested.connect(func(h: ServerHandle) -> void: _import_world_dialog.open(h))
	_import_server_dialog.imported.connect(func(h: ServerHandle) -> void: show_server(h.key()))
	_wizard.server_created.connect(func(h: ServerHandle) -> void: show_server(h.key()))
	_duplicate_dialog.duplicated.connect(func(h: ServerHandle) -> void:
		if h != null:
			show_server(h.key()))
	_temp_dialog.visibility_changed.connect(_show_next_temp_decision)
	RemoteHosts.links_changed.connect(_rebuild_cards)
	RemoteHosts.server_added.connect(func(server: RemoteServer) -> void:
		server.temporary_run_ended.connect(_on_temporary_run_ended.bind(server)))
	RemoteHosts.server_removed.connect(func(key: String) -> void:
		if key == _current_id:
			show_home())
	_rebuild_cards()
	show_home()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			# Android's back gesture: from a server back to the list, from the list out.
			if _current_id != "":
				show_home()
			else:
				get_tree().quit()
		NOTIFICATION_APPLICATION_RESUMED:
			# The phone suspends the app's connections while it is in the background.
			for link in RemoteHosts.links():
				if link.status == RemoteLink.Status.OFFLINE:
					link.connect_now()


# --- Screen ------------------------------------------------------------------------

## Scales the interface to the phone's pixel density and keeps it clear of the notch,
## the home indicator and the on-screen keyboard.
func _fit_screen() -> void:
	var window := get_window()
	if not OS.has_feature("mobile"):
		if not _sized_desktop and DisplayServer.get_name() != "headless":
			_sized_desktop = true
			window.min_size = Vector2i(320, 560)
			window.size = DESKTOP_PHONE_SIZE
		_scale = 1.0
	else:
		var screen := window.current_screen
		var density := DisplayServer.screen_get_scale(screen)
		if density <= 1.0:
			density = maxf(DisplayServer.screen_get_dpi(screen) / 160.0, 1.0)
		_scale = density * (AppSettings.ui_scale if AppSettings.ui_scale > 0.0 else 1.0)
	window.content_scale_factor = _scale
	var full := Rect2(Vector2.ZERO, Vector2(DisplayServer.screen_get_size(window.current_screen)))
	_safe = Rect2(DisplayServer.get_display_safe_area()) if OS.has_feature("mobile") else full
	_apply_insets()
	_queue_adapt()


func _apply_insets() -> void:
	var window_px := Vector2(get_window().size)
	var left := maxf(_safe.position.x, 0.0) / _scale
	var top := maxf(_safe.position.y, 0.0) / _scale
	var right := maxf(window_px.x - _safe.end.x, 0.0) / _scale if _safe.size.x > 0 else 0.0
	var bottom := maxf(window_px.y - _safe.end.y, 0.0) / _scale if _safe.size.y > 0 else 0.0
	bottom = maxf(bottom, _keyboard / _scale)
	_safe_margin.add_theme_constant_override("margin_left", int(left))
	_safe_margin.add_theme_constant_override("margin_top", int(top))
	_safe_margin.add_theme_constant_override("margin_right", int(right))
	_safe_margin.add_theme_constant_override("margin_bottom", int(bottom))


func _process(_delta: float) -> void:
	var keyboard := float(DisplayServer.virtual_keyboard_get_height()) if _has_keyboard else 0.0
	if keyboard != _keyboard:
		_keyboard = keyboard
		_apply_insets()
	_track_touch()
	if Engine.get_process_frames() % 10 == 0:
		_grow_open_dialogs()


## Width the screens are fitted to (UI units).
func content_width() -> float:
	return get_viewport_rect().size.x - _safe_margin.get_theme_constant("margin_left") - _safe_margin.get_theme_constant("margin_right")


func _queue_adapt() -> void:
	if _adapt_queued:
		return
	_adapt_queued = true
	_adapt_now.call_deferred()


func _adapt_now() -> void:
	_adapt_queued = false
	if not is_inside_tree():
		return
	PhoneLayout.adapt(_server_view, content_width())
	PhoneLayout.adapt(_home, content_width())
	for window: Window in _adapted_windows.keys():
		if is_instance_valid(window) and window.visible:
			_fit_dialog(window)


## Rows added to a screen later (lists filling in, dialogs opening) are refitted too.
func _on_node_added(node: Node) -> void:
	if is_instance_valid(_bubble) and (node == _bubble or _bubble.is_ancestor_of(node)):
		return
	if node is Window and not node is Popup and not _adapted_windows.has(node):
		# Remembers the height the dialog was designed with: dialogs whose contents scroll
		# report hardly any minimum height of their own.
		_adapted_windows[node] = (node as Window).size.y
		var dialog := node as Window
		# Without the phone's own file picker, files are picked from the app's folder, which
		# iOS shows in the Files app (put plugins or worlds there to upload them).
		if dialog is FileDialog and not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
			(dialog as FileDialog).current_dir = OS.get_user_data_dir()
		dialog.window_input.connect(func(e: InputEvent) -> void: _note_position(e, Vector2(dialog.position)))
		dialog.visibility_changed.connect(func() -> void:
			if dialog.visible:
				_fit_dialog.call_deferred(dialog))
	elif node is Control and is_ancestor_of(node):
		_queue_adapt()
	elif node is Control:
		var window := node.get_window()
		if window != get_window() and window != null and window.visible:
			_fit_dialog.call_deferred(window)


## Makes a dialog as wide as the screen and as tall as its contents need (they scroll when
## taller than the screen), and refits its rows.
func _fit_dialog(window: Window) -> void:
	if not is_instance_valid(window) or not window.visible or _fitting.has(window):
		return
	_fitting[window] = true
	var screen := get_viewport_rect().size
	var width := floorf(minf(screen.x - 16.0, 560.0))
	# An embedded window's title bar sits above its position.
	var title := float(window.get_theme_constant("title_height")) if not window.borderless else 0.0
	var top := float(_safe_margin.get_theme_constant("margin_top")) + 8.0 + title
	var bottom := float(_safe_margin.get_theme_constant("margin_bottom")) + 8.0
	var max_height := screen.y - top - bottom
	window.min_size = Vector2i.ZERO
	# Width first, so wrapping text knows how many lines it takes.
	window.size = Vector2i(int(width), mini(window.size.y, int(max_height)))
	if not window is FileDialog:
		for child in window.get_children():
			if child is Control:
				PhoneLayout.adapt(child, width - 40.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_fitting.erase(window)
	if not is_instance_valid(window) or not window.visible:
		return
	var height := max_height
	# Lists that scroll inside the dialog get all the room there is.
	if not window is FileDialog and window.find_children("*", "ScrollContainer", true, false).is_empty():
		height = maxf(_needed_height(window), minf(float(_adapted_windows.get(window, 0)), max_height))
		if height > max_height:
			_scroll_contents(window)
		height = clampf(height, 120.0, max_height)
	window.size = Vector2i(int(width), int(height))
	window.position = Vector2i(int((screen.x - width) / 2.0), int(top + (max_height - height) / 2.0))


## Height a dialog needs to show all of its contents without scrolling.
func _needed_height(window: Window) -> float:
	var needed := window.get_contents_minimum_size().y
	for child in window.get_children():
		if child is ScrollContainer and child.get_child_count() > 0 and child.get_child(0) is Control:
			needed += (child.get_child(0) as Control).get_combined_minimum_size().y - (child as Control).get_combined_minimum_size().y
	return needed


## Contents taller than the screen go inside a scroll area.
func _scroll_contents(window: Window) -> void:
	for child in window.get_children():
		if child is Control and not child is ScrollContainer:
			var scroll := ScrollContainer.new()
			scroll.name = "PhoneScroll"
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			window.add_child(scroll)
			window.move_child(scroll, child.get_index())
			child.reparent(scroll, false)
			(child as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
			return


## Grows a dialog whose contents got taller while open (an error appearing, a list filling).
func _grow_open_dialogs() -> void:
	for window: Window in _adapted_windows.keys():
		if is_instance_valid(window) and window.visible and not _fitting.has(window) and not window is FileDialog:
			var max_height := get_viewport_rect().size.y - 16.0 - window.get_theme_constant("title_height") \
					- _safe_margin.get_theme_constant("margin_top") - _safe_margin.get_theme_constant("margin_bottom")
			if _needed_height(window) > window.size.y + 1 and window.size.y < max_height - 1:
				_fit_dialog(window)


# --- Touch ---------------------------------------------------------------------------

## Touch screens have no hover: holding a finger on a control shows its tooltip, and lists
## and text areas scroll with a swipe like the rest of the app. Read from the finger's
## state each frame (touches arrive as mouse input), so it works over dialogs too.
func _track_touch() -> void:
	var down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var pos := _touch_pos
	var now := Time.get_ticks_msec()
	if not down:
		if _press_msec != 0 and _bubble_shown and _bubble_hide_msec == 0:
			_bubble_hide_msec = now + 1200
		_press_msec = 0
	elif _press_msec == 0:
		_press_msec = now
		_press_pos = pos
		_last_pos = pos
	else:
		if pos.distance_to(_press_pos) > LONG_PRESS_SLOP and not _bubble_shown:
			_press_msec = -1  # Moving: a swipe, not a long press.
		if _press_msec == -1 and pos != _last_pos and pos.x > -100.0:
			_scroll_under(pos, pos - _last_pos)
		elif _press_msec > 0 and not _bubble_shown and now - _press_msec >= LONG_PRESS_SEC * 1000:
			_show_tooltip_at(pos)
		_last_pos = pos
	if _bubble_hide_msec > 0 and now >= _bubble_hide_msec:
		_bubble_hide_msec = 0
		_bubble_shown = false
		if is_instance_valid(_bubble):
			_bubble.queue_free()


## Where the finger (or mouse) is, from the input events of the app and its dialogs.
func _input(event: InputEvent) -> void:
	_note_position(event, Vector2.ZERO)


func _note_position(event: InputEvent, offset: Vector2) -> void:
	if event is InputEventMouse:
		_touch_pos = (event as InputEventMouse).position + offset
	elif event is InputEventScreenTouch:
		_touch_pos = (event as InputEventScreenTouch).position + offset
	elif event is InputEventScreenDrag:
		_touch_pos = (event as InputEventScreenDrag).position + offset


## The open dialog under [param pos] (the topmost), or null.
func _window_at(pos: Vector2) -> Window:
	var windows := get_viewport().get_embedded_subwindows()
	for i in range(windows.size() - 1, -1, -1):
		var window: Window = windows[i]
		if window.visible and Rect2(window.position, window.size).has_point(pos):
			return window
	return null


## The control under [param pos], in the topmost open dialog when there is one there.
## (Found by position: a touch that hasn't moved doesn't update what counts as hovered.)
func _control_at(pos: Vector2) -> Control:
	var window := _window_at(pos)
	return _find_control(window, pos - Vector2(window.position)) if window != null else _find_control(self, pos)


## The topmost visible control under [param pos] (in [param root]'s viewport) that takes
## touches, or null.
func _find_control(root: Node, pos: Vector2) -> Control:
	for i in range(root.get_child_count(true) - 1, -1, -1):
		var child := root.get_child(i, true)
		if child is Window or (child is CanvasItem and not (child as CanvasItem).visible):
			continue
		var control := child as Control
		if control != null and control.clip_contents and not control.get_global_rect().has_point(pos):
			continue
		var found := _find_control(child, pos)
		if found != null:
			return found
		if control != null and control.mouse_filter != Control.MOUSE_FILTER_IGNORE and control.get_global_rect().has_point(pos):
			return control
	return null


func _scroll_under(pos: Vector2, delta: Vector2) -> void:
	var node: Node = _control_at(pos)
	while node != null and node is Control:
		if node is ScrollContainer:
			if not DisplayServer.is_touchscreen_available():
				(node as ScrollContainer).scroll_vertical -= int(delta.y)
			return  # Touch screens: it scrolls by itself.
		if node is Tree or node is ItemList or node is RichTextLabel or node is TextEdit:
			var bar: ScrollBar = node.get_v_scroll_bar()
			if bar != null and bar.visible:
				bar.value -= delta.y
			return
		node = node.get_parent()


func _show_tooltip_at(pos: Vector2) -> void:
	var node: Node = _control_at(pos)
	var text := ""
	while node != null and node is Control and text == "":
		var control := node as Control
		text = control.get_tooltip(control.get_global_transform_with_canvas().affine_inverse() * pos)
		node = node.get_parent()
	if text == "":
		_press_msec = -1
		return
	_bubble_shown = true
	_bubble_hide_msec = 0
	# Moves the touch off the control first, so lifting the finger doesn't press it.
	var away := InputEventMouseMotion.new()
	away.position = Vector2(-1000, -1000)
	away.global_position = away.position
	away.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(away)
	# Shown inside the dialog under the finger, if any: dialogs are drawn above the app.
	var window := _window_at(pos)
	var host: Node = window if window != null else self
	var area := Rect2(Vector2.ZERO, Vector2(window.size)) if window != null else get_viewport_rect()
	var local := pos - (Vector2(window.position) if window != null else Vector2.ZERO)
	if is_instance_valid(_bubble):
		_bubble.queue_free()
	# On a layer of its own: a dialog lays out every control it holds as its contents.
	_bubble = CanvasLayer.new()
	_bubble.name = "TouchTip"
	_bubble.layer = 100
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"ToastPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	_bubble.add_child(panel)
	host.add_child(_bubble, false, Node.INTERNAL_MODE_BACK)
	var width := minf(area.size.x - 24.0, 340.0)
	var padding := panel.get_theme_stylebox("panel").get_minimum_size()
	label.custom_minimum_size.x = width - padding.x
	panel.modulate.a = 0.0
	_place_bubble(panel, local, area)


## Sizes and places the tooltip once its text has wrapped to its width (a wrapping label
## only knows its height after a layout pass).
func _place_bubble(panel: PanelContainer, local: Vector2, area: Rect2) -> void:
	await get_tree().process_frame
	if not is_instance_valid(panel):
		return
	panel.reset_size()
	var bubble_size := panel.size
	var at := local - Vector2(bubble_size.x / 2.0, bubble_size.y + 48.0)
	if at.y < 12.0:
		at.y = local.y + 48.0
	panel.position = at.clamp(Vector2(12, 12), area.size - bubble_size - Vector2(12, 12))
	panel.modulate.a = 1.0


# --- Pages ---------------------------------------------------------------------------

func show_home() -> void:
	_current_id = ""
	_home.visible = true
	_server_view.visible = false
	_back_button.visible = false
	_add_button.visible = true
	_title_label.text = "Server Manager"
	for card in _card_list.get_children():
		if card is ComputerCard:
			card.refresh()


func show_server(handle_key: String) -> void:
	var server := RemoteHosts.find_server(handle_key)
	if server == null:
		show_home()
		return
	_current_id = handle_key
	_server_view.show_instance(server)
	_server_view.visible = true
	_home.visible = false
	_back_button.visible = true
	_add_button.visible = false
	_title_label.text = server.host_name()
	_queue_adapt()


## Opens the tab named [param tab_name] of the server shown (used by tests and links).
func open_tab(tab_name: String) -> void:
	var tabs := _server_view.tabs()
	for i in tabs.get_tab_count():
		if str(tabs.get_child(i).name) == tab_name:
			tabs.current_tab = i
			_queue_adapt()


func _rebuild_cards() -> void:
	for card in _card_list.get_children():
		_card_list.remove_child(card)
		card.queue_free()
	for link in RemoteHosts.links():
		var card: ComputerCard = CARD_SCENE.instantiate()
		_card_list.add_child(card)
		card.setup(link)
		card.server_open_requested.connect(show_server)
		card.action_requested.connect(_on_computer_action)
	_empty_box.visible = RemoteHosts.links().is_empty()


func _on_computer_action(link: RemoteLink, id: int) -> void:
	match id:
		ComputerCard.MenuItem.WAKE:
			link.wake()
			Notifier.info("Waking %s…" % link.source_name())
		ComputerCard.MenuItem.RECONNECT:
			if link.status == RemoteLink.Status.ONLINE or link.status == RemoteLink.Status.CONNECTING:
				link.disconnect_now()
			else:
				link.connect_now()
		ComputerCard.MenuItem.NEW_SERVER:
			_wizard.open(link)
		ComputerCard.MenuItem.IMPORT_SERVER:
			_import_server_dialog.open("", link)
		ComputerCard.MenuItem.ACCESS_KEYS:
			_remote_dialog.open(RemoteDialog.TabIndex.SHARE, link)
		ComputerCard.MenuItem.PREFERENCES:
			_settings_dialog.open(link)
		ComputerCard.MenuItem.ADDRESS:
			_link_target = link
			_link_address_edit.text = ", ".join(link.addresses)
			_address_dialog.popup_centered()
		ComputerCard.MenuItem.REMOVE:
			_link_target = link
			_remove_dialog.dialog_text = "Remove %s? You can add it again with its invite code." % link.source_name()
			_remove_dialog.popup_centered()


func _fill_app_menu() -> void:
	var menu := _app_menu.get_popup()
	menu.clear()
	menu.add_item("Add computer…", AppMenu.ADD_COMPUTER)
	menu.add_separator("Text size")
	var i := 0
	for size_name: String in TEXT_SIZES:
		menu.add_radio_check_item(size_name, AppMenu.TEXT_SIZE + i)
		menu.set_item_checked(menu.item_count - 1, is_equal_approx(AppSettings.ui_scale, TEXT_SIZES[size_name]))
		i += 1


func _on_app_menu(id: int) -> void:
	if id == AppMenu.ADD_COMPUTER:
		_open_add_computer()
	elif id >= AppMenu.TEXT_SIZE:
		AppSettings.ui_scale = TEXT_SIZES.values()[id - AppMenu.TEXT_SIZE]
		AppSettings.save_settings()
		_fit_screen()


func _open_add_computer() -> void:
	_code_edit.text = ""
	_address_edit.text = ""
	_add_error.text = ""
	_add_error.visible = false
	_add_dialog.popup_centered()


func _add_computer() -> void:
	var res := RemoteHosts.add_from_invite(_code_edit.text.strip_edges(), _address_edit.text)
	if not res.ok:
		_add_error.text = res.error
		_add_error.visible = true
		return
	_add_dialog.hide()
	Notifier.info("Connecting to %s…" % (res.link as RemoteLink).source_name())


func _save_address() -> void:
	if _link_target == null or not is_instance_valid(_link_target):
		return
	var addresses := PackedStringArray()
	for part in _link_address_edit.text.split(",", false):
		if part.strip_edges() != "":
			addresses.append(part.strip_edges())
	if addresses.is_empty():
		Notifier.warn("Enter at least one address.")
		return
	RemoteHosts.set_addresses(_link_target, addresses, _link_target.port)


# --- Temporary runs --------------------------------------------------------------------

func _on_temporary_run_ended(inst: ServerHandle) -> void:
	if _temp_dialog.visible:
		if not _temp_queue.has(inst):
			_temp_queue.append(inst)
		return
	_temp_dialog.open(inst)


func _show_next_temp_decision() -> void:
	if _temp_dialog.visible:
		return
	while not _temp_queue.is_empty():
		var inst: ServerHandle = _temp_queue.pop_front()
		if is_instance_valid(inst) and inst.is_temporary() and not inst.is_process_alive():
			_temp_dialog.open.call_deferred(inst)
			return
