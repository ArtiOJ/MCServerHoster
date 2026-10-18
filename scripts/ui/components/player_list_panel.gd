class_name PlayerListPanel
extends PanelContainer
## Card listing player names (whitelist, operators, bans) with add/remove controls.

signal add_requested(player_name: String)
signal remove_requested(player_name: String)

@export var title := "Players":
	set(value):
		title = value
		if is_node_ready():
			_title_label.text = value

static var _re_name := RegEx.create_from_string("^[A-Za-z0-9_]{3,16}$")

var _editable := true

@onready var _title_label: Label = %TitleLabel
@onready var _count_label: Label = %CountLabel
@onready var _list: ItemList = %NameList
@onready var _name_edit: LineEdit = %NameEdit
@onready var _add_button: Button = %AddButton
@onready var _remove_button: Button = %RemoveButton
@onready var _hint_label: Label = %HintLabel


func _ready() -> void:
	title = title
	_add_button.pressed.connect(_on_add)
	_name_edit.text_submitted.connect(_on_add.unbind(1))
	_name_edit.text_changed.connect(_update_buttons.unbind(1))
	_remove_button.pressed.connect(_on_remove)
	_list.item_selected.connect(_update_buttons.unbind(1))
	_list.empty_clicked.connect(func(_p: Vector2, _b: int) -> void:
		_list.deselect_all()
		_update_buttons())
	_update_buttons()


static func is_valid_name(player_name: String) -> bool:
	return _re_name.search(player_name) != null


func set_names(names: PackedStringArray) -> void:
	var selected := _selected_name()
	_list.clear()
	var sorted := Array(names)
	sorted.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	for n in sorted:
		var idx := _list.add_item(n)
		if n == selected:
			_list.select(idx)
	_count_label.text = str(names.size())
	_update_buttons()


func set_editable(editable: bool, hint := "") -> void:
	_editable = editable
	_name_edit.editable = editable
	_hint_label.text = hint
	_hint_label.visible = hint != ""
	_update_buttons()


func _selected_name() -> String:
	var sel := _list.get_selected_items()
	return _list.get_item_text(sel[0]) if not sel.is_empty() else ""


func _on_add() -> void:
	var n := _name_edit.text.strip_edges()
	if not _editable or not is_valid_name(n):
		return
	_name_edit.clear()
	_update_buttons()
	add_requested.emit(n)


func _on_remove() -> void:
	var n := _selected_name()
	if _editable and n != "":
		remove_requested.emit(n)


func _update_buttons() -> void:
	var typed := _name_edit.text.strip_edges()
	_add_button.disabled = not _editable or not is_valid_name(typed)
	_add_button.tooltip_text = "" if typed == "" or is_valid_name(typed) else "Names are 3–16 letters, digits or underscores."
	_remove_button.disabled = not _editable or _selected_name() == ""
