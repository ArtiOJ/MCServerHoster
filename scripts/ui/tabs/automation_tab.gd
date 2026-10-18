class_name AutomationTab
extends ServerTab
## Auto-start, crash recovery, scheduled tasks and backup retention for one
## server. Edits go to a draft config and are copied over on save.

const ROW_SCENE := preload("res://scenes/components/schedule_row.tscn")
const EDITED_FIELDS: PackedStringArray = [
	"auto_start", "auto_restart", "max_restarts", "restart_window_sec", "stop_timeout_sec",
	"schedules", "backup_retention", "backup_full",
]

var _draft: ServerConfig
var _loading := false
var _rows: Array[ScheduleRow] = []

@onready var _auto_start_check: CheckButton = %AutoStartCheck
@onready var _auto_restart_check: CheckButton = %AutoRestartCheck
@onready var _max_restarts_spin: SpinBox = %MaxRestartsSpin
@onready var _window_spin: SpinBox = %WindowSpin
@onready var _stop_timeout_spin: SpinBox = %StopTimeoutSpin
@onready var _recovery_hint: Label = %RecoveryHint
@onready var _add_menu: MenuButton = %AddTaskMenu
@onready var _schedule_list: VBoxContainer = %ScheduleList
@onready var _empty_label: Label = %EmptyScheduleLabel
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
	_add_menu.get_popup().id_pressed.connect(_add_task)
	_revert_button.pressed.connect(_load_draft)
	_save_button.pressed.connect(_save)
	_refresh_timer.timeout.connect(_update_next_runs)


func _on_bound() -> void:
	watch(instance.config_changed, _on_config_changed)
	watch(instance.state_changed, _update_next_runs.unbind(1))
	_load_draft()


func _on_config_changed() -> void:
	if _draft == null or not _is_dirty():
		_load_draft()


func _load_draft() -> void:
	if instance == null:
		return
	_draft = ServerConfig.from_dict(instance.config.to_dict(), instance.config.directory)
	_loading = true
	_auto_start_check.button_pressed = _draft.auto_start
	_auto_restart_check.button_pressed = _draft.auto_restart
	_max_restarts_spin.value = _draft.max_restarts
	_window_spin.value = _draft.restart_window_sec / 60.0
	_stop_timeout_spin.value = _draft.stop_timeout_sec
	_retention_spin.value = _draft.backup_retention
	_full_check.button_pressed = _draft.backup_full
	_loading = false
	_build_rows()
	_refresh()


func _build_rows() -> void:
	for row in _rows:
		_schedule_list.remove_child(row)
		row.queue_free()
	_rows.clear()
	for entry in _draft.schedules:
		var row: ScheduleRow = ROW_SCENE.instantiate()
		row.setup(entry)
		_schedule_list.add_child(row)
		row.changed.connect(_refresh)
		row.remove_requested.connect(_remove_task.bind(entry))
		_rows.append(row)
	_empty_label.visible = _rows.is_empty()
	_update_next_runs()


func _add_task(kind: int) -> void:
	if _draft == null:
		return
	var entry := ScheduleEntry.new()
	entry.kind = kind as ScheduleEntry.Kind
	match entry.kind:
		ScheduleEntry.Kind.RESTART:
			entry.time_of_day = "04:00"
		ScheduleEntry.Kind.BACKUP:
			entry.time_of_day = "03:00"
		ScheduleEntry.Kind.COMMAND:
			entry.mode = ScheduleEntry.Mode.INTERVAL
			entry.interval_minutes = 60
	_draft.schedules.append(entry)
	_build_rows()
	_refresh()


func _remove_task(entry: ScheduleEntry) -> void:
	_draft.schedules.erase(entry)
	_build_rows()
	_refresh()


func _on_input_changed() -> void:
	if _loading or _draft == null:
		return
	_draft.auto_start = _auto_start_check.button_pressed
	_draft.auto_restart = _auto_restart_check.button_pressed
	_draft.max_restarts = int(_max_restarts_spin.value)
	_draft.restart_window_sec = int(_window_spin.value) * 60
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
	var invalid := _rows.any(func(r: ScheduleRow) -> bool: return not r.is_valid())
	var dirty := _is_dirty()
	_save_button.disabled = not dirty or invalid
	_revert_button.disabled = not dirty
	_dirty_label.text = "Fix the highlighted time before saving" if invalid else ("Unsaved changes" if dirty else "")
	_update_next_runs()


func _update_next_runs() -> void:
	if _draft == null or instance == null:
		return
	var now := int(Time.get_unix_time_from_system())
	var saved := instance.config.schedules
	for i in _rows.size():
		var entry: ScheduleEntry = _draft.schedules[i]
		var text := ""
		if not entry.enabled:
			text = "Disabled"
		elif i < saved.size() and saved[i].to_dict() == entry.to_dict():
			text = "Next: " + Fmt.datetime(instance.scheduler.next_run_of(saved[i]))
		else:
			text = "Next: %s (after saving)" % Fmt.datetime(entry.next_run_after(now, now))
		if entry.enabled and entry.kind != ScheduleEntry.Kind.BACKUP and not instance.is_online():
			text += " · only while online"
		_rows[i].set_next_run(text)


func _edited_values(cfg: ServerConfig) -> Dictionary:
	var d := cfg.to_dict()
	var out := {}
	for key in EDITED_FIELDS:
		out[key] = d.get(key)
	return out


func _is_dirty() -> bool:
	return _draft != null and instance != null and _edited_values(_draft) != _edited_values(instance.config)


func _save() -> void:
	if instance == null or _rows.any(func(r: ScheduleRow) -> bool: return not r.is_valid()):
		return
	var c := instance.config
	c.auto_start = _draft.auto_start
	c.auto_restart = _draft.auto_restart
	c.max_restarts = _draft.max_restarts
	c.restart_window_sec = _draft.restart_window_sec
	c.stop_timeout_sec = _draft.stop_timeout_sec
	c.backup_retention = _draft.backup_retention
	c.backup_full = _draft.backup_full
	var schedules: Array[ScheduleEntry] = []
	for entry in _draft.schedules:
		schedules.append(ScheduleEntry.from_dict(entry.to_dict()))
	c.schedules = schedules
	instance.save_config()
	Notifier.success("Saved automation settings for %s." % c.display_name)
	_load_draft()
