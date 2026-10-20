extends SceneTree
## Renders icon.svg into the files packages need: a multi-size Windows .ico and PNGs,
## including the phone app icons (iOS and Android).
## godot --headless --path . -s packaging/make_icons.gd -- <output dir>

const ICO_SIZES: Array[int] = [16, 24, 32, 48, 64, 128, 256]
## Background of the icon's tile in icon.svg, and the share of the 64 px canvas it covers.
const TILE_COLOR := Color("1d222b")
const TILE_SHARE := 56.0 / 64.0


func _init() -> void:
	var out_dir := OS.get_cmdline_user_args()[0] if not OS.get_cmdline_user_args().is_empty() else "packaging/build"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var svg := FileAccess.get_file_as_bytes("res://icon.svg")
	var pngs: Array[PackedByteArray] = []
	for size in ICO_SIZES:
		pngs.append(_render(svg, size).save_png_to_buffer())
	_render(svg, 256).save_png(out_dir.path_join("server-manager-256.png"))
	_app_icon(svg, 1024).save_png(out_dir.path_join("app-icon-1024.png"))
	_app_icon(svg, 192).save_png(out_dir.path_join("app-icon-192.png"))
	# Android adaptive icon: the launcher masks it to a shape and shows the middle 66 %.
	var background := Image.create(432, 432, false, Image.FORMAT_RGB8)
	background.fill(TILE_COLOR)
	background.save_png(out_dir.path_join("app-icon-background-432.png"))
	var glyph := _app_icon(svg, 288)
	glyph.convert(Image.FORMAT_RGBA8)
	var foreground := Image.create(432, 432, false, Image.FORMAT_RGBA8)
	foreground.blit_rect(glyph, Rect2i(0, 0, 288, 288), Vector2i(72, 72))
	foreground.save_png(out_dir.path_join("app-icon-foreground-432.png"))
	var f := FileAccess.open(out_dir.path_join("server-manager.ico"), FileAccess.WRITE)
	f.store_buffer(ico(ICO_SIZES, pngs))
	f.close()
	print("Icons written to %s" % out_dir)
	quit()


func _render(svg: PackedByteArray, size: int) -> Image:
	var probe := Image.new()
	probe.load_svg_from_buffer(svg, 1.0)
	var img := Image.new()
	img.load_svg_from_buffer(svg, float(size) / maxf(probe.get_width(), 1.0))
	img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != size or img.get_height() != size:
		img.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return img


## Phone app icon: opaque, with the tile filling the square (the phone rounds the corners).
func _app_icon(svg: PackedByteArray, size: int) -> Image:
	var big := _render(svg, roundi(size / TILE_SHARE))
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(TILE_COLOR)
	var offset := (big.get_width() - size) / 2
	img.blend_rect(big, Rect2i(offset, offset, size, size), Vector2i.ZERO)
	img.convert(Image.FORMAT_RGB8)
	return img


## An .ico holding PNG images (supported since Windows Vista).
static func ico(sizes: Array[int], pngs: Array[PackedByteArray]) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(6)
	out.encode_u16(0, 0)
	out.encode_u16(2, 1)
	out.encode_u16(4, sizes.size())
	var offset := 6 + 16 * sizes.size()
	for i in sizes.size():
		var entry := PackedByteArray()
		entry.resize(16)
		entry[0] = sizes[i] % 256
		entry[1] = sizes[i] % 256
		entry.encode_u16(4, 1)
		entry.encode_u16(6, 32)
		entry.encode_u32(8, pngs[i].size())
		entry.encode_u32(12, offset)
		out.append_array(entry)
		offset += pngs[i].size()
	for png in pngs:
		out.append_array(png)
	return out
