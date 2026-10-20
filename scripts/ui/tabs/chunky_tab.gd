class_name ChunkyTab
extends ServerTab
## Chunky (chunk pre-generation): start tasks (an area, the world border, or only the chunks
## that already exist), follow their progress, pause, continue or cancel them, and trim
## chunks outside or inside an area. Tasks run while the server is online (see Chunky and
## ServerOps.chunky_*). Works the same for servers on other computers.
## Opened from the Plugins tab (see PluginsTab.INTEGRATIONS), not a tab of its own.

## Area of each shape for a radius of 1, to estimate the number of chunks.
const SHAPE_AREA := {"square": 4.0, "circle": PI, "rectangle": 4.0, "ellipse": PI, "diamond": 2.0,
		"pentagon": 2.378, "hexagon": 2.598, "star": 1.12, "triangle": 1.299}
const POLL_SEC := 2.0

var _state := {}
var _serial := 0
var _busy := false
var _poll: Timer

@onready var _refresh_button: Button = %RefreshButton
@onready var _status_label: Label = %StatusLabel
@onready var _install_button: Button = %InstallButton
@onready var _notice: PanelContainer = %Notice
@onready var _notice_label: Label = %NoticeLabel
@onready var _tasks_card: PanelContainer = %TasksCard
@onready var _task_list: VBoxContainer = %TaskList
@onready var _no_tasks_label: Label = %NoTasksLabel
@onready var _new_card: PanelContainer = %NewCard
@onready var _world_option: OptionButton = %WorldOption
@onready var _mode_option: OptionButton = %ModeOption
@onready var _shape_label: Label = %ShapeLabel
@onready var _shape_option: OptionButton = %ShapeOption
@onready var _center_label: Label = %CenterLabel
@onready var _center_row: HBoxContainer = %CenterRow
@onready var _center_option: OptionButton = %CenterOption
@onready var _x_spin: SpinBox = %XSpin
@onready var _z_spin: SpinBox = %ZSpin
@onready var _radius_label: Label = %RadiusLabel
@onready var _radius_row: HBoxContainer = %RadiusRow
@onready var _radius_spin: SpinBox = %RadiusSpin
@onready var _radius_z_spin: SpinBox = %RadiusZSpin
@onready var _estimate_label: Label = %EstimateLabel
@onready var _start_button: Button = %StartButton
@onready var _trim_side_option: OptionButton = %TrimSideOption
@onready var _trim_button: Button = %TrimButton
@onready var _trim_dialog: ConfirmationDialog = %TrimDialog


func _ready() -> void:
	for i in Chunky.MODE_NAMES.size():
		_mode_option.add_item(Chunky.MODE_NAMES[i])
		_mode_option.set_item_tooltip(i, Chunky.MODE_TIPS[i])
	for name in Chunky.SHAPE_NAMES:
		_shape_option.add_item(name)
	for name in Chunky.CENTER_NAMES:
		_center_option.add_item(name)
	for option in [_mode_option, _shape_option, _center_option, _world_option, _trim_side_option]:
		option.item_selected.connect(_update_form.unbind(1))
	for spin in [_radius_spin, _radius_z_spin, _x_spin, _z_spin]:
		spin.value_changed.connect(_update_form.unbind(1))
	_refresh_button.pressed.connect(refresh)
	_install_button.pressed.connect(_install)
	_start_button.pressed.connect(_start)
	_trim_button.pressed.connect(_confirm_trim)
	_trim_dialog.confirmed.connect(_trim)
	_poll = Timer.new()
	_poll.wait_time = POLL_SEC
	_poll.timeout.connect(_on_poll)
	add_child(_poll)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and handle != null:
			refresh()
		else:
			_poll.stop())
	_update_form()


func _on_bound() -> void:
	_state = {}
	_show()
	watch(handle.state_changed, func(_s: ServerHandle.State) -> void:
		if is_visible_in_tree():
			refresh())
	watch(handle.data_changed, func(area: StringName) -> void:
		if area in [&"chunky", &"plugins"] and is_visible_in_tree():
			refresh())
	if is_visible_in_tree():
		refresh()


