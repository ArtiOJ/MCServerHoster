class_name PortField
extends LineEdit
## Text field for a TCP port. Unlike a SpinBox it never rewrites what the user is
## typing: it only keeps digits, reports validity, and shows invalid input in red.
## ↑/↓ and the mouse wheel step the port by one.

## Emitted on every edit. [param valid] is false while the text is not a usable port.
signal port_changed(port: int, valid: bool)

## Ports below 1024 need root on Linux, so a server started by this app cannot bind them.
const MIN_PORT := 1024
const MAX_PORT := 65535

var port: int:
	get:
		return text.to_int() if text.is_valid_int() else 0
	set(value):
		set_port(value)



func _ready() -> void:
	max_length = 5
	select_all_on_focus = true
	text_changed.connect(_on_text_changed)
	text_submitted.connect(func(_t: String) -> void: release_focus())
	_update_style()


## Sets the port without emitting [signal port_changed].
func set_port(value: int) -> void:
	text = str(value)
	_update_style()


func is_valid() -> bool:
	return error_text() == ""


## Why the current text is not a usable port ("" when it is).
func error_text() -> String:
	if text == "":
		return "Enter a port number."
	var p := port
	if p < MIN_PORT:
		return "Ports below %d need administrator rights on Linux." % MIN_PORT if p > 0 else "Enter a port number."
	if p > MAX_PORT:
		return "The highest port is %d." % MAX_PORT
	return ""


func _gui_input(event: InputEvent) -> void:
	var step := 0
	var key := event as InputEventKey
	if key != null and key.pressed:
		if key.keycode == KEY_UP:
			step = 1
		elif key.keycode == KEY_DOWN:
			step = -1
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and has_focus():
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			step = 1
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			step = -1
	if step != 0:
		set_port(clampi((port if port > 0 else MIN_PORT) + step, MIN_PORT, MAX_PORT))
		caret_column = text.length()
		port_changed.emit(port, is_valid())
		accept_event()


func _on_text_changed(new_text: String) -> void:
	var digits := ""
	for c in new_text:
		if c >= "0" and c <= "9":
			digits += c
	if digits != new_text:
		var caret := caret_column - (new_text.length() - digits.length())
		text = digits
		caret_column = clampi(caret, 0, digits.length())
	_update_style()
	port_changed.emit(port, is_valid())


func _update_style() -> void:
	var valid := is_valid()
	theme_type_variation = &"" if valid else &"InvalidInput"
	tooltip_text = "TCP port (%d–%d). ↑/↓ or the mouse wheel change it by one." % [MIN_PORT, MAX_PORT] if valid else error_text()
