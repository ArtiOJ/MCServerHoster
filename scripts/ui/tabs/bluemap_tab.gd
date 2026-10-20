class_name BlueMapTab
extends ServerTab
## BlueMap (3D map plugin): shows the rendered maps natively (see BlueMapViewer), and runs
## and configures BlueMap: the download consent it needs, render threads and tasks,
## render actions per map (update, fix edges, re-render, freeze, delete the render), maps
## for more dimensions, each map's settings and render areas, and BlueMap's own settings.
## Works the same for servers on other computers (see ServerOps.bluemap_*).
## Opened from the Plugins tab (see PluginsTab.INTEGRATIONS), not a tab of its own.

const POLL_SEC := 3.0
const ACTION_NAMES := {
	"update": "Update", "update-area": "Update an area…", "fix-edges": "Fix edges",
	"force-update": "Re-render all", "force-update-area": "Re-render an area…",
	"freeze": "Freeze", "unfreeze": "Unfreeze", "purge": "Delete the render…",
	"troubleshoot": "Why isn't it rendered?…",
}
const ACTION_TIPS := {
	"update": "Render what changed since the last render",
	"update-area": "Render what changed around a spot",
	"fix-edges": "Re-render the edges between rendered and unrendered parts",
	"force-update": "Render the whole map again, e.g. after changing its settings or resource packs",
	"force-update-area": "Render an area again",
	"freeze": "Stop updating this map automatically",
	"unfreeze": "Update this map automatically again",
	"purge": "Delete everything rendered for this map (it renders again unless frozen)",
	"troubleshoot": "Ask BlueMap why a spot isn't rendered (missing light data, outside the render areas, ...)",
}
## Labels and tooltips of the map settings (BlueMap.MAP_FIELDS).
const FIELDS := {
	"name": ["Name", "How the map is called in lists"],
	"sorting": ["Order", "Lower values come first in lists"],
	"start-pos": ["Start (x, z)", "Where the map opens"],
	"sky-color": ["Sky colour", "The sky behind the map"],
	"void-color": ["Void colour", "Where nothing is rendered"],
	"sky-light": ["Daylight", "How bright the map opens (0: night, only block light; 1: day)"],
	"ambient-light": ["Ambient light", "Light every block gets regardless of sun and block light (0..1)"],
	"remove-caves-below-y": ["Hide caves below Y", "Faces without sky light below this height aren't rendered (faster, smaller). Very low: render all caves. Needs a re-render."],
	"cave-detection-ocean-floor": ["Cave depth below ocean floor", "Cave hiding starts this many blocks below the ocean floor height. Very high: off. Needs a re-render."],
	"cave-detection-uses-block-light": ["Lit caves count as caves", "Use block light (torches) too when deciding what is a cave. Needs a re-render."],
	"min-inhabited-time": ["Only visited chunks", "Render only chunks players have spent at least this many ticks near (0: all). Needs a re-render."],
	"render-edges": ["Render cut edges", "Show the blocks where render areas cut the world instead of looking inside. Needs a re-render."],
	"edge-light-strength": ["Edge light", "Sky light (0..15) of blocks at render area edges. Needs a re-render."],
	"enable-perspective-view": ["3D view", "Allow the 3D view"],
	"enable-flat-view": ["Flat view", "Allow the top-down view"],
	"enable-free-flight-view": ["Free flight", "Allow flying around"],
	"enable-hires": ["Full 3D blocks", "Render full 3D blocks for close-ups (off: only the coarse map; much faster and smaller). Turning it on needs a re-render."],
	"ignore-missing-light-data": ["Render unlit chunks", "Render chunks saved without light data (WorldPainter exports, for one) fully lit, instead of skipping them. Better: load them once with Chunky's \"Load existing chunks\", which lights them. Needs a re-render."],
}

var _state := {}
var _serial := 0
var _busy := false
var _poll: Timer
var _shown_map := ""
var _editing := ""
var _creating_dimension := ""
var _map_fields := {}
var _confirm_action := Callable()
var _area_action := ""
var _area_map := ""
var _trouble_map := ""

