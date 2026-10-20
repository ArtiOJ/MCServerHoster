class_name BlueMapViewer
extends Control
## A map rendered by BlueMap, drawn natively: BlueMap's lowres levels and hires tiles with
## its own shading, live players and markers, and its three views: perspective (drag to
## move, right-drag or Ctrl+drag to turn and tilt, wheel to zoom), flat (top-down) and free
## flight (drag to look, WASD to fly, Space and Shift for up and down, wheel for speed).
## Files come through the server's bluemap_files operation, so a server on another
## computer works the same way. Tiles are decoded on worker threads (see Prbm) and reloaded
## when BlueMap renders them again.

## Loading progress or why nothing shows ("" when all is loaded).
signal info_changed(text: String)

enum View { PERSPECTIVE, FLAT, FREE }

const HIRES_SHADER := preload("res://assets/shaders/bluemap_hires.gdshader")
const HIRES_TRANSPARENT_SHADER := preload("res://assets/shaders/bluemap_hires_transparent.gdshader")
const LOWRES_SHADER := preload("res://assets/shaders/bluemap_lowres.gdshader")
const VIEW_NAMES: PackedStringArray = ["3D", "Flat", "Free"]
const VIEW_TIPS: PackedStringArray = [
	"Perspective: drag to move, right-drag (or Ctrl+drag) to turn and tilt, wheel to zoom. WASD and Q/E work too.",
	"Top-down: drag to move, right-drag to turn, wheel to zoom.",
	"Free flight: drag to look around, WASD to fly, Space/Shift for up/down, wheel for speed.",
]
## Hires tiles are shown within this many blocks of the centre (BlueMap's default first).
const DETAIL_DISTANCES: PackedFloat32Array = [100.0, 200.0, 350.0]
const DETAIL_NAMES: PackedStringArray = ["Detail: near", "Detail: farther", "Detail: farthest"]
## Lowres tiles are loaded within this many blocks (BlueMap's default).
const LOWRES_DISTANCE := 2000.0
## Hires tiles aren't loaded when the camera is farther than this.
const HIRES_MAX_DISTANCE := 1000.0
## Texels per side of the mask of loaded hires tiles (lowres gives way where it is set).
const MASK_SIZE := 96
const FETCH_BATCH := 24
const MAX_JOBS := 6
const FINALIZE_PER_FRAME := 3
const REFRESH_SEC := 15.0
const LIVE_SEC := 2.0
const MIN_DISTANCE := 5.0
const MAX_DISTANCE := 100000.0
const FOV := 75.0

var handle: ServerHandle
var map_id := ""
## Seconds between checks for tiles BlueMap rendered again (shorter while it renders).
var refresh_interval := REFRESH_SEC
var view := View.PERSPECTIVE
var detail := 0

var _generation := 0
var _ready_to_draw := false
var _suffix := ".gz"
var _hires_tile := Vector2(32, 32)
var _hires_translate := Vector2(2, 2)
var _hires_scale := Vector2(1, 1)
var _lowres_tile := Vector2(500, 500)
var _lod_factor := 5
var _lod_count := 3
var _views := [true, true, true]
var _start_pos := Vector2.ZERO
## Server and map last opened: reopening the same map keeps the camera where it was.
var _last_opened := ""
var _textures: ImageTexture
var _transparent := {}
var _cutout := {}
## path -> {node, mtime, lod, key, image (level 1, for heights)}
var _tiles := {}
## Paths of tiles that don't exist (yet).
var _missing := {}
## path -> {lod, key} of the tiles the camera wants.
var _wanted := {}
var _in_flight := {}
## Decoding on worker threads: [{task, box, path, lod, key, mtime, generation}].
var _jobs := []
var _fetching := false
var _mask_image: Image
var _mask_texture: ImageTexture
var _mask_origin := Vector2i(1 << 30, 0)
var _mask_dirty := false
var _last_center := Vector3(INF, 0, 0)
var _refresh_left := REFRESH_SEC
var _live_left := 0.0
var _live_busy := false
var _markers_mtime := -1
var _players := []
var _heads := {}
var _overlay_items := {}

# Camera
var _target := Vector3.ZERO
var _distance := 400.0
var _yaw := 0.0
var _angle := 0.7
var _free_position := Vector3.ZERO
var _free_yaw := 0.0
var _free_pitch := -0.5
var _free_speed := 30.0
var _drag := 0
var _height_smoothing := true
## Shader globals as last set (setting them redraws, so only changes are sent).
var _globals := {}

@onready var _viewport: SubViewport = %Viewport
@onready var _camera: Camera3D = %Camera
@onready var _environment: WorldEnvironment = %Environment
@onready var _tile_root: Node3D = %TileRoot
@onready var _marker_root: Node3D = %MarkerRoot
@onready var _overlay: Control = %Overlay
@onready var _view_option: OptionButton = %ViewOption
@onready var _detail_option: OptionButton = %DetailOption
@onready var _reset_button: Button = %ResetButton
@onready var _light_slider: HSlider = %LightSlider
@onready var _coords_label: Label = %CoordsLabel
@onready var _info_label: Label = %InfoLabel
@onready var _players_box: VBoxContainer = %PlayersBox
@onready var _players_panel: PanelContainer = %PlayersPanel
@onready var _empty_label: Label = %EmptyLabel