func refresh() -> void:
	if handle == null:
		return
	_serial += 1
	var serial := _serial
	var h := handle
	var res: Dictionary = await h.call_op("chunky_status")
	if serial != _serial or h != handle:
		return
	if not res.ok:
		_status_label.text = str(res.error)
		return
	_state = res
	_show()


## Keeps progress moving while a task runs.
func _on_poll() -> void:
	if is_visible_in_tree() and not _busy:
		refresh()


func _show() -> void:
	var installed := bool(_state.get("installed", false))
	_install_button.visible = not _state.is_empty() and not installed
	_status_label.text = ("Chunky %s" % _state.version) if installed and str(_state.get("version", "")) != "" else ""
	var note := str(_state.get("note", ""))
	if not installed and not _state.is_empty():
		note = "Chunky isn't installed. It pre-generates and loads chunks so players don't wait for them (and maps like BlueMap have them). Install it here; it loads on the next start."
	_notice.visible = note != ""
	_notice_label.text = note
	_tasks_card.visible = installed
	_new_card.visible = installed
	_fill_worlds()
	_fill_tasks()
	_update_form()
	var running: bool = _state.get("tasks", []).any(func(t: Dictionary) -> bool: return t.state == "running")
	if running and is_visible_in_tree():
		if _poll.is_stopped():
			_poll.start()
	else:
		_poll.stop()


func _fill_worlds() -> void:
	var keep: String = str(_world_option.get_item_metadata(_world_option.selected)) if _world_option.selected >= 0 else ""
	_world_option.clear()
	for w in _state.get("worlds", []):
		_world_option.add_item("%s (%s)" % [w.label, w.name])
		_world_option.set_item_metadata(_world_option.item_count - 1, str(w.name))
		if str(w.name) == str(keep):
			_world_option.select(_world_option.item_count - 1)


func _fill_tasks() -> void:
	for child in _task_list.get_children():
		child.queue_free()
	var tasks: Array = _state.get("tasks", [])
	_no_tasks_label.visible = tasks.is_empty()
	for t in tasks:
		_task_list.add_child(_task_row(t))


func _task_row(t: Dictionary) -> Control:
	var box := VBoxContainer.new()
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = str(t.world)
	var state := Label.new()
	state.theme_type_variation = &"Badge" if t.state == "running" else &"MutedLabel"
	state.text = {"running": "Running", "paused": "Paused", "finished": "Finished", "cancelled": "Cancelled"}.get(t.state, str(t.state))
	var detail := Label.new()
	detail.theme_type_variation = &"MutedLabel"
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var parts := PackedStringArray(["%d %s" % [int(t.processed), t.unit]])
	if t.state == "running" and str(t.get("eta", "")) != "":
		parts.append("%.0f chunks/s" % float(t.rate))
		parts.append("%s left" % t.eta)
	if t.state == "finished" and str(t.get("total_time", "")) != "":
		parts.append("took %s" % t.total_time)
	detail.text = " · ".join(parts)
	top.add_child(title)
	top.add_child(state)
	top.add_child(detail)
	var ready: bool = _state.get("ready", false) and not _busy
	if t.state == "running":
		top.add_child(_button("Pause", ready, _control.bind("pause", str(t.world))))
	if t.state == "paused":
		top.add_child(_button("Continue", ready, _control.bind("continue", str(t.world))))
	if t.state in ["running", "paused"]:
		top.add_child(_button("Cancel", ready, _control.bind("cancel", str(t.world))))
	var bar := ProgressBar.new()
	bar.max_value = 100.0
	bar.value = float(t.percent)
	bar.custom_minimum_size = Vector2(0, 8)
	box.add_child(top)
	box.add_child(bar)
	return box


