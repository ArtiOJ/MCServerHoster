class_name AutomationTab
extends ServerTab
## Auto-start, crash recovery, events (triggers → actions) and backup retention for
## one server. Edits go to a draft config and are saved through ServerOps (on the
## server's own computer for remote servers).

const ROW_SCENE := preload("res://scenes/components/event_row.tscn")
const EDITED_FIELDS: PackedStringArray = [
	"auto_start", "auto_restart", "max_restarts", "restart_window_sec", "stop_timeout_sec",
	"events", "backup_retention", "backup_full", "wake_on_connect", "wake_on_ping", "wake_motd",
]

var _draft: ServerConfig
var _loading := false
var _saving := false
var _rows: Array[EventRow] = []
## Draft rules whose editor is open, so rebuilding the list keeps them expanded.
var _expanded := {}

@onready var _auto_start_check: CheckButton = %AutoStartCheck
@onready var _auto_restart_check: CheckButton = %AutoRestartCheck
@onready var _max_restarts_spin: SpinBox = %MaxRestartsSpin
@onready var _window_spin: SpinBox = %WindowSpin
@onready var _stop_timeout_spin: SpinBox = %StopTimeoutSpin
@onready var _recovery_hint: Label = %RecoveryHint
@onready var _wake_check: CheckButton = %WakeCheck
@onready var _wake_options: GridContainer = %WakeOptions
@onready var _wake_motd_edit: LineEdit = %WakeMotdEdit
@onready var _wake_ping_check: CheckButton = %WakePingCheck
@onready var _wake_status: Label = %WakeStatus
@onready var _idle_row: HBoxContainer = %IdleRow
@onready var _add_idle_button: Button = %AddIdleButton
@onready var _add_menu: MenuButton = %AddEventMenu
@onready var _event_list: VBoxContainer = %EventList
@onready var _empty_label: Label = %EmptyEventsLabel
@onready var _sleep_notice: PanelContainer = %SleepNotice
@onready var _retention_spin: SpinBox = %RetentionSpin
@onready var _full_check: CheckButton = %FullBackupCheck
@onready var _dirty_label: Label = %DirtyLabel
@onready var _revert_button: Button = %RevertButton
@onready var _save_button: Button = %SaveButton
@onready var _refresh_timer: Timer = %RefreshTimer


func _ready() -> void:
	_auto_start_check.toggled.connect(_on_input_changed.unbind(1))
	_auto_restart_check.toggled.connect(_on_input_changed.unbind(1))
	for spin: SpinBox in [_max_restarts_spin, _window_spin, _stop_timeout_spin, _retention_spin]:
		spin.value_changed.connect(_on_input_changed.unbind(1))
	_full_check.toggled.connect(_on_input_changed.unbind(1))
	_wake_check.toggled.connect(_on_input_changed.unbind(1))
	_wake_ping_check.toggled.connect(_on_input_changed.unbind(1))
	_wake_motd_edit.text_changed.connect(_on_input_changed.unbind(1))
	_add_idle_button.pressed.connect(_add_idle_stop)
	var popup := _add_menu.get_popup()
	var templates := EventRule.templates()
	for i in templates.size():
		popup.add_item(templates[i][0], i)
	popup.id_pressed.connect(_add_event)
	_revert_button.pressed.connect(_load_draft)
	_save_button.pressed.connect(_save)
	_refresh_timer.timeout.connect(_update_next_runs)


func _on_bound() -> void:
	_draft = null
	watch(handle.config_changed, _on_config_changed)
	watch(handle.state_changed, _update_next_runs.unbind(1))
	watch(handle.state_changed, _update_wake_status.unbind(1))
	_load_draft()


func _on_config_changed() -> void:
	if _draft == null or not _is_dirty():
		_load_draft()


func _load_draft() -> void:
	if handle == null:
		return
	# Keep open editors open across reloads (matched by position).
	var open_indices: Array[int] = []
	if _draft != null:
		for i in _draft.events.size():
			if _expanded.has(_draft.events[i]):
				open_indices.append(i)
	_draft = ServerConfig.from_dict(handle.config.to_dict(), handle.config.directory)
	_loading = true
	_auto_start_check.button_pressed = _draft.auto_start
	_auto_restart_check.button_pressed = _draft.auto_restart
	_max_restarts_spin.value = _draft.max_restarts
	_window_spin.value = _draft.restart_window_sec / 60.0
	_stop_timeout_spin.value = _draft.stop_timeout_sec
	_retention_spin.value = _draft.backup_retention
	_full_check.button_pressed = _draft.backup_full
	_wake_check.button_pressed = _draft.wake_on_connect
	_wake_ping_check.button_pressed = _draft.wake_on_ping
	_wake_motd_edit.text = _draft.wake_motd
	_loading = false
	_expanded.clear()
	for i in open_indices:
		if i < _draft.events.size():
			_expanded[_draft.events[i]] = true
	_build_rows()
	_refresh()


