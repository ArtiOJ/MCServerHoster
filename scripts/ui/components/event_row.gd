class_name EventRow
extends PanelContainer
## Editor for one [EventRule]: a compact summary line that expands into the full
## "When / Days / Only between / Only if / Do" editor. Edits are written straight
## into the bound rule.

signal changed
signal remove_requested
signal expanded_changed(expanded: bool)

## Monday-first display order mapped to Godot weekday numbers (0 = Sunday).
const DAY_ORDER: Array[int] = [1, 2, 3, 4, 5, 6, 0]
const DAY_PRESETS: Array[int] = [EventRule.ALL_DAYS, 0b0111110, 0b1000001]
const CHEVRON_DOWN := preload("res://assets/icons/chevron_down.svg")
const CHEVRON_UP := preload("res://assets/icons/chevron_up.svg")

var rule: EventRule
var scheduler: TaskScheduler
## The saved rule this draft corresponds to (set by the tab when unchanged), used for exact next-run times.
var saved_rule: EventRule

var _suppress := false
var _day_buttons: Array[Button] = []

@onready var _enabled_check: CheckButton = %EnabledCheck
@onready var _summary_label: Label = %SummaryLabel
@onready var _next_run_label: Label = %NextRunLabel
@onready var _invalid_badge: Label = %InvalidBadge
@onready var _expand_button: Button = %ExpandButton
@onready var _delete_button: Button = %DeleteButton
@onready var _editor: VBoxContainer = %Editor
@onready var _trigger_option: OptionButton = %TriggerOption
@onready var _time_edit: LineEdit = %TimeEdit
@onready var _interval_spin: SpinBox = %IntervalSpin
@onready var _threshold_spin: SpinBox = %ThresholdSpin
@onready var _days_preset: MenuButton = %DaysPresetMenu
@onready var _window_label: Label = %WindowLabel
@onready var _window_row: HBoxContainer = %WindowRow
@onready var _window_check: CheckButton = %WindowCheck
@onready var _window_start: LineEdit = %WindowStartEdit
@onready var _window_end: LineEdit = %WindowEndEdit
@onready var _state_option: OptionButton = %StateOption
@onready var _action_option: OptionButton = %ActionOption
@onready var _text_edit: LineEdit = %ActionTextEdit
@onready var _warn_check: CheckButton = %WarnCheck
@onready var _wake_check: CheckButton = %WakeComputerCheck
@onready var _delay_spin: SpinBox = %DelaySpin
@onready var _name_edit: LineEdit = %NameEdit


func _ready() -> void:
	_day_buttons = [%DayMon, %DayTue, %DayWed, %DayThu, %DayFri, %DaySat, %DaySun]
	for name in EventRule.TRIGGER_NAMES:
		_trigger_option.add_item(name)
	for name in EventRule.STATE_FILTER_NAMES:
		_state_option.add_item(name)
	for name in EventRule.ACTION_NAMES:
		_action_option.add_item(name)

	_enabled_check.toggled.connect(func(on: bool) -> void: _edit(func() -> void: rule.enabled = on))
	_expand_button.pressed.connect(func() -> void: set_expanded(not _editor.visible))
	_delete_button.pressed.connect(func() -> void: remove_requested.emit())
	_trigger_option.item_selected.connect(func(i: int) -> void: _edit(func() -> void: _set_trigger(i as EventRule.Trigger)))
	_time_edit.text_changed.connect(func(t: String) -> void: _edit(func() -> void: rule.time_of_day = t.strip_edges()))
	_interval_spin.value_changed.connect(func(v: float) -> void: _edit(func() -> void: rule.interval_minutes = int(v)))
	_threshold_spin.value_changed.connect(func(v: float) -> void: _edit(func() -> void: rule.threshold = v))
	for i in _day_buttons.size():
		var day := DAY_ORDER[i]
		_day_buttons[i].toggled.connect(func(on: bool) -> void: _edit(func() -> void:
			rule.weekdays = (rule.weekdays | (1 << day)) if on else (rule.weekdays & ~(1 << day))))
	_days_preset.get_popup().id_pressed.connect(func(id: int) -> void:
		_edit(func() -> void: rule.weekdays = DAY_PRESETS[id])
		_load_fields())
	_window_check.toggled.connect(func(on: bool) -> void: _edit(func() -> void: rule.window_enabled = on))
	_window_start.text_changed.connect(func(t: String) -> void: _edit(func() -> void: rule.window_start = t.strip_edges()))
	_window_end.text_changed.connect(func(t: String) -> void: _edit(func() -> void: rule.window_end = t.strip_edges()))
	_state_option.item_selected.connect(func(i: int) -> void: _edit(func() -> void: rule.state_filter = i as EventRule.StateFilter))
	_action_option.item_selected.connect(func(i: int) -> void: _edit(func() -> void: rule.action = i as EventRule.Action))
	_text_edit.text_changed.connect(func(t: String) -> void: _edit(func() -> void: rule.text = t))
	_warn_check.toggled.connect(func(on: bool) -> void: _edit(func() -> void: rule.warn_players = on))
	_wake_check.toggled.connect(func(on: bool) -> void: _edit(func() -> void: rule.wake_computer = on))
	_delay_spin.value_changed.connect(func(v: float) -> void: _edit(func() -> void: rule.delay_seconds = int(v)))
	_name_edit.text_changed.connect(func(t: String) -> void: _edit(func() -> void: rule.label = t))
	if rule != null:
		_load_fields()


