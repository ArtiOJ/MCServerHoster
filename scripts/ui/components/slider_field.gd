@tool
class_name SliderField
extends VBoxContainer
## Labelled slider with a formatted value readout and an optional hint line.

signal value_changed(value: float)

enum Unit { NONE, MEGABYTES, PERCENT, CORES, NICE }

@export var title := "Value":
	set(v):
		title = v
		if is_node_ready():
			_title_label.text = v
@export var unit: Unit = Unit.NONE
@export var min_value := 0.0:
	set(v):
		min_value = v
		if is_node_ready():
			_slider.min_value = v
@export var max_value := 100.0:
	set(v):
		max_value = v
		if is_node_ready():
			_slider.max_value = v
@export var step := 1.0:
	set(v):
		step = v
		if is_node_ready():
			_slider.step = v
## Text shown instead of the number when the slider is at [member min_value] (e.g. "Unlimited").
@export var zero_text := ""
@export_multiline var hint := "":
	set(v):
		hint = v
		if is_node_ready():
			_hint_label.text = v
			_hint_label.visible = v != ""

var value: float:
	get:
		return _slider.value
	set(v):
		_slider.set_value_no_signal(v)
		_update_label()

@onready var _title_label: Label = %TitleLabel
@onready var _value_label: Label = %ValueLabel
@onready var _slider: HSlider = %Slider
@onready var _hint_label: Label = %HintLabel


func _ready() -> void:
	_slider.min_value = min_value
	_slider.max_value = max_value
	_slider.step = step
	title = title
	hint = hint
	_slider.value_changed.connect(func(v: float) -> void:
		_update_label()
		value_changed.emit(v))
	_update_label()


func set_editable(editable: bool) -> void:
	_slider.editable = editable


func _update_label() -> void:
	if not is_node_ready():
		return
	var v := _slider.value
	if zero_text != "" and is_equal_approx(v, min_value):
		_value_label.text = zero_text
		return
	match unit:
		Unit.MEGABYTES:
			_value_label.text = Fmt.megabytes(int(v))
		Unit.PERCENT:
			_value_label.text = "%d%%  (%s cores)" % [int(v), String.num(v / 100.0, 2)]
		Unit.CORES:
			_value_label.text = "%d core%s" % [int(v), "" if int(v) == 1 else "s"]
		Unit.NICE:
			_value_label.text = "%d  (%s)" % [int(v), "normal" if v == 0 else ("low" if v < 10 else "lowest")]
		_:
			_value_label.text = str(int(v)) if is_equal_approx(step, roundf(step)) else "%.2f" % v
