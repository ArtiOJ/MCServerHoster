@tool
class_name StatCard
extends PanelContainer
## Dashboard tile: caption, large value and a muted sub-line.

@export var title := "Title":
	set(value):
		title = value
		if is_node_ready():
			_title_label.text = value.to_upper()
@export var icon: Texture2D:
	set(value):
		icon = value
		if is_node_ready():
			_icon_rect.texture = value
			_icon_rect.visible = value != null

@onready var _title_label: Label = %TitleLabel
@onready var _icon_rect: TextureRect = %Icon
@onready var _value_label: Label = %ValueLabel
@onready var _sub_label: Label = %SubLabel


func _ready() -> void:
	title = title
	icon = icon


func set_value(text: String, color := Color(0, 0, 0, 0)) -> void:
	_value_label.text = text
	if color.a > 0.0:
		_value_label.add_theme_color_override("font_color", color)
	else:
		_value_label.remove_theme_color_override("font_color")


func set_sub(text: String) -> void:
	_sub_label.text = text
	_sub_label.visible = text != ""