@onready var _refresh_button: Button = %RefreshButton
@onready var _map_page_button: Button = %MapPageButton
@onready var _manage_page_button: Button = %ManagePageButton
@onready var _map_option: OptionButton = %MapOption
@onready var _status_label: Label = %StatusLabel
@onready var _browser_button: Button = %BrowserButton
@onready var _install_button: Button = %InstallButton
@onready var _notice: PanelContainer = %Notice
@onready var _notice_label: Label = %NoticeLabel
@onready var _consent_card: PanelContainer = %ConsentCard
@onready var _accept_button: Button = %AcceptButton
@onready var _map_page: VBoxContainer = %MapPage
@onready var _viewer: BlueMapViewer = %Viewer
@onready var _manage_page: ScrollContainer = %ManagePage
@onready var _threads_label: Label = %ThreadsLabel
@onready var _start_button: Button = %StartButton
@onready var _stop_button: Button = %StopButton
@onready var _reload_button: Button = %ReloadButton
@onready var _task_list: VBoxContainer = %TaskList
@onready var _cancel_all_button: Button = %CancelAllButton
@onready var _add_map_button: MenuButton = %AddMapButton
@onready var _map_list: VBoxContainer = %MapList
@onready var _threads_spin: SpinBox = %ThreadsSpin
@onready var _cooldown_spin: SpinBox = %CooldownSpin
@onready var _full_spin: SpinBox = %FullSpin
@onready var _pause_spin: SpinBox = %PauseSpin
@onready var _live_check: CheckBox = %LiveCheck
@onready var _web_check: CheckBox = %WebCheck
@onready var _port_spin: SpinBox = %PortSpin
@onready var _save_settings_button: Button = %SaveSettingsButton
@onready var _map_dialog: ConfirmationDialog = %MapDialog
@onready var _map_grid: GridContainer = %MapGrid
@onready var _mask_note: Label = %MaskNote
@onready var _mask_list: VBoxContainer = %MaskList
@onready var _add_mask_button: Button = %AddMaskButton
@onready var _area_dialog: ConfirmationDialog = %AreaDialog
@onready var _area_x: SpinBox = %AreaX
@onready var _area_z: SpinBox = %AreaZ
@onready var _area_radius: SpinBox = %AreaRadius
@onready var _confirm_dialog: ConfirmationDialog = %ConfirmDialog
@onready var _trouble_dialog: ConfirmationDialog = %TroubleDialog
@onready var _trouble_x: SpinBox = %TroubleX
@onready var _trouble_z: SpinBox = %TroubleZ
@onready var _trouble_result: Label = %TroubleResult


func _ready() -> void:
	_refresh_button.pressed.connect(refresh)
	_install_button.pressed.connect(_install)
	_accept_button.pressed.connect(_accept)
	_map_page_button.toggled.connect(func(_on: bool) -> void: _show())
	_manage_page_button.toggled.connect(func(_on: bool) -> void: _show())
	_map_option.item_selected.connect(func(_i: int) -> void: _open_selected_map())
	_browser_button.pressed.connect(func() -> void: OS.shell_open("http://localhost:%d" % int(_state.get("port", BlueMap.DEFAULT_PORT))))
	_start_button.pressed.connect(_control.bind("start"))
	_stop_button.pressed.connect(_control.bind("stop"))
	_reload_button.pressed.connect(_control.bind("reload"))
	_cancel_all_button.pressed.connect(_control.bind("cancel"))
	_add_map_button.get_popup().index_pressed.connect(_on_add_map)
	_save_settings_button.pressed.connect(_save_settings)
	_web_check.toggled.connect(func(on: bool) -> void: _port_spin.editable = on)
	_build_map_fields()
	_add_mask_button.pressed.connect(func() -> void:
		_mask_list.add_child(_mask_row({}))
		_update_mask_note())
	_map_dialog.confirmed.connect(_save_map)
	_area_dialog.confirmed.connect(func() -> void:
		_action(_area_action, _area_map, {"x": int(_area_x.value), "z": int(_area_z.value), "radius": int(_area_radius.value)}))
	_confirm_dialog.confirmed.connect(func() -> void:
		if _confirm_action.is_valid():
			_confirm_action.call())
	_trouble_dialog.get_ok_button().pressed.connect(_troubleshoot)
	_trouble_dialog.confirmed.connect(func() -> void: pass)
	_poll = Timer.new()
	_poll.wait_time = POLL_SEC
	_poll.timeout.connect(func() -> void:
		if is_visible_in_tree() and not _busy:
			refresh())
	add_child(_poll)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and handle != null:
			refresh()
		else:
			_poll.stop())


