@tool
class_name GraphCard
extends PanelContainer
## A card with a caption, a current-value readout and a LineGraph.

@export var title := "Graph":
	set(value):
		title = value
		if is_node_ready():
			_title_label.text = value.to_upper()
@export var line_color := Color("3fb97f"):
	set(value):
		line_color = value
		if is_node_ready():
			_graph.line_color = value

@onready var _title_label: Label = %TitleLabel
@onready var _value_label: Label = %ValueLabel
@onready var _graph: LineGraph = %Graph


func _ready() -> void:
	title = title
	line_color = line_color


func set_data(values: PackedFloat32Array, current_text: String, max_value := 0.0) -> void:
	_graph.max_value = max_value
	_graph.set_values(values)
	_value_label.text = current_text