func _button(text: String, enabled: bool, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	b.pressed.connect(action)
	return b


func _task() -> Dictionary:
	return {
		"world": str(_world_option.get_item_metadata(_world_option.selected)) if _world_option.selected >= 0 else "",
		"mode": _mode_option.selected, "shape": Chunky.SHAPES[maxi(_shape_option.selected, 0)],
		"center": _center_option.selected, "x": int(_x_spin.value), "z": int(_z_spin.value),
		"radius": int(_radius_spin.value), "radius_z": int(_radius_z_spin.value),
		"inside": _trim_side_option.selected == 1,
	}


func _update_form() -> void:
	var task := _task()
	var area: bool = task.mode == Chunky.Mode.AREA
	for c in [_shape_label, _shape_option, _center_label, _center_row, _radius_label, _radius_row]:
		c.visible = area
	_x_spin.visible = task.center == Chunky.Center.COORDINATES
	_z_spin.visible = _x_spin.visible
	_radius_z_spin.visible = Chunky.TWO_RADII.has(task.shape)
	var rz: float = _radius_z_spin.value if Chunky.TWO_RADII.has(task.shape) else _radius_spin.value
	var chunks: float = float(SHAPE_AREA.get(task.shape, 4.0)) * _radius_spin.value * rz / 256.0
	_estimate_label.text = "≈ %s chunks" % _count(int(chunks))
	var ready: bool = _state.get("ready", false) and not _busy
	_start_button.disabled = not ready or task.world == ""
	_trim_button.visible = area
	_trim_side_option.visible = area
	_trim_button.disabled = not ready or (task.inside and task.center != Chunky.Center.COORDINATES)
	_trim_button.tooltip_text = "Trimming inside an area needs its centre as coordinates." if task.inside and task.center != Chunky.Center.COORDINATES \
			else "Permanently delete the chunks outside (or inside) the area above, e.g. to shrink a world. A backup of the worlds is made first; restart the server afterwards."


static func _count(n: int) -> String:
	if n >= 1_000_000:
		return "%.1f million" % (n / 1_000_000.0)
	return str(n) if n < 10_000 else "%dk" % (n / 1000)


func _start() -> void:
	var task := _task()
	_busy = true
	_update_form()
	var res: Dictionary = await handle.call_op("chunky_start", {"task": task})
	_busy = false
	if res.ok:
		Notifier.success("Chunky started: %s." % res.text)
	else:
		Notifier.error(str(res.error))
	refresh()


func _control(action: String, world: String) -> void:
	_busy = true
	var res: Dictionary = await handle.call_op("chunky_control", {"action": action, "world": world})
	_busy = false
	if not res.ok:
		Notifier.error(str(res.error))
	refresh()


func _confirm_trim() -> void:
	var built := Chunky.trim_commands(_task())
	if not built.ok:
		Notifier.warn(str(built.error))
		return
	_trim_dialog.dialog_text = "Permanently %s?\n\nA backup of the worlds is saved to Backups first. Restart the server once the trim has finished." % built.text
	_trim_dialog.popup_centered()


func _trim() -> void:
	_busy = true
	_update_form()
	_status_label.text = "Backing up the worlds before trimming…"
	var res: Dictionary = await handle.call_op("chunky_trim", {"task": _task()}, func(text: String, _f: float) -> void: _status_label.text = text)
	_busy = false
	if res.ok:
		Notifier.success("Trimming: %s. Backup %s saved; restart %s when the task has finished." % [res.text, res.backup, handle.config.display_name])
	else:
		Notifier.error(str(res.error))
	refresh()


func _install() -> void:
	_busy = true
	_install_button.disabled = true
	_status_label.text = "Installing Chunky…"
	var res: Dictionary = await handle.call_op("plugin_install_modrinth", {"project_id": Chunky.MODRINTH_ID})
	_busy = false
	_install_button.disabled = false
	if res.ok:
		Notifier.success("Installed Chunky. %s" % ("Restart the server to load it." if handle.is_process_alive() else "It loads when the server starts."))
	else:
		Notifier.error(str(res.error))
	refresh()