func _on_bound() -> void:
	_state = {}
	_shown_map = ""
	_viewer.clear()
	_show()
	watch(handle.state_changed, func(_s: ServerHandle.State) -> void:
		if is_visible_in_tree():
			refresh())
	watch(handle.data_changed, func(area: StringName) -> void:
		if area in [&"bluemap", &"plugins"] and is_visible_in_tree() and not _busy:
			refresh())
	if is_visible_in_tree():
		refresh()


func refresh() -> void:
	if handle == null:
		return
	_serial += 1
	var serial := _serial
	var h := handle
	var res: Dictionary = await h.call_op("bluemap_status")
	if serial != _serial or h != handle:
		return
	if not res.ok:
		_status_label.text = str(res.error)
		return
	_state = res
	_show()


func _show() -> void:
	var installed := bool(_state.get("installed", false))
	var accepted := bool(_state.get("accepted", false))
	var known := not _state.is_empty()
	_install_button.visible = known and not installed
	_status_label.text = _status_text()
	var note := str(_state.get("note", ""))
	if known and not installed:
		note = "BlueMap isn't installed. It renders the worlds into a 3D map you can look at here (and in a browser). Install it here; it loads on the next start."
	_notice.visible = note != ""
	_notice_label.text = note
	_consent_card.visible = installed and not accepted
	var usable := installed and accepted
	_map_page_button.visible = usable
	_manage_page_button.visible = usable
	var on_map := usable and _map_page_button.button_pressed
	_map_page.visible = on_map
	_manage_page.visible = usable and not on_map
	_map_option.visible = on_map and _state.get("maps", []).size() > 1
	_browser_button.visible = usable and handle is ServerInstance and bool(_state.get("ready", false)) and int(_state.get("port", 0)) > 0
	_fill_map_option()
	_fill_render()
	_fill_maps()
	_fill_settings()
	if on_map:
		_open_selected_map()
	var busy_render: bool = str(_state.get("threads", "")) == "running" or _state.get("tasks", []).any(func(t: Dictionary) -> bool: return t.state != "done")
	# New tiles show soon while BlueMap renders.
	_viewer.refresh_interval = 4.0 if busy_render else BlueMapViewer.REFRESH_SEC
	if busy_render and is_visible_in_tree() and handle != null and handle.is_online():
		if _poll.is_stopped():
			_poll.start()
	else:
		_poll.stop()


func _status_text() -> String:
	if _state.is_empty() or not bool(_state.get("installed", false)):
		return ""
	var parts := PackedStringArray(["BlueMap %s" % _state.get("version", "")])
	var rendering: Array = _state.get("maps", []).filter(func(m: Dictionary) -> bool: return m.state == "rendering")
	for m in rendering:
		parts.append("rendering %s: %d%%" % [m.name, roundi(float(m.progress) * 100.0)])
	return " · ".join(parts)


func _fill_map_option() -> void:
	var maps: Array = _state.get("maps", [])
	var keep := _selected_map_id()
	_map_option.clear()
	for m in maps:
		_map_option.add_item(str(m.name))
		_map_option.set_item_metadata(_map_option.item_count - 1, str(m.id))
		if str(m.id) == keep:
			_map_option.select(_map_option.item_count - 1)


func _selected_map_id() -> String:
	return str(_map_option.get_item_metadata(_map_option.selected)) if _map_option.selected >= 0 else ""