func _ready() -> void:
	for i in VIEW_NAMES.size():
		_view_option.add_item(VIEW_NAMES[i])
		_view_option.set_item_tooltip(i, VIEW_TIPS[i])
	_view_option.item_selected.connect(func(i: int) -> void: set_view(i))
	for i in DETAIL_NAMES.size():
		_detail_option.add_item(DETAIL_NAMES[i])
	_detail_option.select(detail)
	_detail_option.item_selected.connect(func(i: int) -> void:
		detail = i
		_last_center = Vector3(INF, 0, 0))
	_reset_button.pressed.connect(reset_view)
	_light_slider.value_changed.connect(func(v: float) -> void: _set_global("bm_sunlight", v))
	_mask_image = Image.create_empty(MASK_SIZE, MASK_SIZE, false, Image.FORMAT_L8)
	_mask_texture = ImageTexture.create_from_image(_mask_image)
	focus_mode = Control.FOCUS_ALL
	visibility_changed.connect(func() -> void: set_process(is_visible_in_tree()))
	set_process(is_visible_in_tree())
	_show_empty("")


## Shows map [param id] of [param h] (whose files use [param suffix], see BlueMap.map_storage).
func open(h: ServerHandle, id: String, suffix: String) -> void:
	clear()
	handle = h
	map_id = id
	_suffix = suffix
	_generation += 1
	var gen := _generation
	_set_info("Loading the map…")
	var res := await _fetch([{"path": "settings.json", "mtime": -1}, {"path": "textures.json" + suffix, "mtime": -1}])
	if gen != _generation:
		return
	if res.has("error"):
		_show_empty(str(res.error))
		return
	if not res.files.has("settings.json") or not res.files.has("textures.json" + suffix):
		_show_empty("This map hasn't been rendered yet.")
		return
	var settings: Variant = JSON.parse_string(res.files["settings.json"].bytes.get_string_from_utf8())
	if not settings is Dictionary:
		_show_empty("BlueMap's settings for this map can't be read.")
		return
	_apply_settings(settings)
	var box := {}
	var task := WorkerThreadPool.add_task(_decode_textures.bind(box, res.files["textures.json" + suffix].bytes, suffix))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if gen != _generation:
		return
	var tex: Dictionary = box.get("result", {"ok": false, "error": "no textures"})
	if not tex.ok:
		_show_empty("This map can't be shown: %s." % tex.error)
		return
	_textures = ImageTexture.create_from_image(tex.atlas)
	_transparent = tex.transparent
	_cutout = tex.cutout
	_ready_to_draw = true
	_show_empty("")
	_set_info("")
	_update_camera()


## Forgets the map shown (tiles, markers, players).
func clear() -> void:
	_generation += 1
	_ready_to_draw = false
	for path in _tiles:
		_tiles[path].node.queue_free()
	_tiles.clear()
	_missing.clear()
	_wanted.clear()
	_in_flight.clear()
	for child in _marker_root.get_children():
		child.queue_free()
	for item in _overlay_items.values():
		item.queue_free()
	_overlay_items.clear()
	_players = []
	_fill_players()
	_markers_mtime = -1
	_mask_origin = Vector2i(1 << 30, 0)
	_last_center = Vector3(INF, 0, 0)
	map_id = ""


func set_view(v: int) -> void:
	if not _views[v]:
		v = View.PERSPECTIVE
	if v == View.FREE and view != View.FREE:
		_free_position = _camera.position
		_free_yaw = _yaw
		_free_pitch = -(PI / 2 - _angle) if view == View.PERSPECTIVE else -PI / 2 + 0.01
	elif v != View.FREE and view == View.FREE:
		var forward := -_camera.global_basis.z
		var ground := _height_at(_free_position.x, _free_position.z)
		var dist := clampf((_free_position.y - (ground if not is_nan(ground) else 64.0)) / maxf(-forward.y, 0.2), MIN_DISTANCE, 2000.0)
		_target = _free_position + forward * dist
		_distance = dist
		_yaw = _free_yaw
	view = v as View
	_view_option.select(view)
	_last_center = Vector3(INF, 0, 0)
	_update_camera()


## Back to the map's start position, facing north.
func reset_view() -> void:
	_yaw = 0.0
	_angle = 0.7
	_distance = 400.0
	_target = Vector3(_start_pos.x, _target.y, _start_pos.y)
	set_view(View.PERSPECTIVE)


