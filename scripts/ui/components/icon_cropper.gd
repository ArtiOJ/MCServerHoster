class_name IconCropper
extends Control
## Interactive square crop of an image. The crop is kept in full-image pixels while
## a smaller preview texture is drawn. Drag inside to move, drag a corner to resize,
## scroll to zoom around the cursor, arrow keys nudge (Shift = 10×), +/- zoom.

signal crop_changed(crop: Rect2)

const HANDLE := 10.0
const MIN_CROP := 8.0
const DIM := Color(0.0, 0.0, 0.0, 0.6)
const CHECKER_A := Color(0.22, 0.24, 0.28)
const CHECKER_B := Color(0.16, 0.18, 0.21)

var crop := Rect2()
var image_size := Vector2i.ZERO

var _texture: Texture2D
## The visible area in image pixels: the "fit" square, so every valid crop fits on screen.
var _view := Rect2()
var _drag := ""  # "", "move", "tl", "tr", "bl", "br"
var _drag_start_mouse := Vector2.ZERO
var _drag_start_crop := Rect2()


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_MOVE
	resized.connect(queue_redraw)


## Shows [param preview] (a possibly downscaled copy) of an image whose full size is
## [param full_size], with [param initial_crop] in full-image pixels.
func set_image(preview: Texture2D, full_size: Vector2i, initial_crop: Rect2) -> void:
	_texture = preview
	image_size = full_size
	_view = ServerIcon.fit_crop(full_size)
	set_crop(initial_crop)


func clear() -> void:
	_texture = null
	image_size = Vector2i.ZERO
	queue_redraw()


func set_crop(rect: Rect2, emit := true) -> void:
	if image_size == Vector2i.ZERO:
		return
	crop = ServerIcon.clamp_crop(rect, image_size, minf(MIN_CROP, float(mini(image_size.x, image_size.y))))
	queue_redraw()
	if emit:
		crop_changed.emit(crop)


func fill() -> void:
	set_crop(ServerIcon.fill_crop(image_size))


func fit() -> void:
	set_crop(ServerIcon.fit_crop(image_size))


## Zooms the crop by [param factor] (< 1 zooms in) around [param pivot] in image pixels.
func zoom(factor: float, pivot := Vector2(INF, INF)) -> void:
	if pivot.x == INF:
		pivot = crop.get_center()
	var side := crop.size.x * factor
	var rel := (pivot - crop.position) / crop.size.x
	set_crop(Rect2(pivot - rel * side, Vector2(side, side)))


# --- Mapping between screen and image pixels ---------------------------------------

func _scale() -> float:
	if _view.size.x <= 0.0:
		return 1.0
	return minf(size.x, size.y) / _view.size.x


func _origin() -> Vector2:
	var side := _view.size.x * _scale()
	return (size - Vector2(side, side)) * 0.5


func _to_screen(p: Vector2) -> Vector2:
	return _origin() + (p - _view.position) * _scale()


func _to_image(p: Vector2) -> Vector2:
	return (p - _origin()) / _scale() + _view.position


func _screen_rect(r: Rect2) -> Rect2:
	return Rect2(_to_screen(r.position), r.size * _scale())


# --- Drawing ---------------------------------------------------------------------

func _draw() -> void:
	if _texture == null or image_size == Vector2i.ZERO:
		return
	var img_rect := _screen_rect(Rect2(Vector2.ZERO, Vector2(image_size)))
	_draw_checker(img_rect)
	draw_texture_rect(_texture, img_rect, false)
	var view_rect := _screen_rect(_view)
	var c := _screen_rect(crop)
	# Dim everything outside the crop (four bands around it).
	draw_rect(Rect2(view_rect.position, Vector2(view_rect.size.x, c.position.y - view_rect.position.y)), DIM)
	draw_rect(Rect2(Vector2(view_rect.position.x, c.end.y), Vector2(view_rect.size.x, view_rect.end.y - c.end.y)), DIM)
	draw_rect(Rect2(Vector2(view_rect.position.x, c.position.y), Vector2(c.position.x - view_rect.position.x, c.size.y)), DIM)
	draw_rect(Rect2(Vector2(c.end.x, c.position.y), Vector2(view_rect.end.x - c.end.x, c.size.y)), DIM)
	# Rule-of-thirds guides, border and corner handles.
	for i in [1, 2]:
		var t: float = i / 3.0
		draw_line(c.position + Vector2(c.size.x * t, 0), c.position + Vector2(c.size.x * t, c.size.y), Color(1, 1, 1, 0.25))
		draw_line(c.position + Vector2(0, c.size.y * t), c.position + Vector2(c.size.x, c.size.y * t), Color(1, 1, 1, 0.25))
	draw_rect(c, Color.WHITE, false, 2.0)
	for corner in _corners(c).values():
		draw_rect(Rect2(corner - Vector2(HANDLE, HANDLE) * 0.5, Vector2(HANDLE, HANDLE)), Color.WHITE)
	if has_focus():
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.247, 0.725, 0.498, 0.6), false, 1.0)