func _open_selected_map() -> void:
	var id := _selected_map_id()
	var map: Dictionary = {}
	for m in _state.get("maps", []):
		if str(m.id) == id:
			map = m
	if map.is_empty():
		if _shown_map != "":
			_viewer.clear()
			_shown_map = ""
		return
	if id == _shown_map:
		return
	if not bool(map.viewable):
		_viewer.clear()
		_shown_map = ""
		_viewer._show_empty(str(map.error) if str(map.error) != "" else "This map hasn't been rendered yet. Start the server; BlueMap renders it while it runs.")
		return
	_shown_map = id
	_viewer.open(handle, id, str(map.suffix))


# --- Renders ---------------------------------------------------------------------------

func _fill_render() -> void:
	var ready: bool = _state.get("ready", false) and bool(_state.get("loaded", false)) and not _busy
	var threads := str(_state.get("threads", ""))
	var count := int(_state.get("thread_count", 0))
	_threads_label.text = {
		"running": "%d render thread%s running" % [count, "" if count == 1 else "s"],
		"idle": "Idle: all maps are up to date",
		"stopped": "Stopped",
		"paused": "Paused while players are online",
	}.get(threads, "Start the server to render" if not handle_online() else ("Loading…" if _state.get("loading", false) else ""))
	_start_button.visible = threads == "stopped"
	_stop_button.visible = threads in ["running", "idle", "paused"]
	for b in [_start_button, _stop_button, _reload_button]:
		b.disabled = not ready
	_reload_button.disabled = not (_state.get("ready", false) and not _busy)
	for child in _task_list.get_children():
		child.queue_free()
	var waiting := 0
	for t in _state.get("tasks", []):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var badge := Label.new()
		badge.theme_type_variation = &"Badge" if t.state == "running" else &"MutedLabel"
		badge.text = {"done": "Done", "running": "Running", "pending": "Waiting"}.get(t.state, str(t.state))
		var text := Label.new()
		text.text = str(t.text)
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(badge)
		row.add_child(text)
		if t.state == "pending" and str(t.ref) != "":
			waiting += 1
			var cancel := Button.new()
			cancel.text = "Cancel"
			cancel.disabled = not ready
			cancel.pressed.connect(_control.bind("cancel", str(t.ref)))
			row.add_child(cancel)
		_task_list.add_child(row)
	_cancel_all_button.visible = waiting > 1
	_cancel_all_button.disabled = not ready


func handle_online() -> bool:
	return handle != null and handle.is_online()


func _control(action: String, ref := "") -> void:
	_busy = true
	_show()
	var res: Dictionary = await handle.call_op("bluemap_control", {"action": action, "ref": ref})
	_busy = false
	if not res.ok:
		Notifier.error(str(res.error))
	elif action == "reload":
		Notifier.success("BlueMap reloaded.")
	refresh()


# --- Maps ------------------------------------------------------------------------------

func _fill_maps() -> void:
	for child in _map_list.get_children():
		child.queue_free()
	var maps: Array = _state.get("maps", [])
	var ready: bool = _state.get("ready", false) and bool(_state.get("loaded", false)) and not _busy
	if maps.is_empty() and not _state.is_empty():
		var empty := Label.new()
		empty.theme_type_variation = &"MutedLabel"
		empty.text = "No maps yet. BlueMap adds the overworld, Nether and End when it first starts; add more with Add map."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_map_list.add_child(empty)
	for m in maps:
		_map_list.add_child(_map_row(m, ready))
	var popup := _add_map_button.get_popup()
	popup.clear()
	var mapped: Array = maps.map(func(m: Dictionary) -> String: return str(m.dimension))
	for d in _state.get("dimensions", []):
		popup.add_item("%s%s" % [d.label, " (has a map)" if mapped.has(d.dimension) else ""])
		popup.set_item_metadata(popup.item_count - 1, d)
	_add_map_button.disabled = _busy or popup.item_count == 0


