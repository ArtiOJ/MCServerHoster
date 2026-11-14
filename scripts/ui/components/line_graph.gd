@tool
class_name LineGraph
extends Control
## Lightweight time-series graph drawn with _draw(): grid, filled area and line, plus an
## optional limit line, red marks along the top (e.g. lost pings) and a hover readout.

@export var line_color := Color("3fb97f"):
	set(value):
		line_color = value
		queue_redraw()
## Fixed upper bound of the Y axis; 0 scales to the data.
@export var max_value := 100.0:
	set(value):
		max_value = value
		queue_redraw()
## Number of samples the X axis spans.
@export var capacity := 120
@export var grid_lines := 4
## Draws a dashed line at this value (0 = none), e.g. the 50 ms tick limit.
@export var threshold := 0.0:
	set(value):
		threshold = value
		queue_redraw()

var values := PackedFloat32Array()
## Sample indices marked in red along the top edge.
var marks := PackedInt32Array()
## Returns the hover text for a sample index; when set, hovering shows it.
var hover_text := Callable()

var _hover := -1


func set_values(new_values: PackedFloat32Array) -> void:
	values = new_values
	if _hover >= values.size():
		_hover = -1
	queue_redraw()


func set_marks(new_marks: PackedInt32Array) -> void:
	marks = new_marks
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and hover_text.is_valid():
		var i := _index_at(event.position.x)
		if i != _hover:
			_hover = i
			tooltip_text = str(hover_text.call(i)) if i >= 0 else ""
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover >= 0:
		_hover = -1
		queue_redraw()


func _get_tooltip(_at_position: Vector2) -> String:
	return str(hover_text.call(_hover)) if _hover >= 0 and hover_text.is_valid() else ""


func _index_at(x: float) -> int:
	if values.size() < 2:
		return -1
	var step := size.x / maxf(capacity - 1, 1)
	var x0 := size.x - step * (values.size() - 1)
	var i := roundi((x - x0) / step)
	return i if i >= 0 and i < values.size() else -1


func _draw() -> void:
	var grid_color := Color(1, 1, 1, 0.06)
	for i in range(1, grid_lines):
		var y := size.y * i / grid_lines
		draw_line(Vector2(0, y), Vector2(size.x, y), grid_color, 1.0)
	if values.size() < 2:
		return
	var top := max_value
	if top <= 0.0:
		for v in values:
			top = maxf(top, v)
		top = maxf(maxf(top, threshold) * 1.15, 1.0)
	var step := size.x / maxf(capacity - 1, 1)
	var x0 := size.x - step * (values.size() - 1)
	var points := PackedVector2Array()
	for i in values.size():
		var y := size.y - clampf(values[i] / top, 0.0, 1.0) * (size.y - 2.0) - 1.0
		points.append(Vector2(x0 + step * i, y))
	var fill := points.duplicate()
	fill.append(Vector2(points[-1].x, size.y))
	fill.append(Vector2(points[0].x, size.y))
	var fill_color := line_color
	fill_color.a = 0.15
	draw_colored_polygon(fill, fill_color)
	draw_polyline(points, line_color, 2.0, true)
	if threshold > 0.0 and threshold < top:
		var ty := size.y - threshold / top * (size.y - 2.0) - 1.0
		draw_dashed_line(Vector2(0, ty), Vector2(size.x, ty), Color(0.878, 0.333, 0.333, 0.55), 1.0, 6.0)
	for i in marks:
		if i >= 0 and i < points.size():
			draw_rect(Rect2(points[i].x - 1.5, 0, 3, 6), Color("e05555"))
	if _hover >= 0 and _hover < points.size():
		draw_line(Vector2(points[_hover].x, 0), Vector2(points[_hover].x, size.y), Color(1, 1, 1, 0.25), 1.0)
		draw_circle(points[_hover], 3.5, line_color)