func _apply_settings(s: Dictionary) -> void:
	var hires: Dictionary = s.get("hires", {})
	_hires_tile = _vec2(hires.get("tileSize"), Vector2(32, 32))
	_hires_translate = _vec2(hires.get("translate"), Vector2(2, 2))
	_hires_scale = _vec2(hires.get("scale"), Vector2(1, 1))
	var lowres: Dictionary = s.get("lowres", {})
	_lowres_tile = _vec2(lowres.get("tileSize"), Vector2(500, 500))
	_lod_factor = maxi(int(lowres.get("lodFactor", 5)), 1)
	_lod_count = clampi(int(lowres.get("lodCount", 3)), 1, 6)
	_views = [bool(s.get("perspectiveView", true)), bool(s.get("flatView", true)), bool(s.get("freeFlightView", true))]
	for i in 3:
		_view_option.set_item_disabled(i, not _views[i])
	if not _views[view]:
		view = View.FLAT if _views[View.FLAT] else View.PERSPECTIVE
		_view_option.select(view)
	var start := _vec2(s.get("startPos"), Vector2.ZERO)
	var opened := "%s/%s" % [handle.key() if handle != null else "", map_id]
	if opened != _last_opened or start != _start_pos:
		_last_opened = opened
		_start_pos = start
		_target = Vector3(start.x, 64.0, start.y)
		_yaw = 0.0
		_angle = 0.7
		_distance = 400.0
		view = View.PERSPECTIVE if _views[View.PERSPECTIVE] else (View.FLAT if _views[View.FLAT] else View.FREE)
		_view_option.select(view)
	var sky := _color(s.get("skyColor"), Color("#7dabff"))
	var env := _environment.environment
	env.background_mode = Environment.BG_COLOR
	env.background_color = sky
	_set_global("bm_void_color", _color(s.get("voidColor"), Color.BLACK))
	_set_global("bm_ambient", float(s.get("ambientLight", 0.0)))
	_light_slider.value = clampf(float(s.get("skyLight", 1.0)), 0.0, 1.0)
	_set_global("bm_sunlight", _light_slider.value)
	_set_global("bm_hires_translate", _hires_translate)
	_set_global("bm_hires_tile_size", _hires_tile.x)
	_set_global("bm_hires_mask_size", float(MASK_SIZE))
	_set_global("bm_hires_mask", _mask_texture)


static func _vec2(v: Variant, default: Vector2) -> Vector2:
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is Dictionary:
		return Vector2(float(v.get("x", default.x)), float(v.get("z", v.get("y", default.y))))
	return default


static func _color(v: Variant, default: Color) -> Color:
	if v is Array and v.size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return default


# --- Every frame -----------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _ready_to_draw:
		return
	_keyboard(delta)
	_update_camera()
	var center := _center()
	if center.distance_to(_last_center) > 8.0 or _last_center.x == INF:
		_last_center = center
		_update_wanted(center)
	if not _fetching:
		_fetch_wanted()
	_finish_jobs()
	if _mask_dirty:
		_update_mask()
	_refresh_left = minf(_refresh_left - delta, refresh_interval)
	if _refresh_left <= 0.0:
		_refresh_left = refresh_interval
		_refresh()
	_live_left -= delta
	if _live_left <= 0.0 and not _live_busy:
		_live_left = LIVE_SEC
		_poll_live()
	_place_overlay()
	var p := _free_position if view == View.FREE else _target
	_coords_label.text = "x %d  y %d  z %d" % [roundi(p.x), roundi(p.y), roundi(p.z)]
	var loading := _in_flight.size() + _jobs.size()
	_set_info("Loading %d tiles…" % loading if loading > 0 else "")
	_check_empty(loading)


## Where tiles are loaded around: the point looked at, or the camera in free flight.
func _center() -> Vector3:
	return _free_position if view == View.FREE else _target


## Puts the camera where the view wants it. Only changed values are assigned: the app draws
## only when something changes (low processor mode), so an idle map costs nothing.
func _update_camera() -> void:
	_set_global("bm_flat", view == View.FLAT)
	if _height_smoothing and view != View.FREE:
		var h := _height_at(_target.x, _target.z)
		if not is_nan(h) and absf(_target.y - h) > 0.01:
			_target.y = lerpf(_target.y, h, 0.2) if absf(_target.y - h) > 0.05 else h
	var projection := Camera3D.PROJECTION_PERSPECTIVE
	var t := Transform3D()
	var near := 0.1
	var far := 20000.0
	match view:
		View.PERSPECTIVE:
			var offset := Vector3(sin(_yaw) * sin(_angle), cos(_angle), cos(_yaw) * sin(_angle)) * _distance
			t = Transform3D(Basis.looking_at(-offset, Vector3(-sin(_yaw), 0, -cos(_yaw)) if _angle < 0.01 else Vector3.UP), _target + offset)
			near = clampf(_distance * 0.01, 0.05, 20.0)
			far = clampf(_distance * 60.0, 3000.0, 400000.0)
			_set_global("bm_distance", _distance)
		View.FLAT:
			projection = Camera3D.PROJECTION_ORTHOGONAL
			t = Transform3D(Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, -PI / 2), _target + Vector3(0, 3000, 0))
			near = 1.0
			far = 8000.0
			if not is_equal_approx(_camera.size, _distance):
				_camera.size = _distance
			_set_global("bm_distance", _distance)
		View.FREE:
			t = Transform3D(Basis.from_euler(Vector3(_free_pitch, _free_yaw, 0)), _free_position)
			_set_global("bm_distance", 50.0)
	if _camera.projection != projection:
		_camera.projection = projection
	if not _camera.transform.is_equal_approx(t):
		_camera.transform = t
	if not is_equal_approx(_camera.near, near):
		_camera.near = near
	if not is_equal_approx(_camera.far, far):
		_camera.far = far


