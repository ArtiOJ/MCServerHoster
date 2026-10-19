extends Node
## Server icon end to end: large photo-like JPEG and an animated GIF (converted with an
## installed tool, if any) go through the real icon editor dialog; the saved icon must
## reach players: a real Paper server's status reply carries a 64×64 PNG favicon.
## Usage: godot --headless --path . res://tests/integration/server_icon_test.tscn -- --no-autostart --profile=ict --root=<dir>

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://icon-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var media := root.path_join("_media")
	DirAccess.make_dir_recursive_absolute(media)

	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Icon Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4", "motd": "§aIcon §btest"},
	})
	var inst: ServerInstance = created.instance

	# A large photo-like JPEG (gradient with detail) through the real dialog.
	var big := Image.create(8000, 6000, false, Image.FORMAT_RGB8)
	for y in 60:
		for x in 80:
			big.fill_rect(Rect2i(x * 100, y * 100, 100, 100), Color(x / 80.0, y / 60.0, 0.5 + 0.5 * sin(x * 0.3)))
	var jpg := media.path_join("photo.jpg")
	big.save_jpg(jpg, 0.9)
	var dialog: IconEditorDialog = load("res://scenes/dialogs/icon_editor_dialog.tscn").instantiate()
	add_child(dialog)
	dialog.open(inst)
	var t0 := Time.get_ticks_msec()
	await dialog.load_file(jpg)
	_check(dialog._full != null and dialog._full.get_size() == Vector2i(8000, 6000), "8000x6000 JPEG loaded in %d ms" % (Time.get_ticks_msec() - t0))
	_check(dialog._preview.get_width() <= 1600, "cropper works on a downscaled copy (%dx%d)" % [dialog._preview.get_width(), dialog._preview.get_height()])
	_check(dialog._preview_1x.texture != null and dialog._preview_1x.texture.get_width() == 64, "live 64x64 preview")
	dialog._cropper.set_crop(Rect2(1000, 1000, 3000, 3000))
	t0 = Time.get_ticks_msec()
	await dialog._on_save()
	var info := ServerIcon.info(inst.config.directory)
	_check(info.valid, "saved a valid 64x64 server-icon.png from the JPEG (%d ms)" % (Time.get_ticks_msec() - t0))

	# An animated GIF needs an external converter.
	var magick := PlatformBackend.find_in_path("magick")
	if magick != "":
		var gif := media.path_join("anim.gif")
		var code := OS.execute(magick, ["-size", "120x90", "xc:red", "-size", "120x90", "xc:blue", "-delay", "20", gif])
		_check(code == 0 and FileAccess.file_exists(gif), "made an animated GIF fixture with magick")
		var res := ServerIcon.load_image(gif)
		_check(res.ok and res.get("converted_with", "") != "", "GIF converted with %s" % res.get("converted_with", "nothing"))
		if res.ok:
			var px := (res.image as Image).get_pixel(10, 10)
			_check(px.r > 0.9 and px.b < 0.1, "first frame used (red, not blue)")
		dialog.open(inst)
		await dialog.load_file(gif)
		_check(dialog._source_label.text.contains("converted with"), "dialog shows the conversion: " + dialog._source_label.text)
		dialog._cropper.fit()
		await dialog._on_save()
		var icon := Image.new()
		icon.load_png_from_buffer(FileAccess.get_file_as_bytes(ServerIcon.icon_path(inst.config.directory)))
		_check(icon.get_size() == Vector2i(64, 64) and icon.get_pixel(32, 2).a == 0.0, "4:3 GIF fitted with transparent padding")
	else:
		print("SKIP no ImageMagick: GIF conversion not tested")

	# The real server serves it.
	inst.start()
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	var status: Dictionary = await _status(inst.config.port)
	var fav: String = status.get("favicon", "")
	_check(fav.begins_with("data:image/png;base64,"), "status reply carries a PNG favicon")
	if fav != "":
		var png := Image.new()
		png.load_png_from_buffer(Marshalls.base64_to_raw(fav.get_slice(",", 1)))
		_check(png.get_size() == Vector2i(64, 64), "favicon decodes to 64x64")
	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)
	_check(dialog.visible == false, "dialog closed after saving")
	dialog.queue_free()
	ServerManager.delete_server(inst.config.id, true, true)
	FileOps.remove_tree(media)
	print("\nIcon test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _status(port: int) -> Dictionary:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", port)
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		await get_tree().process_frame
	peer.put_data(McProtocol.handshake(774, "localhost", port, McProtocol.STATE_STATUS))
	peer.put_data(McProtocol.packet(0x00))
	var buf := PackedByteArray()
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			buf.append_array(peer.get_partial_data(n)[1])
			var pkt := McProtocol.take_packet(buf)
			if not pkt.is_empty() and not pkt.has("error"):
				peer.disconnect_from_host()
				var parsed = JSON.parse_string(McProtocol.read_string(pkt.payload, 0)[0])
				return parsed if parsed is Dictionary else {}
		await get_tree().process_frame
	return {}


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
