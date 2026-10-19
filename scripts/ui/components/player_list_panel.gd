class_name PlayerListPanel
extends PanelContainer
## Card listing one access list (whitelist, operators, player bans or IP bans) with
## add/remove controls. Operator lists can show and change permission levels; ban
## lists take an optional reason. The owner performs the actual edits.

## [param options] holds "level" (operators) and/or "reason" (bans) when those are shown.
signal add_requested(value: String, options: Dictionary)
signal remove_requested(value: String)
## A listed operator's permission level was changed with the level selector.
signal level_change_requested(value: String, level: int)

enum EntryKind { PLAYER, IP }

@export var title := "Players":
	set(value):
		title = value
		if is_node_ready():
			_title_label.text = value
@export var entry_kind: EntryKind = EntryKind.PLAYER
## Show permission levels (operators list).
@export var show_level := false
## Show the optional reason field (ban lists).
@export var show_reason := false

static var _re_name := RegEx.create_from_string("^[A-Za-z0-9_]{3,16}$")

var _editable := true
var _levels_editable := true
## value -> entry Dictionary from set_entries()
var _entries := {}
var _suppress_level := false

@onready var _title_label: Label = %TitleLabel
@onready var _count_label: Label = %CountLabel
@onready var _list: ItemList = %NameList
@onready var _selected_row: HBoxContainer = %SelectedRow
@onready var _selected_level: OptionButton = %SelectedLevel
@onready var _name_edit: LineEdit = %NameEdit
@onready var _level_option: OptionButton = %LevelOption
@onready var _add_button: Button = %AddButton
@onready var _reason_edit: LineEdit = %ReasonEdit
@onready var _remove_button: Button = %RemoveButton
@onready var _status_label: Label = %StatusLabel
@onready var _hint_label: Label = %HintLabel


func _ready() -> void:
	title = title
	_level_option.visible = show_level
	_reason_edit.visible = show_reason
	if entry_kind == EntryKind.IP:
		_name_edit.placeholder_text = "IP address"
		_name_edit.max_length = 45
	_add_button.pressed.connect(_on_add)
	_name_edit.text_submitted.connect(_on_add.unbind(1))
	_reason_edit.text_submitted.connect(_on_add.unbind(1))
	_name_edit.text_changed.connect(_update_buttons.unbind(1))
	_remove_button.pressed.connect(_on_remove)
	_list.item_selected.connect(func(_i: int) -> void:
		_update_selection()
		_update_buttons())
	_list.empty_clicked.connect(func(_p: Vector2, _b: int) -> void:
		_list.deselect_all()
		_update_selection()
		_update_buttons())
	_selected_level.item_selected.connect(func(index: int) -> void:
		if not _suppress_level and _selected_value() != "":
			level_change_requested.emit(_selected_value(), index + 1))
	_update_selection()
	_update_buttons()


static func is_valid_name(player_name: String) -> bool:
	return _re_name.search(player_name) != null


## Replaces the listed entries. Each is {value, text, tooltip, [level]}.
func set_entries(entries: Array[Dictionary]) -> void:
	var selected := _selected_value()
	_entries.clear()
	_list.clear()
	var sorted := entries.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.value).naturalnocasecmp_to(str(b.value)) < 0)
	for e in sorted:
		_entries[e.value] = e
		var idx := _list.add_item(str(e.get("text", e.value)))
		_list.set_item_metadata(idx, e.value)
		_list.set_item_tooltip(idx, str(e.get("tooltip", "")))
		if e.value == selected:
			_list.select(idx)
	_count_label.text = str(entries.size())
	_update_selection()
	_update_buttons()


## Plain list of names (kept for simple callers).
func set_names(names: PackedStringArray) -> void:
	var entries: Array[Dictionary] = []
	for n in names:
		entries.append({"value": n, "text": n})
	set_entries(entries)


## [param levels_editable] controls the operator level selector separately (levels can
## only be changed while the server is stopped).
func set_editable(editable: bool, hint := "", levels_editable := true) -> void:
	_editable = editable
	_levels_editable = levels_editable
	_name_edit.editable = editable
	_reason_edit.editable = editable
	_level_option.disabled = not editable or not levels_editable
	_hint_label.text = hint
	_hint_label.visible = hint != ""
	_update_selection()
	_update_buttons()


func set_default_level(level: int) -> void:
	_level_option.select(clampi(level, 1, 4) - 1)


## Progress ("Looking up Steve…") or an error (shown in red); "" clears it.
func set_status(text: String, is_error := false) -> void:
	_status_label.text = text
	_status_label.visible = text != ""
	if is_error:
		_status_label.add_theme_color_override("font_color", Color("e05555"))
	else:
		_status_label.remove_theme_color_override("font_color")


func _selected_value() -> String:
	var sel := _list.get_selected_items()
	return str(_list.get_item_metadata(sel[0])) if not sel.is_empty() else ""


func _is_valid_input(text: String) -> bool:
	return PlayerLists.is_valid_ip(text) if entry_kind == EntryKind.IP else is_valid_name(text)


func _on_add() -> void:
	var value := _name_edit.text.strip_edges()
	if not _editable or not _is_valid_input(value):
		return
	var options := {}
	if show_level:
		options["level"] = _level_option.selected + 1
	if show_reason:
		options["reason"] = _reason_edit.text.strip_edges()
	_name_edit.clear()
	_reason_edit.clear()
	_update_buttons()
	add_requested.emit(value, options)


func _on_remove() -> void:
	var value := _selected_value()
	if _editable and value != "":
		remove_requested.emit(value)


func _update_selection() -> void:
	var value := _selected_value()
	_selected_row.visible = show_level and value != ""
	if value != "" and show_level:
		_suppress_level = true
		_selected_level.select(clampi(int(_entries.get(value, {}).get("level", 4)), 1, 4) - 1)
		_suppress_level = false
	_selected_level.disabled = not _editable or not _levels_editable


func _update_buttons() -> void:
	var typed := _name_edit.text.strip_edges()
	var valid := _is_valid_input(typed)
	_add_button.disabled = not _editable or not valid
	var rule := "Enter an IPv4 or IPv6 address." if entry_kind == EntryKind.IP else "Names are 3–16 letters, digits or underscores."
	_add_button.tooltip_text = "Add" if typed == "" or valid else rule
	_remove_button.disabled = not _editable or _selected_value() == ""
