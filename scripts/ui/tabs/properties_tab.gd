class_name SettingsTab
extends ServerTab
## Typed editor for every catalog setting of a server: server.properties, Paper/Spigot/
## Bukkit YAML and game rules, grouped by category. A raw mode edits the files directly.
## Keys the manager owns (port, RCON) are hidden here and preserved on save. Configuration
## always targets the real server folder, also while a temporary copy runs. Everything
## goes through the server handle, so servers on other computers work the same way.

const ROW_SCENE := preload("res://scenes/components/property_row.tscn")
const SECTION_SCENE := preload("res://scenes/components/section_header.tscn")
const PROPERTIES_FILE := "server.properties"

## Last [method ServerHandle.settings_snapshot] result.
var _snapshot := {}
## Bumped for every load, so an answer that arrives after switching servers is ignored.
var _serial := 0
var _busy := false
var _rows: Array[PropertyRow] = []
## SectionHeader -> Array of PropertyRow in that category, for filtering.
var _sections := {}
var _dirty := false
var _raw_dirty := false
## Text of the raw file as loaded; dirty means the editor differs from it. (TextEdit emits
## text_changed deferred, so a suppression flag around assignments is not reliable.)
var _raw_loaded := ""
var _raw_file := PROPERTIES_FILE

@onready var _search: LineEdit = %SearchEdit
@onready var _raw_toggle: CheckButton = %RawToggle
@onready var _file_option: OptionButton = %FileOption
@onready var _revert_button: Button = %RevertButton
@onready var _save_button: Button = %SaveButton
@onready var _status_label: Label = %StatusLabel
@onready var _running_notice: PanelContainer = %RunningNotice
@onready var _pending_notice: PanelContainer = %PendingNotice
@onready var _pending_label: Label = %PendingLabel
@onready var _temp_notice: PanelContainer = %TempNotice
@onready var _missing_notice: Label = %MissingNotice
@onready var _form_scroll: ScrollContainer = %FormScroll
@onready var _form_list: VBoxContainer = %FormList
@onready var _raw_editor: CodeEdit = %RawEditor


func _ready() -> void:
	_search.text_changed.connect(_apply_filter.unbind(1))
	_raw_toggle.toggled.connect(_on_raw_toggled)
	_file_option.item_selected.connect(_on_file_selected)
	_revert_button.pressed.connect(_revert)
	_save_button.pressed.connect(_save)
	_raw_editor.text_changed.connect(_on_raw_text_changed)
	_file_option.visible = false
	_set_dirty(false)


func _on_bound() -> void:
	watch(handle.state_changed, _on_state_changed)
	watch(handle.config_changed, _on_config_changed)
	# An event changed server.properties.
	watch(handle.data_changed, func(area: StringName) -> void:
		if area == &"settings":
			_on_config_changed())
	if _raw_toggle.button_pressed:
		_raw_toggle.set_pressed_no_signal(false)
		_show_raw(false)
	_dirty = false
	_raw_dirty = false
	_reload(true)


func _on_state_changed(_state: ServerHandle.State) -> void:
	# Minecraft and Paper rewrite their files with every key on boot; pick that up when nothing is pending.
	if not _dirty and not _raw_toggle.button_pressed:
		_reload()
	_update_notices()


func _on_config_changed() -> void:
	# Fired e.g. after game rules were read from the running server.
	if not _dirty and not _raw_toggle.button_pressed:
		_reload()
	_update_notices()


func _reload(force_rebuild := false) -> void:
	if handle == null:
		return
	_serial += 1
	var serial := _serial
	var h := handle
	if force_rebuild:
		_status_label.text = "Loading…"
	var snap: Dictionary = await h.settings_snapshot()
	if serial != _serial or h != handle:
		return
	if not snap.get("ok", false):
		_status_label.text = str(snap.get("error", "Could not load the settings."))
		return
	_snapshot = snap
	_missing_notice.visible = bool(snap.get("properties_missing", false))
	var entries := _visible_entries()
	var ids := entries.map(func(e: Dictionary) -> String: return e.id)
	var current := _rows.map(func(r: PropertyRow) -> String: return r.key)
	if force_rebuild or ids != current:
		_build_form(entries)
	else:
		for row in _rows:
			row.setup_entry(row.entry, _value_of(row.entry))
	_set_dirty(false)
	_update_notices()


## Catalog entries for the server's version plus its unknown server.properties keys, in
## the same order ServerSettings.entries() uses; managed keys (ports, RCON) left out.
func _visible_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in SettingsCatalog.for_version(handle.config.mc_version):
		if e.source == "property" and PropertySchema.is_managed(e.key):
			continue
		out.append(e)
	var unknown: Dictionary = _snapshot.get("unknown", {})
	for key in unknown:
		if not PropertySchema.is_managed(str(key)):
			out.append(SettingsCatalog.unknown_property_entry(str(key), str(unknown[key])))
	return out


func _value_of(entry: Dictionary) -> String:
	var values: Dictionary = _snapshot.get("values", {})
	return str(values.get(entry.id, entry.default))


func _build_form(entries: Array[Dictionary]) -> void:
	var scroll := _form_scroll.scroll_vertical
	for child in _form_list.get_children():
		_form_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	_sections.clear()
	var by_category := {}
	for e in entries:
		var cat := _category_of(e)
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(e)
	for cat in SettingsCatalog.CATEGORIES:
		if not by_category.has(cat):
			continue
		var section: SectionHeader = SECTION_SCENE.instantiate()
		section.title = cat
		_form_list.add_child(section)
		var rows: Array[PropertyRow] = []
		for e: Dictionary in by_category[cat]:
			var row: PropertyRow = ROW_SCENE.instantiate()
			row.setup_entry(e, _value_of(e))
			_form_list.add_child(row)
			row.changed.connect(_on_row_changed.unbind(2))
			rows.append(row)
			_rows.append(row)
		_sections[section] = rows
	_apply_filter()
	_form_scroll.set_deferred("scroll_vertical", scroll)


