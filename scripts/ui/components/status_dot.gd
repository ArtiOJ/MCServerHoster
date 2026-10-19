@tool
class_name StatusDot
extends Control
## Small filled circle showing a server's state colour; pulses while [member pulsing].

@export var color := Color("6b7280"):
	set(value):
		color = value
		queue_redraw()
@export var pulsing := false:
	set(value):
		pulsing = value
		set_process(value and not Engine.is_editor_hint())
		if not value:
			modulate.a = 1.0

var _t := 0.0


func _ready() -> void:
	set_process(pulsing and not Engine.is_editor_hint())


func _process(delta: float) -> void:
	_t += delta
	modulate.a = 0.55 + 0.45 * (0.5 + 0.5 * sin(_t * 5.0))


func _draw() -> void:
	var r := minf(size.x, size.y) * 0.5
	draw_circle(size * 0.5, r, color, true, -1.0, true)


func show_state(handle: ServerHandle) -> void:
	color = handle.state_color()
	var connected := not handle.is_remote() or (handle as RemoteServer).is_connected_to_host()
	pulsing = connected and handle.state in [ServerHandle.State.STARTING, ServerHandle.State.STOPPING, ServerHandle.State.INSTALLING]