func _map_row(m: Dictionary, ready: bool) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = str(m.name)
	title.tooltip_text = "%s (%s)" % [m.id, m.dimension]
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	var dim := Label.new()
	dim.theme_type_variation = &"MutedLabel"
	dim.text = str(m.dimension).trim_prefix("minecraft:")
	dim.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dim.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var badge := Label.new()
	var state := str(m.state)
	if bool(m.frozen):
		state = "frozen"
	badge.theme_type_variation = &"Badge" if state in ["rendering", "purging"] else &"MutedLabel"
	badge.text = {"updated": "Up to date", "rendering": "Rendering %d%%" % roundi(float(m.progress) * 100.0),
			"purging": "Deleting the render", "pending": "Waiting (%d)" % int(m.pending), "frozen": "Frozen"}.get(state, "")
	top.add_child(title)
	top.add_child(dim)
	top.add_child(badge)
	var view := Button.new()
	view.text = "View"
	view.disabled = not bool(m.viewable)
	view.tooltip_text = "Look at this map" if bool(m.viewable) else "Not rendered yet"
	view.pressed.connect(func() -> void:
		for i in _map_option.item_count:
			if str(_map_option.get_item_metadata(i)) == str(m.id):
				_map_option.select(i)
		_map_page_button.button_pressed = true)
	top.add_child(view)
	var render := MenuButton.new()
	render.text = "Render"
	render.flat = false
	render.tooltip_text = "Render actions (the server must be running)"
	render.disabled = not ready
	var popup := render.get_popup()
	for action in ["update", "update-area", "fix-edges", "force-update", "force-update-area", "unfreeze" if bool(m.frozen) else "freeze", "purge", "troubleshoot"]:
		popup.add_item(ACTION_NAMES[action])
		popup.set_item_metadata(popup.item_count - 1, action)
		popup.set_item_tooltip(popup.item_count - 1, ACTION_TIPS[action])
	popup.index_pressed.connect(func(i: int) -> void: _on_map_action(str(popup.get_item_metadata(i)), m))
	top.add_child(render)
	var settings := Button.new()
	settings.text = "Settings"
	settings.tooltip_text = "This map's settings and render areas"
	settings.disabled = _busy
	settings.pressed.connect(_edit_map.bind(str(m.id)))
	top.add_child(settings)
	var delete := Button.new()
	delete.icon = preload("res://assets/icons/trash.svg")
	delete.tooltip_text = "Remove this map and its rendered files"
	delete.disabled = _busy
	delete.pressed.connect(func() -> void:
		_ask("Remove the map %s and everything rendered for it?" % m.name, "Remove", _delete_map.bind(str(m.id))))
	top.add_child(delete)
	box.add_child(top)
	if state in ["rendering", "purging"]:
		var bar := ProgressBar.new()
		bar.max_value = 1.0
		bar.value = float(m.progress)
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		box.add_child(bar)
	return box


func _on_map_action(action: String, m: Dictionary) -> void:
	match action:
		"update-area", "force-update-area":
			_area_action = action.trim_suffix("-area")
			_area_map = str(m.id)
			var pos := _viewer._target if _shown_map == str(m.id) else Vector3.ZERO
			_area_x.value = roundi(pos.x)
			_area_z.value = roundi(pos.z)
			_area_dialog.title = "%s: %s" % [m.name, "update an area" if _area_action == "update" else "re-render an area"]
			_area_dialog.popup_centered()
		"purge":
			_ask("Delete everything rendered for %s? It renders again from scratch%s." % [m.name, " when unfrozen" if bool(m.frozen) else ""], "Delete the render", _action.bind("purge", str(m.id), {}))
		"force-update":
			_ask("Render all of %s again? Big maps take a long time." % m.name, "Re-render", _action.bind("force-update", str(m.id), {}))
		"troubleshoot":
			_trouble_map = str(m.id)
			var pos := _viewer._target if _shown_map == str(m.id) else Vector3.ZERO
			_trouble_x.value = roundi(pos.x)
			_trouble_z.value = roundi(pos.z)
			_trouble_result.text = ""
			_trouble_dialog.title = "%s: why isn't it rendered?" % m.name
			_trouble_dialog.popup_centered()
		_:
			_action(action, str(m.id), {})


