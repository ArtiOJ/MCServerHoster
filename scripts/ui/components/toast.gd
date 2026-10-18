class_name Toast
extends PanelContainer
## A transient notification card; dismisses itself after a delay or on click.

const LEVEL_COLORS: Array[Color] = [Color("5aa9f2"), Color("3fb97f"), Color("f2b84b"), Color("e05555")]

@onready var _label: Label = %MessageLabel
@onready var _close: Button = %CloseButton
@onready var _timer: Timer = %LifeTimer


func _ready() -> void:
	_close.pressed.connect(dismiss)
	_timer.timeout.connect(dismiss)


func show_message(message: String, level: int) -> void:
	_label.text = message
	var style := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	style.border_color = LEVEL_COLORS[clampi(level, 0, LEVEL_COLORS.size() - 1)]
	add_theme_stylebox_override("panel", style)
	_timer.start(8.0 if level >= Notifier.Level.WARNING else 4.5)
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.15)


func dismiss() -> void:
	_timer.stop()
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.2)
	tween.tween_callback(queue_free)