## Catalog category of [param e], matched case-insensitively; unknown ones go to "Other".
static func _category_of(e: Dictionary) -> String:
	var cat := str(e.get("category", "Other"))
	for c in SettingsCatalog.CATEGORIES:
		if c.to_lower() == cat.to_lower():
			return c
	return "Other"


func _apply_filter() -> void:
	var filter := _search.text
	for section: SectionHeader in _sections:
		var any := false
		for row: PropertyRow in _sections[section]:
			row.visible = row.matches(filter)
			any = any or row.visible
		section.visible = any


func _on_row_changed() -> void:
	_set_dirty(_rows.any(func(r: PropertyRow) -> bool: return r.is_modified()))


func _revert() -> void:
	if _raw_toggle.button_pressed:
		_load_raw()
	else:
		_reload()


func _save() -> void:
	if handle == null or _busy:
		return
	if _raw_toggle.button_pressed:
		_save_raw()
		return
	var changes := {}
	for row in _rows:
		if row.is_modified():
			changes[row.entry.id] = row.get_value()
	var h := handle
	_set_busy(true)
	var res: Dictionary = await h.save_settings(changes)
	_set_busy(false)
	if h != handle:
		return
	if not res.get("ok", false):
		Notifier.error(str(res.get("error", "Could not save the settings.")))
		return
	var suffix := " Restart the server to apply file settings." if res.get("restart_needed", false) else ""
	Notifier.success("Saved settings for %s.%s" % [h.config.display_name, suffix])
	_reload()


func _set_busy(busy: bool) -> void:
	_busy = busy
	_refresh_buttons()
	if busy:
		_status_label.text = "Saving…"


func _set_dirty(dirty: bool) -> void:
	_dirty = dirty
	_refresh_buttons()


func _refresh_buttons() -> void:
	var pending := _raw_dirty if _raw_toggle.button_pressed else _dirty
	_save_button.disabled = not pending or _busy
	_revert_button.disabled = not pending or _busy
	_status_label.text = "Unsaved changes" if pending else ""


func _update_notices() -> void:
	if handle == null:
		return
	_running_notice.visible = handle.is_process_alive()
	var pending := handle.config.pending_gamerules.size()
	_pending_notice.visible = pending > 0 and not handle.is_online()
	_pending_label.text = "%d game rule change%s will be applied when the server next starts." % [pending, "" if pending == 1 else "s"]
	_temp_notice.visible = handle.is_temporary()


# --- Raw file editing -------------------------------------------------------

func _on_raw_toggled(raw: bool) -> void:
	if raw and _dirty:
		Notifier.warn("Save or revert your setting changes before editing files directly.")
		_raw_toggle.set_pressed_no_signal(false)
		return
	if not raw and _raw_dirty:
		Notifier.warn("Save or revert your changes to %s first." % _raw_file)
		_raw_toggle.set_pressed_no_signal(true)
		return
	_show_raw(raw)
	if raw:
		_populate_files()
		_load_raw()
	else:
		_reload()


func _show_raw(raw: bool) -> void:
	_form_scroll.visible = not raw
	_search.editable = not raw
	_file_option.visible = raw
	_raw_editor.visible = raw
	_refresh_buttons()


func _populate_files() -> void:
	_file_option.clear()
	var files := PackedStringArray(_snapshot.get("raw_files", [PROPERTIES_FILE]))
	for f in files:
		_file_option.add_item(f)
	if not files.has(_raw_file):
		_raw_file = PROPERTIES_FILE
	_file_option.select(files.find(_raw_file))


func _on_file_selected(index: int) -> void:
	var chosen := _file_option.get_item_text(index)
	if chosen == _raw_file:
		return
	if _raw_dirty:
		Notifier.warn("Save or revert your changes to %s first." % _raw_file)
		for i in _file_option.item_count:
			if _file_option.get_item_text(i) == _raw_file:
				_file_option.select(i)
		return
	_raw_file = chosen
	_load_raw()


func _load_raw() -> void:
	var h := handle
	var file := _raw_file
	_raw_editor.editable = false
	var res: Dictionary = await h.read_config_file(file)
	if h != handle or file != _raw_file:
		return
	_raw_editor.editable = true
	if not res.get("ok", false):
		Notifier.error(str(res.get("error", "Could not read %s." % file)))
	_raw_loaded = str(res.get("text", ""))
	_raw_editor.text = _raw_loaded
	_raw_editor.clear_undo_history()
	_raw_dirty = false
	_refresh_buttons()


func _on_raw_text_changed() -> void:
	_raw_dirty = _raw_editor.text != _raw_loaded
	_refresh_buttons()


func _save_raw() -> void:
	var h := handle
	var file := _raw_file
	_set_busy(true)
	var res: Dictionary = await h.write_config_file(file, _raw_editor.text)
	_set_busy(false)
	if h != handle:
		return
	if not res.get("ok", false):
		Notifier.error(str(res.get("error", "Could not save %s." % file)))
		_refresh_buttons()
		return
	Notifier.success("Saved %s for %s." % [file, h.config.display_name])
	_load_raw()