func _build_rows() -> void:
	for row in _rows:
		_event_list.remove_child(row)
		row.queue_free()
	_rows.clear()
	for rule in _draft.events:
		var row: EventRow = ROW_SCENE.instantiate()
		row.setup(rule, instance.scheduler if instance != null else null)
		if handle.is_remote():
			row.set_remote(handle.host_name(), handle.can_manage_host())
		_event_list.add_child(row)
		row.set_expanded(_expanded.has(rule))
		row.changed.connect(_refresh)
		row.remove_requested.connect(_remove_event.bind(rule))
		row.expanded_changed.connect(func(on: bool) -> void:
			if on:
				_expanded[rule] = true
			else:
				_expanded.erase(rule))
		_rows.append(row)
	_empty_label.visible = _rows.is_empty()
	_update_next_runs()


func _add_event(template_index: int) -> void:
	if _draft == null:
		return
	var rule := EventRule.from_template(EventRule.templates()[template_index][1])
	if not handle.can_manage_host():
		rule.wake_computer = false
	_draft.events.append(rule)
	_expanded[rule] = true
	_build_rows()
	_refresh()


func _add_idle_stop() -> void:
	for i in EventRule.templates().size():
		if EventRule.templates()[i][0] == "Stop when empty":
			_add_event(i)
			return


func _update_wake_status() -> void:
	if handle == null or _draft == null:
		return
	if not _draft.wake_on_connect:
		_wake_status.text = ""
	elif handle.config.wake_on_connect != _draft.wake_on_connect:
		_wake_status.text = "Save to start listening on port %d." % handle.config.port
	elif handle.is_asleep():
		_wake_status.text = "Asleep — listening on port %d for players." % handle.config.port
	elif handle.wake_error() != "":
		_wake_status.text = handle.wake_error()
	elif handle.is_temporary():
		_wake_status.text = "Paused while a temporary copy is pending."
	else:
		_wake_status.text = "Listens on port %d whenever the server is stopped." % handle.config.port
	_wake_status.visible = _wake_status.text != ""


func _remove_event(rule: EventRule) -> void:
	_draft.events.erase(rule)
	_expanded.erase(rule)
	_build_rows()
	_refresh()


func _on_input_changed() -> void:
	if _loading or _draft == null:
		return
	_draft.auto_start = _auto_start_check.button_pressed
	_draft.auto_restart = _auto_restart_check.button_pressed
	_draft.max_restarts = int(_max_restarts_spin.value)
	_draft.restart_window_sec = int(_window_spin.value) * 60
	_draft.wake_on_connect = _wake_check.button_pressed
	_draft.wake_on_ping = _wake_ping_check.button_pressed
	_draft.wake_motd = _wake_motd_edit.text
	_draft.stop_timeout_sec = int(_stop_timeout_spin.value)
	_draft.backup_retention = int(_retention_spin.value)
	_draft.backup_full = _full_check.button_pressed
	_refresh()


func _refresh() -> void:
	if _draft == null:
		return
	_max_restarts_spin.editable = _draft.auto_restart
	_window_spin.editable = _draft.auto_restart
	_recovery_hint.text = ("After a crash the server restarts after 5 s, then 15 s, then 60 s. If it crashes more than %d time(s) within %s, automatic restarts pause until you start it manually." % [_draft.max_restarts, Fmt.duration(_draft.restart_window_sec)]) \
		if _draft.auto_restart else "Crashed servers stay stopped until you start them."
	_wake_options.visible = _draft.wake_on_connect
	_idle_row.visible = _draft.wake_on_connect and not _draft.events.any(func(r: EventRule) -> bool:
		return r.enabled and r.trigger == EventRule.Trigger.SERVER_EMPTY and r.action == EventRule.Action.STOP)
	_update_wake_status()
	var invalid := _rows.any(func(r: EventRow) -> bool: return not r.is_valid())
	_sleep_notice.visible = _draft.events.any(func(r: EventRule) -> bool:
		return r.trigger == EventRule.Trigger.SYSTEM_SLEEP or r.trigger == EventRule.Trigger.SYSTEM_WAKE)
	var dirty := _is_dirty()
	_save_button.disabled = not dirty or invalid or _saving
	_revert_button.disabled = not dirty
	_dirty_label.text = "Fix the highlighted times before saving" if invalid else ("Unsaved changes" if dirty else "")
	_update_next_runs()


func _update_next_runs() -> void:
	if _draft == null or handle == null:
		return
	var saved := handle.config.events
	for i in _rows.size():
		var rule: EventRule = _draft.events[i]
		# Unchanged rules can use the live scheduler's exact next run (interval alignment etc.).
		_rows[i].saved_rule = saved[i] if i < saved.size() and saved[i].to_dict() == rule.to_dict() else null
		_rows[i].refresh_next_run()


func _edited_values(cfg: ServerConfig) -> Dictionary:
	var d := cfg.to_dict()
	var out := {}
	for key in EDITED_FIELDS:
		out[key] = d.get(key)
	return out


func _is_dirty() -> bool:
	return _draft != null and handle != null and _edited_values(_draft) != _edited_values(handle.config)


func _save() -> void:
	if handle == null or _saving or _rows.any(func(r: EventRow) -> bool: return not r.is_valid()):
		return
	var h := handle
	_saving = true
	_refresh()
	var res: Dictionary = await h.call_op("config_save", {"changes": _edited_values(_draft)})
	_saving = false
	if h != handle:
		return
	if not res.ok:
		Notifier.error(str(res.error))
		_refresh()
		return
	Notifier.success("Saved automation settings for %s." % h.config.display_name)
	_load_draft()