func setup(event_rule: EventRule, event_scheduler: TaskScheduler) -> void:
	rule = event_rule
	scheduler = event_scheduler
	if is_node_ready():
		_load_fields()


func set_expanded(expanded: bool) -> void:
	_editor.visible = expanded
	_expand_button.icon = CHEVRON_UP if expanded else CHEVRON_DOWN
	_expand_button.tooltip_text = "Collapse" if expanded else "Edit this event"
	expanded_changed.emit(expanded)


func is_expanded() -> bool:
	return _editor.visible


## False when a time field holds something other than a valid "HH:MM".
func is_valid() -> bool:
	if rule == null:
		return true
	if rule.trigger == EventRule.Trigger.TIME and not _valid_time(rule.time_of_day):
		return false
	if rule.window_enabled and not rule.is_timed() and not (_valid_time(rule.window_start) and _valid_time(rule.window_end)):
		return false
	return true


func refresh_next_run() -> void:
	if rule == null or not is_node_ready():
		return
	var text := ""
	if not rule.enabled:
		text = "Disabled"
	elif rule.is_timed() and is_valid():
		var now := int(Time.get_unix_time_from_system())
		var next := -1
		var pending := true
		if saved_rule != null and scheduler != null:
			next = scheduler.next_run_of(saved_rule)
			pending = false
		else:
			next = rule.next_run_after(now, now)
		if next < 0:
			text = "Never runs (no days selected)"
		else:
			text = "Next: %s (in %s)%s" % [Fmt.datetime(next), Fmt.duration(next - now), "  · after saving" if pending else ""]
	_next_run_label.text = text
	_next_run_label.visible = text != ""


func _edit(apply: Callable) -> void:
	if _suppress or rule == null:
		return
	apply.call()
	_update_view()
	changed.emit()


func _set_trigger(trigger: EventRule.Trigger) -> void:
	rule.trigger = trigger
	# Sensible defaults for the threshold the new trigger uses.
	match trigger:
		EventRule.Trigger.SERVER_EMPTY:
			rule.threshold = 15.0
		EventRule.Trigger.PLAYERS_AT_LEAST:
			rule.threshold = 1.0
		EventRule.Trigger.TPS_BELOW:
			rule.threshold = 15.0
	_load_fields()