func _keyboard(delta: float) -> void:
	if not has_focus():
		return
	var move := Vector2(
		float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
	var turn := float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q))
	if view == View.FREE:
		var up := float(Input.is_physical_key_pressed(KEY_SPACE)) - float(Input.is_physical_key_pressed(KEY_SHIFT))
		var b := _camera.global_basis
		_free_position += (b.x * move.x + b.z * move.y + Vector3.UP * up) * _free_speed * delta
		_free_yaw -= turn * 1.5 * delta
		return
	if move != Vector2.ZERO:
		_target += _flat_rotated(move) * _distance * 0.8 * delta
	_yaw += turn * 1.5 * delta
	if Input.is_physical_key_pressed(KEY_PAGEUP) or Input.is_physical_key_pressed(KEY_EQUAL):
		_distance = clampf(_distance * (1.0 - 1.5 * delta), MIN_DISTANCE, MAX_DISTANCE)
	if Input.is_physical_key_pressed(KEY_PAGEDOWN) or Input.is_physical_key_pressed(KEY_MINUS):
		_distance = clampf(_distance * (1.0 + 1.5 * delta), MIN_DISTANCE, MAX_DISTANCE)


## A screen-space movement (x right, y down) as a horizontal world direction.
func _flat_rotated(v: Vector2) -> Vector3:
	var right := Vector3(cos(_yaw), 0, -sin(_yaw))
	var back := Vector3(sin(_yaw), 0, cos(_yaw))
	return right * v.x + back * v.y


func _gui_input(event: InputEvent) -> void:
	if not _ready_to_draw:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			grab_focus()
		if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_drag = mb.button_index if mb.pressed else 0
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.ctrl_pressed and mb.pressed:
				_drag = MOUSE_BUTTON_RIGHT
			accept_event()
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var factor := 1.0 / 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.15
			if view == View.FREE:
				_free_speed = clampf(_free_speed / factor, 2.0, 2000.0)
			else:
				_distance = clampf(_distance * factor, MIN_DISTANCE, MAX_DISTANCE)
			accept_event()
	elif event is InputEventMouseMotion and _drag != 0:
		var rel: Vector2 = (event as InputEventMouseMotion).relative
		var looking := _drag != MOUSE_BUTTON_LEFT or view == View.FREE
		if view == View.FREE:
			_free_yaw -= rel.x * 0.004
			_free_pitch = clampf(_free_pitch - rel.y * 0.004, -PI / 2 + 0.01, PI / 2 - 0.01)
		elif looking:
			_yaw -= rel.x * 0.005
			if view == View.PERSPECTIVE:
				_angle = clampf(_angle - rel.y * 0.005, 0.0, 1.5)
		else:
			var per_pixel := _distance / maxf(size.y, 1.0)
			if view == View.PERSPECTIVE:
				per_pixel = 2.0 * _distance * tan(deg_to_rad(FOV) / 2.0) / maxf(size.y, 1.0)
			_target -= _flat_rotated(Vector2(rel.x, rel.y)) * per_pixel
		accept_event()
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).physical_keycode
		if key in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_SPACE, KEY_SHIFT, KEY_PAGEUP, KEY_PAGEDOWN, KEY_EQUAL, KEY_MINUS]:
			accept_event()


# --- Tiles -------------------------------------------------------------------------------

