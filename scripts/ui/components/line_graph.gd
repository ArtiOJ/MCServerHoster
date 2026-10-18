@tool
class_name LineGraph
extends Control
## Lightweight time-series graph drawn with _draw(): grid, filled area and line.

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

var values := PackedFloat32Array()


func set_values(new_values: PackedFloat32Array) -> void:
	values = new_values
	queue_redraw()


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
		top = maxf(top * 1.15, 1.0)
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
