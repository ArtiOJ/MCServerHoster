class_name ScheduleRow
extends HBoxContainer
## Editor for one ScheduleEntry. Edits are written straight into [member entry].

signal changed
signal remove_requested

const ERROR_COLOR := Color("e05555")

var entry: ScheduleEntry

var _loading := false
var _time_re := RegEx.create_from_string("^([01]?\\d|2[0-3]):[0-5]\\d$")

@onready var _enabled_check: CheckBox = %EnabledCheck
@onready var _kind_option: OptionButton = %KindOption
@onready var _mode_option: OptionButton = %ModeOption
@onready var _time_edit: LineEdit = %TimeEdit
@onready var _interval_spin: SpinBox = %IntervalSpin
@onready var _command_edit: LineEdit = %CommandEdit
@onready var _warn_check: CheckBox = %WarnCheck
@onready var _next_label: Label = %NextLabel
@onready var _delete_button: Button = %DeleteButton


func _ready() -> void:
	_enabled_check.toggled.connect(func(on: bool) -> void: _edit(func() -> void: entry.enabled = on))
	_kind_option.item_selected.connect(func(i: int) -> void: _edit(func() -> void: entry.kind = i as ScheduleEntry.Kind))
	_mode_option.item_selected.connect(func(i: int) -> void: _edit(func() -> void: entry.mode = i as ScheduleEntry.Mode))
	_interval_spin.value_changed.connect(func(v: float) -> void: _edit(func() -> void: entry.interval_minutes = int(v)))
	_command_edit.text_changed.connect(func(t: String) -> void: _edit(func() -> void: entry.command = t))
	_warn_check.toggled.connect(func(on: bool) -> void: _edit(func() -> void: entry.warn_players = on))
	_time_edit.text_changed.connect(_on_time_changed)
	_delete_button.pressed.connect(func() -> void: remove_requested.emit())
	if entry != null:
		_load()


func setup(schedule: ScheduleEntry) -> void:
	entry = schedule
	if is_node_ready():
		_load()


## False when the row holds input that cannot be saved (e.g. a malformed time).
func is_valid() -> bool:
	return entry.mode != ScheduleEntry.Mode.DAILY or _time_re.search(_time_edit.text.strip_edges()) != null


func set_next_run(text: String) -> void:
	_next_label.text = text


func _load() -> void:
	_loading = true
	_enabled_check.button_pressed = entry.enabled
	_kind_option.select(entry.kind)
	_mode_option.select(entry.mode)
	_time_edit.text = entry.time_of_day
	_interval_spin.value = entry.interval_minutes
	_command_edit.text = entry.command
	_warn_check.button_pressed = entry.warn_players
	_loading = false
	_update_visibility()


func _edit(apply: Callable) -> void:
	if _loading or entry == null:
		return
	apply.call()
	_update_visibility()
	changed.emit()


func _on_time_changed(text: String) -> void:
	if _loading:
		return
	if _time_re.search(text.strip_edges()) != null:
		_time_edit.remove_theme_color_override("font_color")
		_time_edit.tooltip_text = "Local time of day (24-hour HH:MM)"
		entry.time_of_day = text.strip_edges()
	else:
		_time_edit.add_theme_color_override("font_color", ERROR_COLOR)
		_time_edit.tooltip_text = "Enter a time as HH:MM, e.g. 04:00"
	changed.emit()


func _update_visibility() -> void:
	var daily := entry.mode == ScheduleEntry.Mode.DAILY
	_time_edit.visible = daily
	_interval_spin.visible = not daily
	_command_edit.visible = entry.kind == ScheduleEntry.Kind.COMMAND
	_warn_check.visible = entry.kind == ScheduleEntry.Kind.RESTART
	modulate.a = 1.0 if entry.enabled else 0.6