## The tiles to show around [param center]; tiles well outside are unloaded.
func _update_wanted(center: Vector3) -> void:
	var wanted := {}
	var keep := {}
	var c := Vector2(center.x, center.z)
	var reach := minf(LOWRES_DISTANCE, maxf(1000.0, _distance * 3.0)) if view != View.FREE else LOWRES_DISTANCE
	var radius := maxi(1, floori(reach / _lowres_tile.x))
	for lod in range(1, _lod_count + 1):
		var scale := pow(_lod_factor, lod - 1)
		var tile := Vector2i(floori(c.x / (_lowres_tile.x * scale)), floori(c.y / (_lowres_tile.y * scale)))
		for x in range(tile.x - radius - 1, tile.x + radius + 2):
			for z in range(tile.y - radius - 1, tile.y + radius + 2):
				var path := BlueMap.tile_path(lod, x, z)
				keep[path] = true
				if absi(x - tile.x) <= radius and absi(z - tile.y) <= radius:
					wanted[path] = {"lod": lod, "key": Vector2i(x, z), "priority": Vector2(x - tile.x, z - tile.y).length() + lod * 0.5}
	var show_hires := view == View.FREE or _distance < (HIRES_MAX_DISTANCE if view == View.PERSPECTIVE else HIRES_MAX_DISTANCE * 0.8)
	if show_hires:
		var hires := Vector2i(floori((c.x - _hires_translate.x) / _hires_tile.x), floori((c.y - _hires_translate.y) / _hires_tile.y))
		var r := maxi(1, floori(DETAIL_DISTANCES[detail] / _hires_tile.x))
		for x in range(hires.x - r - 1, hires.x + r + 2):
			for z in range(hires.y - r - 1, hires.y + r + 2):
				var path := BlueMap.tile_path(0, x, z, _suffix)
				keep[path] = true
				var d := Vector2(x - hires.x, z - hires.y).length()
				if d <= r + 0.5:
					wanted[path] = {"lod": 0, "key": Vector2i(x, z), "priority": d * 0.3}
	_wanted = wanted
	for path in _tiles.keys():
		if not keep.has(path):
			_unload(path)
	var origin := Vector2i(floori((c.x - _hires_translate.x) / _hires_tile.x), floori((c.y - _hires_translate.y) / _hires_tile.y)) - Vector2i(MASK_SIZE / 2, MASK_SIZE / 2)
	if (origin - _mask_origin).length() > MASK_SIZE / 8.0:
		_mask_origin = origin
		_mask_dirty = true


func _unload(path: String) -> void:
	var t: Dictionary = _tiles[path]
	t.node.queue_free()
	_tiles.erase(path)
	if t.lod == 0:
		_mask_dirty = true


func _fetch_wanted() -> void:
	var todo := []
	for path in _wanted:
		if not _tiles.has(path) and not _missing.has(path) and not _in_flight.has(path):
			todo.append(path)
	if todo.is_empty() or _jobs.size() >= MAX_JOBS:
		return
	todo.sort_custom(func(a: String, b: String) -> bool: return _wanted[a].priority < _wanted[b].priority)
	todo = todo.slice(0, FETCH_BATCH)
	_load_tiles(todo.map(func(p: String) -> Dictionary: return {"path": p, "mtime": -1}))


## Fetches tiles and starts decoding them.
func _load_tiles(items: Array) -> void:
	_fetching = true
	var gen := _generation
	for item in items:
		_in_flight[item.path] = true
	var res := await _fetch(items)
	_fetching = false
	if gen != _generation:
		return
	for item in items:
		_in_flight.erase(item.path)
	if not res.has("error"):
		_load_files(res)


static func _tile_info(path: String) -> Dictionary:
	var m := RegEx.create_from_string("^tiles/(\\d+)/x(-?)([\\d/]+)z(-?)([\\d/]*\\d)\\.").search(path)
	if m == null:
		return {}
	var x := m.get_string(3).replace("/", "").to_int() * (-1 if m.get_string(2) == "-" else 1)
	var z := m.get_string(5).replace("/", "").to_int() * (-1 if m.get_string(4) == "-" else 1)
	return {"lod": m.get_string(1).to_int(), "key": Vector2i(x, z)}


func _finish_jobs() -> void:
	var done := 0
	var i := 0
	while i < _jobs.size() and done < FINALIZE_PER_FRAME:
		var job: Dictionary = _jobs[i]
		if not WorkerThreadPool.is_task_completed(job.task):
			i += 1
			continue
		WorkerThreadPool.wait_for_task_completion(job.task)
		_jobs.remove_at(i)
		if job.generation != _generation:
			continue
		var result: Dictionary = job.box.get("result", {})
		if not result.get("ok", false):
			_missing[job.path] = true
			continue
		var node := _make_hires(result.parts, job.key) if job.lod == 0 else _make_lowres(result.image, job.lod, job.key)
		if _tiles.has(job.path):
			_tiles[job.path].node.queue_free()
		_tile_root.add_child(node)
		_tiles[job.path] = {"node": node, "mtime": job.mtime, "lod": job.lod, "key": job.key, "image": result.get("image")}
		if job.lod == 0:
			_mask_dirty = true
		done += 1


static func _decode_hires(box: Dictionary, bytes: PackedByteArray, suffix: String, transparent: Dictionary, cutout: Dictionary) -> void:
	var tile := Prbm.parse(Prbm.decompress(bytes, suffix))
	if not tile.ok:
		box.result = tile
		return
	box.result = {"ok": true, "parts": Prbm.surfaces(tile, transparent, cutout)}


static func _decode_lowres(box: Dictionary, bytes: PackedByteArray) -> void:
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		box.result = {"ok": false}
		return
	img.convert(Image.FORMAT_RGBA8)
	box.result = {"ok": true, "image": img}


static func _decode_textures(box: Dictionary, bytes: PackedByteArray, suffix: String) -> void:
	box.result = Prbm.textures(Prbm.decompress(bytes, suffix))


