extends SceneTree
## Renders icon.svg into the files packages need: a multi-size Windows .ico and PNGs.
## godot --headless --path . -s packaging/make_icons.gd -- <output dir>

const ICO_SIZES: Array[int] = [16, 24, 32, 48, 64, 128, 256]


func _init() -> void:
	var out_dir := OS.get_cmdline_user_args()[0] if not OS.get_cmdline_user_args().is_empty() else "packaging/build"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var svg := FileAccess.get_file_as_bytes("res://icon.svg")
	var pngs: Array[PackedByteArray] = []
	for size in ICO_SIZES:
		pngs.append(_render(svg, size).save_png_to_buffer())
	_render(svg, 256).save_png(out_dir.path_join("server-manager-256.png"))
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
