class_name IconEditorDialog
extends ConfirmationDialog
## Choose, crop and save a server's 64×64 server-list icon. Any common image format
## works (unsupported ones are converted with an installed tool). The crop is edited
## on a downscaled copy and applied to the full image on a worker thread.

## Pending mode (server not created yet): the chosen icon, or null when cleared.
signal icon_ready(icon: Image)
signal icon_saved

const ACTION_REMOVE := "remove"
const DIALOG_SIZE := Vector2i(940, 640)
const MOTD_COLOR := "#aaaaaa"

var _instance: ServerInstance
var _pending := false
var _display_name := ""
var _full: Image
var _preview: Image
var _preview_factor := 1.0
var _busy := false
var _remove_button: Button

@onready var _choose_button: Button = %ChooseButton
@onready var _source_label: Label = %SourceLabel
@onready var _cropper: IconCropper = %Cropper
@onready var _empty_label: Label = %EmptyLabel
@onready var _preview_1x: TextureRect = %Preview1x
@onready var _preview_2x: TextureRect = %Preview2x
@onready var _mock_icon: TextureRect = %MockIcon
@onready var _mock_name: Label = %MockName
@onready var _mock_motd: RichTextLabel = %MockMotd
@onready var _mock_players: Label = %MockPlayers
@onready var _fill_button: Button = %FillButton
@onready var _fit_button: Button = %FitButton
@onready var _pixel_art_check: CheckButton = %PixelArtCheck
@onready var _status: Label = %StatusLabel
@onready var _file_dialog: FileDialog = %FileDialog


func _ready() -> void:
	_remove_button = add_button("Remove icon", false, ACTION_REMOVE)
	_remove_button.theme_type_variation = &"DangerButton"
	_remove_button.tooltip_text = "Delete server-icon.png; the server list shows the default icon."
	get_ok_button().theme_type_variation = &"AccentButton"
	confirmed.connect(_on_save)
	custom_action.connect(func(action: StringName) -> void:
		if action == ACTION_REMOVE:
			_on_remove())
	_choose_button.pressed.connect(func() -> void: _file_dialog.popup_centered())
	_file_dialog.filters = ServerIcon.FILE_FILTERS
	_file_dialog.file_selected.connect(load_file)
	_cropper.crop_changed.connect(func(_c: Rect2) -> void: _update_preview())
	_fill_button.pressed.connect(func() -> void: _cropper.fill())
	_fit_button.pressed.connect(func() -> void: _cropper.fit())
	_pixel_art_check.toggled.connect(func(_on: bool) -> void: _update_preview())
	visibility_changed.connect(_on_visibility_changed)


## Edits the icon of an existing server.
func open(inst: ServerInstance) -> void:
	_instance = inst
	_pending = false
	_display_name = inst.config.display_name
	_reset(inst.get_properties().get_value("motd", "A Minecraft Server"), inst.get_properties().get_int("max-players", 20))
	title = "Server icon — %s" % _display_name
	_remove_button.text = "Remove icon"
	_remove_button.visible = ServerIcon.info(inst.config.directory).exists
	var info := ServerIcon.info(inst.config.directory)
	if info.exists and not info.valid:
		_set_status("The current server-icon.png is %d×%d. Minecraft only shows 64×64 icons, so it's being ignored. Choose an image to replace it." % [info.size.x, info.size.y], true)
	elif info.exists:
		_show_current(ServerIcon.load_texture(inst.config.directory))
	popup_centered(DIALOG_SIZE)


## Picks an icon for a server that doesn't exist yet; emits [signal icon_ready].
func open_pending(display_name: String, motd := "A Minecraft Server", current: Image = null) -> void:
	_instance = null
	_pending = true
	_display_name = display_name
	_reset(motd, 20)
	title = "Server icon"
	_remove_button.text = "No icon"
	_remove_button.visible = current != null
	if current != null:
		_show_current(ImageTexture.create_from_image(current))
	popup_centered(DIALOG_SIZE)