func _make_hires(parts: Array, key: Vector2i) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	for i in parts.size():
		var s: Dictionary = parts[i]
		if s.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = s.vertices
		arrays[Mesh.ARRAY_TEX_UV] = s.uvs
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var m := ShaderMaterial.new()
		m.shader = HIRES_SHADER if i == 0 else HIRES_TRANSPARENT_SHADER
		m.set_shader_parameter("block_atlas", _textures)
		m.set_shader_parameter("atlas_columns", Prbm.ATLAS_COLUMNS)
		m.set_shader_parameter("texture_size", Prbm.TEXTURE_SIZE)
		m.set_shader_parameter("data_width", Prbm.DATA_WIDTH)
		for name in s.images:
			m.set_shader_parameter("data_" + name, ImageTexture.create_from_image(s.images[name]))
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(key.x * _hires_tile.x + _hires_translate.x, 0, key.y * _hires_tile.y + _hires_translate.y)
	mi.scale = Vector3(_hires_scale.x, 1, _hires_scale.y)
	return mi


var _grids := {}


func _make_lowres(image: Image, lod: int, key: Vector2i) -> MeshInstance3D:
	var scale := pow(_lod_factor, lod - 1)
	var m := ShaderMaterial.new()
	m.shader = LOWRES_SHADER
	m.set_shader_parameter("tile_texture", ImageTexture.create_from_image(image))
	m.set_shader_parameter("texture_size", Vector2(image.get_size()))
	m.set_shader_parameter("tile_size", _lowres_tile)
	m.set_shader_parameter("lod", float(lod))
	m.set_shader_parameter("lod_scale", scale)
	var mi := MeshInstance3D.new()
	mi.mesh = _grid(lod)
	mi.material_override = m
	mi.position = Vector3(key.x * _lowres_tile.x * scale, 0, key.y * _lowres_tile.y * scale)
	mi.scale = Vector3(scale, 1, scale)
	return mi


## The flat grid lowres tiles are drawn with (BlueMap's: coarser for farther levels).
func _grid(lod: int) -> PlaneMesh:
	if not _grids.has(lod):
		var segments := ceili(100.0 / (lod * 2))
		var plane := PlaneMesh.new()
		plane.size = _lowres_tile + Vector2.ONE
		plane.subdivide_width = segments - 1
		plane.subdivide_depth = segments - 1
		plane.center_offset = Vector3(_lowres_tile.x / 2.0 + 1.0, 0, _lowres_tile.y / 2.0 + 1.0)
		# The shader lifts the grid to the terrain's height.
		plane.custom_aabb = AABB(Vector3(0, -33000, 0), Vector3(_lowres_tile.x + 2.0, 66000, _lowres_tile.y + 2.0))
		_grids[lod] = plane
	return _grids[lod]


func _update_mask() -> void:
	_mask_dirty = false
	_mask_image.fill(Color.BLACK)
	for path in _tiles:
		var t: Dictionary = _tiles[path]
		if t.lod != 0:
			continue
		var p: Vector2i = t.key - _mask_origin
		if p.x >= 0 and p.y >= 0 and p.x < MASK_SIZE and p.y < MASK_SIZE:
			_mask_image.set_pixel(p.x, p.y, Color.WHITE)
	_mask_texture.update(_mask_image)
	_set_global("bm_hires_origin", Vector2(_mask_origin))


## The terrain height at a block position from the loaded level-1 tiles (NAN if unknown).
func _height_at(x: float, z: float) -> float:
	var key := Vector2i(floori(x / _lowres_tile.x), floori(z / _lowres_tile.y))
	var t: Dictionary = _tiles.get(BlueMap.tile_path(1, key.x, key.y), {})
	var img: Image = t.get("image")
	if img == null:
		return NAN
	var px := clampi(floori(x - key.x * _lowres_tile.x), 0, img.get_width() - 1)
	var pz := clampi(floori(z - key.y * _lowres_tile.y), 0, img.get_height() / 2 - 1)
	if img.get_pixel(px, pz).a == 0.0:
		return NAN
	var meta := img.get_pixel(px, pz + img.get_height() / 2)
	var h := roundi(meta.g * 255.0) * 256 + roundi(meta.b * 255.0)
	return float(h - 65535 if h >= 32768 else h)


## Reloads tiles BlueMap has rendered again, and loads ones that didn't exist before.
func _refresh() -> void:
	if _fetching or map_id == "":
		return
	var items := []
	for path in _tiles:
		items.append({"path": path, "mtime": _tiles[path].mtime})
	for path in _missing:
		if _wanted.has(path):
			items.append({"path": path, "mtime": -1})
	var gen := _generation
	for i in range(0, items.size(), 400):
		var chunk := items.slice(i, i + 400)
		var res := await _fetch(chunk)
		if gen != _generation or res.has("error"):
			return
		_load_files(res)


