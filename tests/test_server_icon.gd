extends TestCase

const SVG := "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\" viewBox=\"0 0 20 10\"><rect width=\"20\" height=\"10\" fill=\"#ff0000\"/></svg>"


func _dir() -> String:
	var d := ProjectSettings.globalize_path("user://test-icon-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(d)
	return d


func test_crop_math() -> void:
	check_eq(ServerIcon.fill_crop(Vector2i(200, 100)), Rect2(50, 0, 100, 100), "fill: centred square inside")
	check_eq(ServerIcon.fit_crop(Vector2i(200, 100)), Rect2(0, -50, 200, 200), "fit: square containing all")
	check_eq(ServerIcon.clamp_crop(Rect2(180, 10, 50, 50), Vector2i(200, 100)), Rect2(150, 10, 50, 50), "pushed back inside")
	var big := ServerIcon.clamp_crop(Rect2(-5, 0, 500, 500), Vector2i(200, 100))
	check_eq(big.size, Vector2(200, 200), "never larger than the fit square")
	check(big.position.y <= 0.0 and big.position.y >= -100.0, "padding axis keeps the image inside")
	check_eq(ServerIcon.clamp_crop(Rect2(10, 10, 0.2, 0.2), Vector2i(200, 100), 8.0).size, Vector2(8, 8), "minimum side")


func test_render_size_alpha_and_padding() -> void:
	var img := Image.create(1000, 500, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 1, 1))
	img.fill_rect(Rect2i(0, 0, 500, 500), Color(1, 0, 0, 0.5))
	var filled := ServerIcon.render(img, ServerIcon.fill_crop(img.get_size()))
	check_eq(filled.get_size(), Vector2i(64, 64), "64x64")
	check(filled.detect_alpha() != Image.ALPHA_NONE, "alpha kept")
	var half := filled.get_pixel(5, 32)
	check(absf(half.a - 0.5) < 0.05 and half.r > 0.9 and half.b < 0.1, "semi-transparent red stays red (no dark fringe): %s" % half)
	var fitted := ServerIcon.render(img, ServerIcon.fit_crop(img.get_size()))
	check_eq(fitted.get_pixel(32, 2).a, 0.0, "fit pads with transparency above")
	check(fitted.get_pixel(48, 32).b > 0.9, "image visible in the middle")


func test_small_source_and_pixel_art() -> void:
	var tiny := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	tiny.fill(Color(1, 1, 1, 1))
	tiny.set_pixel(0, 0, Color(0, 0, 0, 1))
	var crisp := ServerIcon.render(tiny, Rect2(0, 0, 16, 16), true)
	check_eq(crisp.get_size(), Vector2i(64, 64), "upscaled to 64")
	check_eq(crisp.get_pixel(3, 3), Color(0, 0, 0, 1), "pixel art keeps hard 4x4 blocks")
	check_eq(crisp.get_pixel(4, 4), Color(1, 1, 1, 1), "next block untouched")


func test_magic_bytes() -> void:
	check_eq(ServerIcon.detect_format(PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0, 0])), "png", "png")
	check_eq(ServerIcon.detect_format(PackedByteArray([0xFF, 0xD8, 0xFF, 0xE0])), "jpeg", "jpeg")
	check_eq(ServerIcon.detect_format("GIF89a....".to_ascii_buffer()), "gif", "gif")
	check_eq(ServerIcon.detect_format("RIFF\u0000\u0000\u0000\u0000WEBPVP8 ".to_ascii_buffer()), "webp", "webp")
	check_eq(ServerIcon.detect_format("\u0000\u0000\u0000\u001cftypavif".to_ascii_buffer()), "avif", "avif")
	check_eq(ServerIcon.detect_format("\u0000\u0000\u0000\u0018ftypheic".to_ascii_buffer()), "heic", "heic")
	check_eq(ServerIcon.detect_format(PackedByteArray([0, 0, 1, 0, 1, 0])), "ico", "ico")
	check_eq(ServerIcon.detect_format(PackedByteArray([0x49, 0x49, 0x2A, 0x00, 8, 0])), "tiff", "tiff")
	check_eq(ServerIcon.detect_format(SVG.to_utf8_buffer()), "svg", "svg by content")
	check_eq(ServerIcon.detect_format(PackedByteArray([1, 2, 3]), "x.tga"), "tga", "tga by extension")
	# A PNG named .jpg is still a PNG.
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	check_eq(ServerIcon.detect_format(img.save_png_to_buffer(), "photo.jpg"), "png", "content beats extension")


func test_svg_rasterized_large() -> void:
	var dir := _dir()
	var path := dir.path_join("logo.svg")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(SVG)
	f.close()
	var res := ServerIcon.load_image(path)
	check(res.ok, "svg loads: %s" % res.get("error", ""))
	if res.ok:
		check_eq((res.image as Image).get_width(), ServerIcon.SVG_RASTER_SIZE, "svg rasterized to the working size")
	FileOps.remove_tree(dir)


func test_save_info_remove_round_trip() -> void:
	var dir := _dir()
	var icon := ServerIcon.render(Image.create(300, 300, false, Image.FORMAT_RGBA8), Rect2(0, 0, 300, 300))
	check_eq(ServerIcon.save(dir, icon), OK, "save")
	var i := ServerIcon.info(dir)
	check(i.exists and i.valid and i.size == Vector2i(64, 64), "valid 64x64 icon")
	check(ServerIcon.load_texture(dir) != null, "texture loads")
	check_eq(ServerIcon.save(dir, Image.create(10, 10, false, Image.FORMAT_RGBA8)), ERR_INVALID_PARAMETER, "wrong size refused")
	var wrong := Image.create(100, 80, false, Image.FORMAT_RGBA8)
	wrong.save_png(ServerIcon.icon_path(dir))
	check(not ServerIcon.info(dir).valid, "a 100x80 file is reported invalid (Paper ignores it)")
	check_eq(ServerIcon.remove(dir), OK, "remove")
	check(not ServerIcon.info(dir).exists and ServerIcon.load_texture(dir) == null, "gone")
	FileOps.remove_tree(dir)


func test_converter_args() -> void:
	check_eq(ServerIcon.converter_args("magick", "/a/b.gif", "/t/o.png"), PackedStringArray(["/a/b.gif[0]", "-auto-orient", "png32:/t/o.png"]), "magick first frame")
	check_eq(ServerIcon.converter_args("ffmpeg", "a.avif", "o.png"), PackedStringArray(["-y", "-loglevel", "error", "-i", "a.avif", "-frames:v", "1", "o.png"]), "ffmpeg single frame")
	check_eq(ServerIcon.converter_args("heif-convert", "a.heic", "o.png"), PackedStringArray(["a.heic", "o.png"]), "heif-convert")
	check_eq(ServerIcon.converter_args("unknown", "a", "b").size(), 0, "unknown tool")