## Copies the rule into every input without emitting edits.
func _load_fields() -> void:
	_suppress = true
	_enabled_check.button_pressed = rule.enabled
	_trigger_option.select(rule.trigger)
	_time_edit.text = rule.time_of_day
	_interval_spin.value = rule.interval_minutes
	_configure_threshold()
	_threshold_spin.set_value_no_signal(rule.threshold)
	for i in _day_buttons.size():
		_day_buttons[i].button_pressed = rule.weekdays & (1 << DAY_ORDER[i]) != 0
	_window_check.button_pressed = rule.window_enabled
	_window_start.text = rule.window_start
	_window_end.text = rule.window_end
	_state_option.select(rule.state_filter)
	_action_option.select(rule.action)
	_text_edit.text = rule.text
	_warn_check.button_pressed = rule.warn_players
	_wake_check.button_pressed = rule.wake_computer
	_delay_spin.value = rule.delay_seconds
	_name_edit.text = rule.label
	_suppress = false
	_update_view()


func _configure_threshold() -> void:
	match rule.trigger:
		EventRule.Trigger.SERVER_EMPTY:
			_set_spin(_threshold_spin, 1.0, 1440.0, 1.0, "min", "Minutes the server must be empty (online with nobody connected).")
		EventRule.Trigger.PLAYERS_AT_LEAST:
			_set_spin(_threshold_spin, 1.0, 1000.0, 1.0, "players", "Fires once when this many players are online; re-arms when the count drops below.")
		EventRule.Trigger.TPS_BELOW:
			_set_spin(_threshold_spin, 1.0, 20.0, 0.5, "TPS", "Fires when TPS stays below this for a minute; re-arms when it recovers.")


static func _set_spin(spin: SpinBox, lo: float, hi: float, step: float, suffix: String, tip: String) -> void:
	spin.min_value = lo
	spin.max_value = hi
	spin.step = step
	spin.suffix = suffix
	spin.tooltip_text = tip


## Shows only the inputs that matter for the current trigger/action and refreshes the summary.
func _update_view() -> void:
	var t := rule.trigger
	_time_edit.visible = t == EventRule.Trigger.TIME
	_interval_spin.visible = t == EventRule.Trigger.INTERVAL
	_threshold_spin.visible = t in [EventRule.Trigger.SERVER_EMPTY, EventRule.Trigger.PLAYERS_AT_LEAST, EventRule.Trigger.TPS_BELOW]
	var windowed := not rule.is_timed()
	_window_label.visible = windowed
	_window_row.visible = windowed
	_window_start.editable = rule.window_enabled
	_window_end.editable = rule.window_enabled
	var a := rule.action
	_text_edit.visible = a in [EventRule.Action.COMMAND, EventRule.Action.BROADCAST, EventRule.Action.NOTIFY]
	match a:
		EventRule.Action.COMMAND:
			_text_edit.placeholder_text = "command without /"
		EventRule.Action.NOTIFY:
			_text_edit.placeholder_text = "notification text — {server} and {players} are filled in"
		_:
			_text_edit.placeholder_text = "message"
	_text_edit.tooltip_text = "Shown as a notification (see Preferences → Notifications). {server} becomes the server name, {players} the number of players online." \
		if a == EventRule.Action.NOTIFY else "Console command (without the leading /) or chat message. Only sent while the server is online."
	_warn_check.visible = a == EventRule.Action.STOP or a == EventRule.Action.RESTART
	_wake_check.visible = rule.is_timed()

	_mark(_time_edit, t != EventRule.Trigger.TIME or _valid_time(rule.time_of_day))
	_mark(_window_start, not rule.window_enabled or _valid_time(rule.window_start))
	_mark(_window_end, not rule.window_enabled or _valid_time(rule.window_end))
	_invalid_badge.visible = not is_valid()

	_summary_label.text = rule.describe()
	_summary_label.modulate.a = 1.0 if rule.enabled else 0.55
	_name_edit.placeholder_text = "%s → %s" % [rule.describe_trigger(), rule.describe_action()]
	refresh_next_run()


func _mark(edit: LineEdit, ok: bool) -> void:
	if ok:
		edit.remove_theme_color_override("font_color")
	else:
		edit.add_theme_color_override("font_color", Color("e05555"))


static func _valid_time(hhmm: String) -> bool:
	var parts := hhmm.strip_edges().split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return false
	var h := parts[0].to_int()
	var m := parts[1].to_int()
	return h >= 0 and h <= 23 and m >= 0 and m <= 59 and parts[1].length() == 2