func _action(action: String, id: String, area: Dictionary) -> void:
	_busy = true
	_show()
	var res: Dictionary = await handle.call_op("bluemap_action", {"action": action, "map": id, "area": area})
	_busy = false
	if res.ok:
		Notifier.success("BlueMap: %s." % res.text)
	else:
		Notifier.error(str(res.error))
	refresh()


func _troubleshoot() -> void:
	_trouble_result.text = "Checking…"
	var res: Dictionary = await handle.call_op("bluemap_troubleshoot", {"map": _trouble_map, "x": int(_trouble_x.value), "z": int(_trouble_z.value)})
	if not res.ok:
		_trouble_result.text = str(res.error)
		return
	var text := str(res.text).replace("BlueMap Troubleshooting >", "").strip_edges()
	if bool(res.get("missing_light", false)):
		text += "\n\nTo fix it: in Plugins, open Chunky and run \"Load existing chunks only\" for this world; loading gives the chunks their light. Then Re-render. (Or turn on \"Render unlit chunks\" in the map's settings.)"
	_trouble_result.text = text


func _ask(text: String, ok: String, action: Callable) -> void:
	_confirm_dialog.title = ok
	_confirm_dialog.dialog_text = text
	_confirm_dialog.ok_button_text = ok
	_confirm_action = action
	_confirm_dialog.popup_centered()


func _delete_map(id: String) -> void:
	_busy = true
	_show()
	var res: Dictionary = await handle.call_op("bluemap_map_delete", {"map": id})
	_busy = false
	if res.ok:
		Notifier.success("Map removed.")
		if _shown_map == id:
			_viewer.clear()
			_shown_map = ""
	else:
		Notifier.error(str(res.error))
	refresh()


func _on_add_map(index: int) -> void:
	var d: Dictionary = _add_map_button.get_popup().get_item_metadata(index)
	var ids: Array = _state.get("maps", []).map(func(m: Dictionary) -> String: return str(m.id))
	var id := str(d.id)
	var n := 2
	while ids.has(id):
		id = "%s_%d" % [d.id, n]
		n += 1
	_creating_dimension = str(d.dimension)
	_open_map_dialog(id, {"values": {"name": "%s (%s)" % [d.label, str(d.dimension).get_slice(":", 1)]}.merged(BlueMap.MAP_DEFAULTS), "masks": {"ok": true, "boxes": []}}, true)


func _edit_map(id: String) -> void:
	_busy = true
	var res: Dictionary = await handle.call_op("bluemap_map_get", {"map": id})
	_busy = false
	if not res.ok:
		Notifier.error(str(res.error))
		return
	_creating_dimension = ""
	_open_map_dialog(id, res.map, false)


# --- Map settings dialog -------------------------------------------------------------

func _build_map_fields() -> void:
	for key in BlueMap.MAP_FIELDS:
		var type: String = BlueMap.MAP_FIELDS[key]
		var label := Label.new()
		label.text = FIELDS[key][0]
		label.tooltip_text = FIELDS[key][1]
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		var field: Control
		match type:
			"string":
				var e := LineEdit.new()
				e.custom_minimum_size = Vector2(260, 0)
				field = e
			"int":
				field = _spin(-100000, 100000, 1)
				if key == "edge-light-strength":
					(field as SpinBox).min_value = 0
					(field as SpinBox).max_value = 15
				elif key == "min-inhabited-time":
					(field as SpinBox).min_value = 0
					(field as SpinBox).max_value = 100000000
					(field as SpinBox).suffix = "ticks"
			"float":
				field = _spin(0, 1, 0.05)
			"bool":
				field = CheckBox.new()
			"color":
				var c := ColorPickerButton.new()
				c.custom_minimum_size = Vector2(80, 28)
				c.edit_alpha = false
				field = c
			"pos":
				var row := HBoxContainer.new()
				var x := _spin(-30000000, 30000000, 1)
				x.prefix = "x"
				x.name = "X"
				var z := _spin(-30000000, 30000000, 1)
				z.prefix = "z"
				z.name = "Z"
				row.add_child(x)
				row.add_child(z)
				field = row
		field.tooltip_text = FIELDS[key][1]
		field.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		_map_grid.add_child(label)
		_map_grid.add_child(field)
		_map_fields[key] = field