## Starts decoding fetched tiles; tiles that are gone are unloaded.
func _load_files(res: Dictionary) -> void:
	var gen := _generation
	for path in res.missing:
		if _tiles.has(path):
			_unload(path)
		_missing[path] = true
	for path in res.files:
		_missing.erase(path)
		var info := _tile_info(path)
		if info.is_empty():
			continue
		var box := {}
		var bytes: PackedByteArray = res.files[path].bytes
		var task: int
		if info.lod == 0:
			task = WorkerThreadPool.add_task(_decode_hires.bind(box, bytes, _suffix, _transparent, _cutout))
		else:
			task = WorkerThreadPool.add_task(_decode_lowres.bind(box, bytes))
		_jobs.append({"task": task, "box": box, "path": path, "lod": info.lod, "key": info.key, "mtime": res.files[path].mtime, "generation": gen})


## {files: {path: {bytes, mtime}}, missing: [paths]} or {error}.
func _fetch(items: Array) -> Dictionary:
	var out := {"files": {}, "missing": []}
	var pending := items
	while not pending.is_empty() and handle != null:
		var res: Dictionary = await handle.call_op("bluemap_files", {"map": map_id, "items": pending})
		if not res.ok:
			return {"error": str(res.get("error", "failed"))}
		for path in res.files:
			out.files[path] = {"bytes": Marshalls.base64_to_raw(res.files[path].data), "mtime": int(res.files[path].mtime)}
		out.missing.append_array(res.missing)
		var more: Array = res.get("more", [])
		pending = pending.filter(func(i: Dictionary) -> bool: return more.has(i.path))
	return out


# --- Players and markers ------------------------------------------------------------------

func _poll_live() -> void:
	if handle == null or map_id == "":
		return
	_live_busy = true
	var gen := _generation
	var res: Dictionary = await handle.call_op("bluemap_live", {"map": map_id, "markers_mtime": _markers_mtime})
	_live_busy = false
	if gen != _generation or not res.ok:
		return
	_players = (res.players as Array).filter(func(p: Variant) -> bool: return p is Dictionary and not bool(p.get("foreign", false)))
	_fill_players()
	if res.has("markers"):
		_markers_mtime = int(res.markers_mtime)
		_build_markers(res.markers)


func _fill_players() -> void:
	if _players_box == null:
		return
	for child in _players_box.get_children():
		child.queue_free()
	_players_panel.visible = not _players.is_empty()
	for p in _players:
		var b := Button.new()
		b.flat = true
		b.text = str(p.get("name", "?"))
		b.tooltip_text = "Go to %s" % b.text
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var pos := _vec3(p.get("position"))
		b.pressed.connect(func() -> void:
			if view == View.FREE:
				_free_position = pos + Vector3(0, 20, 30)
			else:
				_target = pos
				_distance = minf(_distance, 150.0))
		_players_box.add_child(b)
	var seen := {}
	for p in _players:
		var id := "player:" + str(p.get("uuid", ""))
		seen[id] = true
		var item: Control = _overlay_items.get(id)
		if item == null:
			item = _overlay_label(str(p.get("name", "?")), true)
			_overlay_items[id] = item
			_load_head(str(p.get("uuid", "")), item)
		item.set_meta("position", _vec3(p.get("position")) + Vector3(0, 2.0, 0))
	for id in _overlay_items.keys():
		if str(id).begins_with("player:") and not seen.has(id):
			_overlay_items[id].queue_free()
			_overlay_items.erase(id)


func _load_head(uuid: String, item: Control) -> void:
	if not RegEx.create_from_string("^[0-9a-fA-F\\-]{32,36}$").search(uuid):
		return
	if not _heads.has(uuid):
		var path := "assets/playerheads/%s.png" % uuid
		var res := await _fetch([{"path": path, "mtime": -1}])
		var tex: Texture2D = null
		if res.has("files") and res.files.has(path):
			var img := Image.new()
			if img.load_png_from_buffer(res.files[path].bytes) == OK:
				img.resize(16, 16, Image.INTERPOLATE_NEAREST)
				tex = ImageTexture.create_from_image(img)
		_heads[uuid] = tex
	if is_instance_valid(item) and _heads[uuid] != null:
		var icon := item.get_node_or_null("Box/Head") as TextureRect
		if icon != null:
			icon.texture = _heads[uuid]
			icon.visible = true


static func _vec3(v: Variant) -> Vector3:
	if v is Dictionary:
		return Vector3(float(v.get("x", 0)), float(v.get("y", 0)), float(v.get("z", 0)))
	return Vector3.ZERO


## Label (and head) shown over a spot of the map.
func _overlay_label(text: String, player: bool) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"ToastPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := HBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 4)
	var head := TextureRect.new()
	head.name = "Head"
	head.visible = false
	head.custom_minimum_size = Vector2(16, 16)
	head.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	box.add_child(head)
	box.add_child(label)
	panel.add_child(box)
	panel.set_meta("player", player)
	_overlay.add_child(panel)
	return panel