## Loads an image file (from the picker or a drop) into the cropper.
func load_file(path: String) -> void:
	if _busy:
		return
	_busy = true
	_set_controls_enabled(false)
	_set_status("Loading %s…" % path.get_file())
	var temp_dir := ProjectSettings.globalize_path("user://cache/icon-convert")
	var res: Dictionary = await FileOps.run_async(self, func() -> Dictionary:
		var r := ServerIcon.load_image(path, temp_dir)
		if r.ok:
			# A smaller working copy keeps dragging and live previews fast for huge images.
			var copy := ServerIcon.preview_copy(r.image)
			r.preview = copy.image
			r.factor = copy.factor
		return r)
	_busy = false
	if not res.ok:
		_set_controls_enabled(true)
		_set_status(res.error, true)
		return
	_full = res.image
	_preview = res.preview
	_preview_factor = res.factor
	_cropper.set_image(ImageTexture.create_from_image(_preview), _full.get_size(), ServerIcon.fill_crop(_full.get_size()))
	_empty_label.visible = false
	_pixel_art_check.button_pressed = maxi(_full.get_width(), _full.get_height()) <= 128 and res.format in ["png", "gif", "bmp"]
	var converted: String = res.get("converted_with", "")
	_source_label.text = "%s — %d×%d %s%s" % [path.get_file(), _full.get_width(), _full.get_height(), str(res.format).to_upper(),
			" (converted with %s)" % converted if converted != "" else ""]
	_set_controls_enabled(true)
	_set_status("Drag to move, drag a corner to resize, scroll to zoom, arrow keys to nudge.")
	_update_preview()


func _reset(motd: String, max_players: int) -> void:
	_full = null
	_preview = null
	_cropper.clear()
	_empty_label.visible = true
	_source_label.text = "No image chosen"
	_pixel_art_check.button_pressed = false
	_mock_name.text = _display_name
	_mock_motd.text = Ansi.to_bbcode(motd, MOTD_COLOR)
	_mock_players.text = "0/%d" % max_players
	_set_preview_texture(null)
	_set_status("Choose an image, or drop one here. It will be cropped to a square and saved as a 64×64 PNG.")
	get_ok_button().disabled = true
	_set_controls_enabled(true)


func _show_current(texture: Texture2D) -> void:
	_set_preview_texture(texture)
	_source_label.text = "Current icon"


func _update_preview() -> void:
	if _preview == null:
		return
	var crop := _cropper.crop
	var preview_crop := Rect2(crop.position / _preview_factor, crop.size / _preview_factor)
	var icon := ServerIcon.render(_preview, preview_crop, _pixel_art_check.button_pressed)
	_set_preview_texture(ImageTexture.create_from_image(icon))
	get_ok_button().disabled = _busy


func _set_preview_texture(tex: Texture2D) -> void:
	_preview_1x.texture = tex
	_preview_2x.texture = tex
	_mock_icon.texture = tex


func _on_save() -> void:
	if _busy or _full == null:
		return
	_busy = true
	_set_controls_enabled(false)
	_set_status("Saving…")
	var full := _full
	var crop := _cropper.crop
	var pixel_art := _pixel_art_check.button_pressed
	var icon: Image = await FileOps.run_async(self, func() -> Image: return ServerIcon.render(full, crop, pixel_art))
	_busy = false
	_set_controls_enabled(true)
	if _pending:
		icon_ready.emit(icon)
		hide()
		return
	var err := ServerIcon.save(_instance.config.directory, icon)
	if err != OK:
		_set_status("Could not save the icon: %s" % error_string(err), true)
		return
	_instance.config_changed.emit()
	var note := " Restart the server to show it in the server list." if _instance.is_process_alive() else ""
	Notifier.success("Saved the icon for %s.%s" % [_instance.config.display_name, note])
	icon_saved.emit()
	hide()


func _on_remove() -> void:
	if _pending:
		icon_ready.emit(null)
		hide()
		return
	var err := ServerIcon.remove(_instance.config.directory)
	if err != OK:
		_set_status("Could not remove the icon: %s" % error_string(err), true)
		return
	_instance.config_changed.emit()
	Notifier.info("Removed the icon of %s." % _instance.config.display_name)
	icon_saved.emit()
	hide()


func _set_controls_enabled(enabled: bool) -> void:
	_choose_button.disabled = not enabled
	_fill_button.disabled = not enabled or _full == null
	_fit_button.disabled = not enabled or _full == null
	_pixel_art_check.disabled = not enabled or _full == null
	get_ok_button().disabled = not enabled or _full == null
	_remove_button.disabled = not enabled


func _set_status(text: String, is_error := false) -> void:
	_status.text = text
	if is_error:
		_status.add_theme_color_override("font_color", Color("e05555"))
	else:
		_status.remove_theme_color_override("font_color")


## Embedded dialogs don't receive OS drops themselves; listen on the main window while open.
func _on_visibility_changed() -> void:
	var root := get_tree().root
	if visible and not root.files_dropped.is_connected(_on_files_dropped):
		root.files_dropped.connect(_on_files_dropped)
	elif not visible and root.files_dropped.is_connected(_on_files_dropped):
		root.files_dropped.disconnect(_on_files_dropped)


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if FileAccess.file_exists(f):
			load_file(f)
			return
