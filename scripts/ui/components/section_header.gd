@tool
class_name SectionHeader
extends VBoxContainer
## Category heading with a separator, used to group rows in long forms.

@export var title := "Section":
	set(value):
		title = value
		if is_node_ready():
			_title_label.text = value

@onready var _title_label: Label = %TitleLabel


func _ready() -> void:
	title = title