func _spin(lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size = Vector2(130, 0)
	return s


func _open_map_dialog(id: String, config: Dictionary, creating: bool) -> void:
	_editing = id
	_map_dialog.title = "New map %s" % id if creating else "Map settings: %s" % id
	_map_dialog.ok_button_text = "Add map" if creating else "Save"
	for key in _map_fields:
		var field: Control = _map_fields[key]
		var v: Variant = config.values.get(key, BlueMap.MAP_DEFAULTS.get(key))
		match BlueMap.MAP_FIELDS[key]:
			"string":
				(field as LineEdit).text = str(v if v != null else id)
			"int", "float":
				(field as SpinBox).value = float(v) if v != null else 0.0
			"bool":
				(field as CheckBox).button_pressed = bool(v)
			"color":
				(field as ColorPickerButton).color = Color(str(v)) if str(v).begins_with("#") else Color.BLACK
			"pos":
				var p: Dictionary = v if v is Dictionary else {}
				(field.get_node("X") as SpinBox).value = float(p.get("x", 0))
				(field.get_node("Z") as SpinBox).value = float(p.get("z", 0))
	for child in _mask_list.get_children():
		child.queue_free()
	var masks: Dictionary = config.masks
	_mask_list.set_meta("custom", not bool(masks.ok))
	_add_mask_button.disabled = not bool(masks.ok)
	if masks.ok:
		for box in masks.boxes:
			_mask_list.add_child(_mask_row(box))
	_update_mask_note()
	_map_dialog.popup_centered()


func _mask_row(box: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for k in ["min-x", "max-x", "min-y", "max-y", "min-z", "max-z"]:
		var e := LineEdit.new()
		e.name = k
		e.placeholder_text = k
		e.custom_minimum_size = Vector2(76, 0)
		e.tooltip_text = "%s (empty: no limit)" % k
		e.text = str(box[k]) if box.get(k) != null else ""
		row.add_child(e)
	var subtract := CheckBox.new()
	subtract.name = "subtract"
	subtract.text = "Cut out"
	subtract.tooltip_text = "Remove this box from the render instead of limiting it to the box"
	subtract.button_pressed = bool(box.get("subtract", false))
	row.add_child(subtract)
	var remove := Button.new()
	remove.icon = preload("res://assets/icons/close.svg")
	remove.tooltip_text = "Remove this area"
	remove.pressed.connect(func() -> void:
		row.queue_free()
		_update_mask_note.call_deferred())
	row.add_child(remove)
	return row


func _update_mask_note() -> void:
	if _mask_list.get_meta("custom", false):
		_mask_note.text = "This map's render areas use shapes the editor doesn't know; edit plugins/BlueMap/maps/%s.conf to change them." % _editing
		return
	var count := _mask_list.get_children().filter(func(c: Node) -> bool: return not c.is_queued_for_deletion()).size()
	_mask_note.text = "No areas: everything that exists is rendered." if count == 0 else \
			"Only what is inside the areas is rendered (minus the cut-out ones). Empty fields: no limit."


func _map_values() -> Dictionary:
	var values := {}
	for key in _map_fields:
		var field: Control = _map_fields[key]
		match BlueMap.MAP_FIELDS[key]:
			"string":
				values[key] = (field as LineEdit).text.strip_edges()
			"int":
				values[key] = int((field as SpinBox).value)
			"float":
				values[key] = (field as SpinBox).value
			"bool":
				values[key] = (field as CheckBox).button_pressed
			"color":
				values[key] = "#" + (field as ColorPickerButton).color.to_html(false)
			"pos":
				values[key] = {"x": int((field.get_node("X") as SpinBox).value), "z": int((field.get_node("Z") as SpinBox).value)}
	return values


func _map_masks() -> Variant:
	if _mask_list.get_meta("custom", false):
		return null
	var boxes := []
	for row in _mask_list.get_children():
		if row.is_queued_for_deletion():
			continue
		var box := {}
		for k in ["min-x", "max-x", "min-y", "max-y", "min-z", "max-z"]:
			var t := (row.get_node(k) as LineEdit).text.strip_edges()
			if t.is_valid_int():
				box[k] = t.to_int()
		box["subtract"] = (row.get_node("subtract") as CheckBox).button_pressed
		boxes.append(box)
	return boxes


func _save_map() -> void:
	var id := _editing
	var creating := _creating_dimension != ""
	_busy = true
	_show()
	var res: Dictionary = await handle.call_op("bluemap_map_save", {"map": id, "values": _map_values(), "masks": _map_masks(), "dimension": _creating_dimension})
	_busy = false
	if not res.ok:
		Notifier.error(str(res.error))
	elif creating:
		Notifier.success("Map %s added.%s" % [id, " BlueMap renders it now." if res.reloaded else " BlueMap renders it when the server runs."])
	elif res.rerender:
		Notifier.info("Saved. Some changes only show after Render → Re-render all.")
	else:
		Notifier.success("Map settings saved.")
	if res.ok and _shown_map == id:
		_shown_map = ""  # Reopen with the new settings.
	refresh()


# --- BlueMap settings --------------------------------------------------------------------

func _fill_settings() -> void:
	var s: Dictionary = _state.get("settings", {})
	if s.is_empty() or _save_settings_button.has_meta("dirty"):
		return
	_threads_spin.value = float(s.get("render-thread-count", 1))
	_cooldown_spin.value = float(s.get("update-cooldown", 60))
	_full_spin.value = float(s.get("full-update-interval", 1440))
	_pause_spin.value = maxf(float(s.get("player-render-limit", -1)), 0.0)
	_live_check.button_pressed = bool(s.get("live-player-markers", true))
	_web_check.button_pressed = bool(s.get("webserver-enabled", true))
	_port_spin.value = float(s.get("webserver-port", BlueMap.DEFAULT_PORT))
	_port_spin.editable = _web_check.button_pressed
	_save_settings_button.disabled = _busy


func _save_settings() -> void:
	var values := {
		"render-thread-count": int(_threads_spin.value), "update-cooldown": int(_cooldown_spin.value),
		"full-update-interval": int(_full_spin.value), "player-render-limit": int(_pause_spin.value) if _pause_spin.value > 0 else -1,
		"live-player-markers": _live_check.button_pressed, "webserver-enabled": _web_check.button_pressed,
		"webserver-port": int(_port_spin.value),
	}
	_busy = true
	_show()
	var res: Dictionary = await handle.call_op("bluemap_settings_save", {"values": values})
	_busy = false
	if res.ok:
		Notifier.success("BlueMap settings saved%s." % (" and BlueMap reloaded" if res.reloaded else "; they apply when the server starts"))
	else:
		Notifier.error(str(res.error))
	refresh()


# --- Install and consent -----------------------------------------------------------------

func _install() -> void:
	_busy = true
	_install_button.disabled = true
	_status_label.text = "Installing BlueMap…"
	var res: Dictionary = await handle.call_op("plugin_install_modrinth", {"project_id": BlueMap.MODRINTH_ID})
	_busy = false
	_install_button.disabled = false
	if res.ok:
		Notifier.success("Installed BlueMap. %s" % ("Restart the server to load it." if handle.is_process_alive() else "It loads when the server starts."))
	else:
		Notifier.error(str(res.error))
	refresh()


func _accept() -> void:
	_busy = true
	_accept_button.disabled = true
	var res: Dictionary = await handle.call_op("bluemap_accept")
	_busy = false
	_accept_button.disabled = false
	if res.ok:
		Notifier.success("Accepted. %s" % ("BlueMap is downloading the textures and starts rendering." if res.reloaded else "BlueMap renders when the server runs."))
	else:
		Notifier.error(str(res.error))
	refresh()