func _draw_checker(r: Rect2) -> void:
	var cell := 12.0
	var y := r.position.y
	var row := 0
	while y < r.end.y:
		var x := r.position.x
		var col := 0
		var h := minf(cell, r.end.y - y)
		while x < r.end.x:
			var w := minf(cell, r.end.x - x)
			draw_rect(Rect2(x, y, w, h), CHECKER_A if (row + col) % 2 == 0 else CHECKER_B)
			x += cell
			col += 1
		y += cell
		row += 1


func _corners(c: Rect2) -> Dictionary:
	return {"tl": c.position, "tr": Vector2(c.end.x, c.position.y), "bl": Vector2(c.position.x, c.end.y), "br": c.end}


# --- Input -----------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if image_size == Vector2i.ZERO:
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				grab_focus()
				_drag = _hit(mb.position)
				_drag_start_mouse = mb.position
				_drag_start_crop = crop
			else:
				_drag = ""
			accept_event()
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			zoom(0.9 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1, _to_image(mb.position))
			accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null:
		if _drag == "":
			var hit := _hit(mm.position)
			mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE if hit in ["tl", "br"] else (
					Control.CURSOR_BDIAGSIZE if hit in ["tr", "bl"] else Control.CURSOR_MOVE)
			return
		var delta := (mm.position - _drag_start_mouse) / _scale()
		if _drag == "move":
			set_crop(Rect2(_drag_start_crop.position + delta, _drag_start_crop.size))
		else:
			_resize_from_corner(delta)
		accept_event()
		return
	var key := event as InputEventKey
	if key != null and key.pressed:
		var step := 10.0 if key.shift_pressed else 1.0
		var move := Vector2.ZERO
		match key.keycode:
			KEY_LEFT:
				move.x = -step
			KEY_RIGHT:
				move.x = step
			KEY_UP:
				move.y = -step
			KEY_DOWN:
				move.y = step
			KEY_PLUS, KEY_EQUAL, KEY_KP_ADD:
				zoom(0.9)
				accept_event()
				return
			KEY_MINUS, KEY_KP_SUBTRACT:
				zoom(1.1)
				accept_event()
				return
			_:
				return
		set_crop(Rect2(crop.position + move, crop.size))
		accept_event()


func _hit(p: Vector2) -> String:
	var c := _screen_rect(crop)
	var corners := _corners(c)
	for name in corners:
		if p.distance_to(corners[name]) <= HANDLE:
			return name
	return "move"


## Resizes the square from the dragged corner; the opposite corner stays fixed.
func _resize_from_corner(delta: Vector2) -> void:
	var start := _drag_start_crop
	var anchor: Vector2 = {"tl": start.end, "tr": Vector2(start.position.x, start.end.y),
			"bl": Vector2(start.end.x, start.position.y), "br": start.position}[_drag]
	var dir_sign := Vector2(-1 if _drag in ["tl", "bl"] else 1, -1 if _drag in ["tl", "tr"] else 1)
	var grow := maxf(delta.x * dir_sign.x, delta.y * dir_sign.y)
	var side := maxf(start.size.x + grow, MIN_CROP)
	var pos := Vector2(anchor.x - side if dir_sign.x < 0 else anchor.x, anchor.y - side if dir_sign.y < 0 else anchor.y)
	set_crop(Rect2(pos, Vector2(side, side)))