## Markers of BlueMap's marker sets: POI and HTML markers as labels, lines and shapes as
## outlines.
func _build_markers(sets: Dictionary) -> void:
	for child in _marker_root.get_children():
		child.queue_free()
	for id in _overlay_items.keys():
		if str(id).begins_with("marker:"):
			_overlay_items[id].queue_free()
			_overlay_items.erase(id)
	var lines := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var any_line := false
	for set_id in sets:
		var s: Variant = sets[set_id]
		if not s is Dictionary or bool(s.get("defaultHidden", false)):
			continue
		var markers: Dictionary = s.get("markers", {}) if s.get("markers") is Dictionary else {}
		for marker_id in markers:
			var m: Variant = markers[marker_id]
			if not m is Dictionary:
				continue
			var type := str(m.get("type", ""))
			var label := _strip_html(str(m.get("label", marker_id)))
			if type in ["poi", "html"]:
				var item := _overlay_label(label, false)
				item.set_meta("position", _vec3(m.get("position")))
				item.set_meta("max_distance", float(m.get("maxDistance", 1e7)))
				_overlay_items["marker:%s/%s" % [set_id, marker_id]] = item
			elif type in ["line", "shape", "extrude"]:
				var color := _marker_color(m.get("lineColor"), Color(1, 0.3, 0.3, 1))
				var points := []
				if type == "line":
					for p in m.get("line", []):
						points.append(_vec3(p))
				else:
					var y := float(m.get("shapeY", m.get("shapeMinY", 64)))
					for p in m.get("shape", []):
						points.append(Vector3(float(p.get("x", 0)), y, float(p.get("z", 0))) if p is Dictionary else Vector3.ZERO)
					if not points.is_empty():
						points.append(points[0])
				if points.size() < 2:
					continue
				if not any_line:
					lines.surface_begin(Mesh.PRIMITIVE_LINES, material)
					any_line = true
				for i in points.size() - 1:
					lines.surface_set_color(color)
					lines.surface_add_vertex(points[i])
					lines.surface_set_color(color)
					lines.surface_add_vertex(points[i + 1])
				if type == "extrude":
					var top: float = float(m.get("shapeMaxY", 64)) - points[0].y
					for i in points.size() - 1:
						for pair in [[points[i], points[i + 1]], [points[i], points[i]]]:
							lines.surface_set_color(color)
							lines.surface_add_vertex(pair[0] + Vector3(0, top, 0))
							lines.surface_set_color(color)
							lines.surface_add_vertex(pair[1] + (Vector3(0, top, 0) if pair[0] != pair[1] else Vector3.ZERO))
				if label != "" and bool(m.get("type", "") != "line"):
					var item := _overlay_label(label, false)
					var center := Vector3.ZERO
					for p in points:
						center += p
					item.set_meta("position", center / points.size())
					item.set_meta("max_distance", float(m.get("maxDistance", 1e7)))
					_overlay_items["marker:%s/%s" % [set_id, marker_id]] = item
	if any_line:
		lines.surface_end()
		var mi := MeshInstance3D.new()
		mi.mesh = lines
		_marker_root.add_child(mi)


static func _marker_color(v: Variant, default: Color) -> Color:
	if v is Dictionary:
		return Color(float(v.get("r", 255)) / 255.0, float(v.get("g", 0)) / 255.0, float(v.get("b", 0)) / 255.0, float(v.get("a", 1.0)))
	return default


static func _strip_html(text: String) -> String:
	return RegEx.create_from_string("<[^>]*>").sub(text, "", true).strip_edges()


func _place_overlay() -> void:
	var cam := _camera.global_position
	for item: Control in _overlay_items.values():
		var pos: Vector3 = item.get_meta("position", Vector3.ZERO)
		var far: bool = cam.distance_to(pos) > float(item.get_meta("max_distance", 1e7))
		if _camera.is_position_behind(pos) or far:
			item.visible = false
			continue
		var p := _camera.unproject_position(pos)
		var inside := Rect2(Vector2.ZERO, size).has_point(p)
		item.visible = inside
		var at := (p - Vector2(item.size.x / 2.0, item.size.y)).round()
		if inside and item.position != at:
			item.position = at


# --- Messages ------------------------------------------------------------------------------

func _set_global(name: String, value: Variant) -> void:
	if _globals.get(name) != value or value is Texture2D:
		_globals[name] = value
		RenderingServer.global_shader_parameter_set(name, value)


## Says so when nothing around is rendered (every wanted tile is missing).
func _check_empty(loading: int) -> void:
	var nothing := loading == 0 and _tiles.is_empty() and not _wanted.is_empty() and not _fetching \
			and _wanted.keys().all(func(p: String) -> bool: return _missing.has(p))
	if nothing and not _empty_label.visible:
		_show_empty("Nothing is rendered here yet. BlueMap renders chunks once they are fully generated: when players have been there, or after Chunky has generated or loaded them.")
	elif not nothing and _empty_label.visible and _ready_to_draw:
		_show_empty("")

func _set_info(text: String) -> void:
	if _info_label.text != text:
		_info_label.text = text
		_info_label.visible = text != ""
		info_changed.emit(text)


func _show_empty(text: String) -> void:
	_empty_label.text = text
	_empty_label.visible = text != ""
	if text != "":
		_set_info("")


func _exit_tree() -> void:
	for job in _jobs:
		WorkerThreadPool.wait_for_task_completion(job.task)
	_jobs.clear()
