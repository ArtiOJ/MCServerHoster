class_name PropertyRow
extends HBoxContainer
## One editable server.properties entry. The scene contains an editor for every
## property type; [method setup] shows the one matching the key's schema type.

signal changed(key: String, value: String)

var key := ""
## Value the row was created with, used to detect modifications.
var original_value := ""

var _info := {}
var _type: PropertySchema.Type = PropertySchema.Type.STRING
var _pending := false
var _suppress := false

@onready var _name_label: Label = %NameLabel
@onready var _desc_label: Label = %DescLabel
@onready var _key_label: Label = %KeyLabel
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


## Configures the row for [param property_key] showing [param value]. Can be called before or after the row enters the tree.
func setup(property_key: String, value: String) -> void:
	key = property_key
	original_value = value
	_info = PropertySchema.get_info(property_key)
	_type = PropertySchema.infer_type(property_key, value)
	if is_node_ready():
		_apply()
	else:
		_pending = true


func get_value() -> String:
	match _type:
		PropertySchema.Type.BOOL:
			return "true" if _bool_edit.button_pressed else "false"
		PropertySchema.Type.INT:
			return str(int(_int_edit.value))
		PropertySchema.Type.ENUM:
			return _enum_edit.get_item_text(_enum_edit.selected) if _enum_edit.selected >= 0 else original_value
		_:
			return _text_edit.text


func is_modified() -> bool:
	return get_value() != original_value


func mark_modified(modified: bool) -> void:
	_modified_badge.visible = modified


## True when [param filter] (case-insensitive) occurs in the key, label or description.
func matches(filter: String) -> bool:
	var f := filter.strip_edges().to_lower()
	if f.is_empty():
		return true
	return key.to_lower().contains(f) or str(_info.get("label", "")).to_lower().contains(f) \
		or str(_info.get("desc", "")).to_lower().contains(f)


func _apply() -> void:
	_pending = false
	_suppress = true
	_name_label.text = str(_info.get("label", key))
	var desc := str(_info.get("desc", ""))
	_desc_label.text = desc
	_desc_label.visible = desc != ""
	_key_label.text = key
	_bool_edit.visible = _type == PropertySchema.Type.BOOL
	_int_edit.visible = _type == PropertySchema.Type.INT
	_enum_edit.visible = _type == PropertySchema.Type.ENUM
	_text_edit.visible = _type == PropertySchema.Type.STRING
	match _type:
		PropertySchema.Type.BOOL:
			_bool_edit.button_pressed = original_value.to_lower() == "true"
		PropertySchema.Type.INT:
			_int_edit.min_value = float(_info.get("min", -2147483648))
			_int_edit.max_value = float(_info.get("max", 2147483647))
			_int_edit.value = original_value.to_int()
		PropertySchema.Type.ENUM:
			_enum_edit.clear()
			var options: Array = _info.get("options", [])
			if not options.has(original_value) and original_value != "":
				options = options + [original_value]
			for opt in options:
				_enum_edit.add_item(str(opt))
			_enum_edit.select(maxi(options.find(original_value), 0))
		_:
			_text_edit.text = original_value
	mark_modified(false)
	_suppress = false


func _emit_changed() -> void:
	if _suppress:
		return
	mark_modified(is_modified())
	changed.emit(key, get_value())
