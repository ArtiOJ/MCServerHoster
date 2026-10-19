@tool
class_name ServerIconView
extends Control
## Shows a server's icon, or a rounded placeholder in the server's colour with its
## initial. Optionally clickable (e.g. to open the icon editor).

signal clicked

@export var clickable := false:
	set(value):
		clickable = value
		mouse_filter = Control.MOUSE_FILTER_STOP if value else Control.MOUSE_FILTER_IGNORE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if value else Control.CURSOR_ARROW
@export var corner_radius := 6

@onready var _placeholder: Panel = %Placeholder
@onready var _initial: Label = %Initial
@onready var _icon: TextureRect = %Icon


func _ready() -> void:
	clickable = clickable
	resized.connect(_update_font)
	_update_font()


## Shows the icon stored in [param dir], or a placeholder from [param display_name] and [param color].
func show_server(display_name: String, color: Color, dir: String) -> void:
	show_texture(ServerIcon.load_texture(dir) if dir != "" else null, display_name, color)


func show_instance(inst: ServerInstance) -> void:
	show_server(inst.config.display_name, inst.config.color, inst.config.directory)


func show_texture(texture: Texture2D, display_name := "", color := Color("3fb97f")) -> void:
	if not is_node_ready():
		await ready
	_icon.texture = texture
	_icon.visible = texture != null
	_placeholder.visible = texture == null
	_initial.text = display_name.strip_edges().left(1).to_upper() if display_name.strip_edges() != "" else "?"
	var style := StyleBoxFlat.new()
	style.bg_color = color.darkened(0.35)
	style.border_color = color
	style.set_border_width_all(1)
	style.set_corner_radius_all(corner_radius)
	_placeholder.add_theme_stylebox_override("panel", style)


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if clickable and mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit()
		accept_event()


func _update_font() -> void:
	if is_node_ready():
		_initial.add_theme_font_size_override("font_size", maxi(int(minf(size.x, size.y) * 0.5), 8))
