class_name PropertiesTab
extends ServerTab
## Typed editor for server.properties with a raw-text fallback. Keys the manager
## owns (port, RCON) are hidden here and preserved on save.

const ROW_SCENE := preload("res://scenes/components/property_row.tscn")
const SECTION_SCENE := preload("res://scenes/components/section_header.tscn")

var _props: ServerProperties
var _rows: Array[PropertyRow] = []
## Section header node -> Array of PropertyRow, for filtering.
var _sections := {}
var _dirty := false
## True once the raw text was edited by hand (not by switching modes).
var _raw_edited := false
var _suppress_raw := false

@onready var _search: LineEdit = %SearchEdit
@onready var _raw_toggle: CheckButton = %RawToggle
@onready var _revert_button: Button = %RevertButton
@onready var _save_button: Button = %SaveButton
@onready var _running_notice: PanelContainer = %RunningNotice
@onready var _missing_notice: Label = %MissingNotice
@onready var _form_scroll: ScrollContainer = %FormScroll
@onready var _form_list: VBoxContainer = %FormList
@onready var _raw_editor: CodeEdit = %RawEditor
@onready var _status_label: Label = %StatusLabel


func _ready() -> void:
	_search.text_changed.connect(_apply_filter.unbind(1))
	_raw_toggle.toggled.connect(_on_raw_toggled)
	_revert_button.pressed.connect(_reload)
	_save_button.pressed.connect(_save)
	_raw_editor.text_changed.connect(_on_raw_text_changed)
	_set_dirty(false)


func _on_bound() -> void:
	watch(instance.state_changed, _on_state_changed)
	_reload()


func _on_state_changed(_state: ServerInstance.State) -> void:
	_update_notice()
	# Minecraft rewrites server.properties with every key on boot; pick that up when nothing is pending.
	if not _dirty:
		_reload()


func _reload() -> void:
	if instance == null:
		return
	_props = instance.get_properties()
	_missing_notice.visible = not FileAccess.file_exists(instance.config.properties_path())
	_build_form()
	_set_raw_text(_props.to_text())
	_raw_editor.clear_undo_history()
	_raw_edited = false
	_set_dirty(false)
	_update_notice()


func _build_form() -> void:
	for child in _form_list.get_children():
		_form_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	_sections.clear()

	var by_category := {}
	for cat in PropertySchema.CATEGORIES:
		by_category[cat] = PackedStringArray()
	var core := PropertySchema.core_keys()
	# Known keys in schema order, then unknown keys alphabetically.
	for key in PropertySchema.KEYS:
		if (_props.has(key) or core.has(key)) and not PropertySchema.is_managed(key):
			by_category[PropertySchema.KEYS[key].category].append(key)
	var unknown := PackedStringArray()
	for key in _props.keys():
		if not PropertySchema.KEYS.has(key) and not PropertySchema.is_managed(key):
			unknown.append(key)
	unknown.sort()
	by_category["Other"].append_array(unknown)

	for cat in PropertySchema.CATEGORIES:
		var keys: PackedStringArray = by_category[cat]
		if keys.is_empty():
			continue
		var section: SectionHeader = SECTION_SCENE.instantiate()
		section.title = cat
		_form_list.add_child(section)
		var rows: Array[PropertyRow] = []
		for key in keys:
			var row: PropertyRow = ROW_SCENE.instantiate()
			var value := _props.get_value(key, str(PropertySchema.NEW_SERVER_DEFAULTS.get(key, "")))
			row.setup(key, value)
			_form_list.add_child(row)
			row.changed.connect(_on_row_changed.unbind(2))
			rows.append(row)
			_rows.append(row)
		_sections[section] = rows
	_apply_filter()


func _apply_filter() -> void:
	var filter := _search.text
	for section in _sections:
		var any := false
		for row: PropertyRow in _sections[section]:
			row.visible = row.matches(filter)
			any = any or row.visible
		section.visible = any


func _on_row_changed() -> void:
	_set_dirty(_raw_edited or _rows.any(func(r: PropertyRow) -> bool: return r.is_modified()))


func _on_raw_text_changed() -> void:
	if _suppress_raw:
		return
	_raw_edited = true
	_set_dirty(true)


func _set_raw_text(text: String) -> void:
	_suppress_raw = true
	_raw_editor.text = text
	_suppress_raw = false


func _on_raw_toggled(raw: bool) -> void:
	if raw:
		_apply_rows_to_props()
		_set_raw_text(_props.to_text())
	else:
		var parsed := ServerProperties.new()
		parsed.parse(_raw_editor.text)
		_props = parsed
		_build_form()
	_form_scroll.visible = not raw
	_search.editable = not raw
	_raw_editor.visible = raw


## Writes form edits into [member _props]; untouched keys missing from the file stay absent.
func _apply_rows_to_props() -> void:
	for row in _rows:
		if _props.has(row.key) or row.is_modified():
			_props.set_value(row.key, row.get_value())


func _save() -> void:
	if instance == null:
		return
	if _raw_toggle.button_pressed:
		var parsed := ServerProperties.new()
		parsed.parse(_raw_editor.text)
		_props = parsed
	else:
		_apply_rows_to_props()
	# The manager owns these keys; keep whatever is currently on disk.
	var current := instance.get_properties()
	for key in PropertySchema.MANAGED_KEYS:
		if current.has(key):
			_props.set_value(key, current.get_value(key))
	var err := _props.save_file(instance.config.properties_path())
	if err != OK:
		Notifier.error("Could not save server.properties: %s" % error_string(err))
		return
	instance.max_players = _props.get_int("max-players", instance.max_players)
	instance.players_changed.emit()
	instance.stats_updated.emit()
	var suffix := " Restart the server to apply." if instance.is_process_alive() else ""
	Notifier.success("Saved server.properties for %s.%s" % [instance.config.display_name, suffix])
	_reload()


func _set_dirty(dirty: bool) -> void:
	_dirty = dirty
	_save_button.disabled = not dirty
	_revert_button.disabled = not dirty
	_status_label.text = "Unsaved changes" if dirty else ""


func _update_notice() -> void:
	_running_notice.visible = instance != null and instance.is_process_alive()
