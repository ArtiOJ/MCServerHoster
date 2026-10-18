class_name PropertyRow
extends HBoxContainer
## One editable setting from [SettingsCatalog]. The scene contains an editor for every
## setting type; [method setup_entry] shows the one that matches. Descriptions are shown
## as tooltips so the row itself stays a plain "name + control" line.

signal changed(key: String, value: String)

## Catalog id for rows placed directly in a scene; set up with the catalog default on ready.
@export var setting_id := ""

## Catalog id of the setting this row edits.
var key := ""
## Value the row was created with, used to detect modifications.
var original_value := ""
var entry := {}

var _type: PropertySchema.Type = PropertySchema.Type.STRING
var _configured := false
var _pending := false
var _suppress := false

@onready var _name_label: Label = %NameLabel
@onready var _source_tag: Label = %SourceTag
@onready var _key_label: Label = %KeyLabel
@onready var _info: VBoxContainer = %Info
@onready var _modified_badge: Label = %ModifiedBadge
@onready var _bool_edit: CheckButton = %BoolEdit
@onready var _int_edit: SpinBox = %IntEdit
@onready var _enum_edit: OptionButton = %EnumEdit
@onready var _text_edit: LineEdit = %TextEdit


func _ready() -> void:
	_bool_edit.toggled.connect(_emit_changed.unbind(1))
	_int_edit.value_changed.connect(_emit_changed.unbind(1))
	_enum_edit.item_selected.connect(_emit_changed.unbind(1))
	_text_edit.text_changed.connect(_emit_changed.unbind(1))
	if _pending:
		_apply()
	elif not _configured and setting_id != "":
		var e := SettingsCatalog.get_entry(setting_id)
		if not e.is_empty():
			setup_entry(e, str(e.get("default", "")))


## Configures the row for a catalog [param setting] showing [param value].
## Can be called before or after the row enters the tree.
func setup_entry(setting: Dictionary, value: String) -> void:
	entry = setting
	key = str(setting.id)
	original_value = value
	_type = setting.get("type", PropertySchema.Type.STRING)
	_configured = true
	if is_node_ready():
		_apply()
	else:
		_pending = true


## Changes the value shown without making it the "original" (used to carry edits across rebuilds).
func set_value(value: String) -> void:
	if not is_node_ready():
		return
	_write_editor(value)
	mark_modified(is_modified())


func get_value() -> String:
	match _type:
		PropertySchema.Type.BOOL:
			return "true" if _bool_edit.button_pressed else "false"
		PropertySchema.Type.INT:
			return str(int(_int_edit.value))
		PropertySchema.Type.FLOAT:
			return _format_float(_int_edit.value)
		PropertySchema.Type.ENUM:
			return _enum_edit.get_item_text(_enum_edit.selected) if _enum_edit.selected >= 0 else original_value
		_:
			return _text_edit.text


func is_modified() -> bool:
	if _type == PropertySchema.Type.FLOAT:
		return not is_equal_approx(get_value().to_float(), original_value.to_float())
	return get_value() != original_value


func mark_modified(modified: bool) -> void:
	_modified_badge.visible = modified


## True when [param filter] (case-insensitive) occurs in the id, label or description.
func matches(filter: String) -> bool:
	var f := filter.strip_edges().to_lower()
	if f.is_empty():
		return true
	return key.to_lower().contains(f) or str(entry.get("label", "")).to_lower().contains(f) \
		or str(entry.get("desc", "")).to_lower().contains(f)


func _apply() -> void:
	_pending = false
	_suppress = true
	_name_label.text = str(entry.get("label", key))
	var tag := SettingsCatalog.source_tag(entry)
	_source_tag.text = tag
	_source_tag.visible = tag != ""
	_key_label.text = str(entry.get("key", key))
	var tip := str(entry.get("desc", ""))
	var where := SettingsCatalog.location(entry)
	tip = (tip + "\n\n" + where) if tip != "" else where
	for c: Control in [self, _info, _bool_edit, _int_edit, _enum_edit, _text_edit]:
		c.tooltip_text = tip
	_bool_edit.visible = _type == PropertySchema.Type.BOOL
	_int_edit.visible = _type == PropertySchema.Type.INT or _type == PropertySchema.Type.FLOAT
	_enum_edit.visible = _type == PropertySchema.Type.ENUM
	_text_edit.visible = _type == PropertySchema.Type.STRING
	match _type:
		PropertySchema.Type.INT:
			_int_edit.step = 1.0
			_int_edit.rounded = true
			_int_edit.min_value = float(entry.get("min", -2147483648))
			_int_edit.max_value = float(entry.get("max", 2147483647))
		PropertySchema.Type.FLOAT:
			_int_edit.rounded = false
			_int_edit.step = float(entry.get("step", 0.1))
			_int_edit.min_value = float(entry.get("min", -1000000.0))
			_int_edit.max_value = float(entry.get("max", 1000000.0))
		PropertySchema.Type.ENUM:
			_enum_edit.clear()
			var options: Array = entry.get("options", []).duplicate()
			if not options.has(original_value) and original_value != "":
				options.append(original_value)
			for opt in options:
				_enum_edit.add_item(str(opt))
	_write_editor(original_value)
	mark_modified(false)
	_suppress = false


func _write_editor(value: String) -> void:
	var was := _suppress
	_suppress = true
	match _type:
		PropertySchema.Type.BOOL:
			_bool_edit.button_pressed = value.to_lower() == "true"
		PropertySchema.Type.INT:
			_int_edit.value = value.to_int()
		PropertySchema.Type.FLOAT:
			_int_edit.value = value.to_float()
		PropertySchema.Type.ENUM:
			for i in _enum_edit.item_count:
				if _enum_edit.get_item_text(i) == value:
					_enum_edit.select(i)
					break
		_:
			_text_edit.text = value
	_suppress = was


static func _format_float(v: float) -> String:
	var s := String.num(v, 3)
	return s if s.contains(".") else s + ".0"


func _emit_changed() -> void:
	if _suppress:
		return
	mark_modified(is_modified())
	changed.emit(key, get_value())
