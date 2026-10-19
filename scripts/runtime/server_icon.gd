class_name ServerIcon
extends RefCounted
## The server-list icon: Minecraft reads `server-icon.png` from the server folder at
## startup and only accepts a 64×64 PNG (anything else is logged as "Couldn't load
## server icon" and ignored). This class loads images in many formats (converting
## unsupported ones with an installed tool), crops, downscales with good quality
## and saves the icon atomically.

const FILE_NAME := "server-icon.png"
const SIZE := 64
## SVGs are rasterized so their longer side has this many pixels before cropping.
const SVG_RASTER_SIZE := 1024
## Formats Godot decodes itself.
const NATIVE_FORMATS: PackedStringArray = ["png", "jpeg", "webp", "svg", "bmp", "tga"]
## Formats that need an external converter.
const CONVERTIBLE_FORMATS: PackedStringArray = ["gif", "avif", "heic", "ico", "tiff", "jxl", "psd"]
## Converters in order of preference; format-specific ones are tried after the generic ones.
const GENERIC_CONVERTERS: PackedStringArray = ["magick", "convert", "vips", "ffmpeg"]
const SPECIFIC_CONVERTERS := {"heic": ["heif-convert"], "avif": ["avifdec", "heif-convert"], "jxl": ["djxl"]}
## File-dialog filters for every format the editor can open.
const FILE_FILTERS: PackedStringArray = [
	"*.png, *.jpg, *.jpeg, *.webp, *.svg, *.bmp, *.tga, *.gif, *.avif, *.heic, *.heif, *.ico, *.tif, *.tiff, *.jxl, *.psd ; Images",
]

## path -> {"mtime": int, "texture": Texture2D}
static var _texture_cache := {}


static func icon_path(dir: String) -> String:
	return dir.path_join(FILE_NAME)


# --- Format detection & loading ---------------------------------------------------

## Real format from the file's first bytes ("" if unknown). The extension is only a
## fallback for TGA, which has no signature.
static func detect_format(bytes: PackedByteArray, path := "") -> String:
	if _starts_with(bytes, [0x89, 0x50, 0x4E, 0x47]):
		return "png"
	if _starts_with(bytes, [0xFF, 0xD8, 0xFF]):
		return "jpeg"
	if _starts_with(bytes, [0x47, 0x49, 0x46, 0x38]):
		return "gif"
	if bytes.size() >= 12 and _ascii(bytes, 0, 4) == "RIFF" and _ascii(bytes, 8, 4) == "WEBP":
		return "webp"
	if _starts_with(bytes, [0x42, 0x4D]):
		return "bmp"
	if _starts_with(bytes, [0x49, 0x49, 0x2A, 0x00]) or _starts_with(bytes, [0x4D, 0x4D, 0x00, 0x2A]):
		return "tiff"
	if _starts_with(bytes, [0x00, 0x00, 0x01, 0x00]):
		return "ico"
	if _starts_with(bytes, [0x38, 0x42, 0x50, 0x53]):
		return "psd"
	if _starts_with(bytes, [0xFF, 0x0A]) or (bytes.size() >= 12 and _ascii(bytes, 4, 4) == "JXL "):
		return "jxl"
	if bytes.size() >= 12 and _ascii(bytes, 4, 4) == "ftyp":
		var brand := _ascii(bytes, 8, 4)
		if brand in ["avif", "avis"]:
			return "avif"
		if brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]:
			return "heic"
	var head := bytes.slice(0, mini(bytes.size(), 2048)).get_string_from_utf8().to_lower()
	if head.contains("<svg"):
		return "svg"
	if path.get_extension().to_lower() == "tga":
		return "tga"
	return ""


## Loads any supported image. Returns {ok, image, format, converted_with, error}.
## Blocking (conversion can take a moment); run it via FileOps.run_async from the UI.
static func load_image(path: String, temp_dir := "") -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {"ok": false, "error": "Could not read %s." % path.get_file()}
	var fmt := detect_format(bytes, path)
	if fmt in NATIVE_FORMATS:
		var img := _decode_native(bytes, fmt)
		if img != null:
			return {"ok": true, "image": img, "format": fmt, "converted_with": ""}
		return {"ok": false, "format": fmt, "error": "%s looks like a %s file but could not be decoded." % [path.get_file(), fmt.to_upper()]}
	if fmt == "" and not CONVERTIBLE_FORMATS.has(path.get_extension().to_lower()):
		return {"ok": false, "error": "%s is not an image format Server Manager recognizes. %s" % [path.get_file(), supported_text()]}
	var converted := convert_to_png(path, fmt if fmt != "" else path.get_extension().to_lower(), temp_dir)
	if not converted.ok:
		return converted
	var png := Image.new()
	var err := png.load_png_from_buffer(FileAccess.get_file_as_bytes(converted.png_path))
	DirAccess.remove_absolute(converted.png_path)
	if err != OK:
		return {"ok": false, "format": fmt, "error": "The converted image could not be read."}
	return {"ok": true, "image": png, "format": fmt, "converted_with": converted.tool}


static func _decode_native(bytes: PackedByteArray, fmt: String) -> Image:
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match fmt:
		"png":
			err = img.load_png_from_buffer(bytes)
		"jpeg":
			err = img.load_jpg_from_buffer(bytes)
		"webp":
			err = img.load_webp_from_buffer(bytes)
		"bmp":
			err = img.load_bmp_from_buffer(bytes)
		"tga":
			err = img.load_tga_from_buffer(bytes)
		"svg":
			err = img.load_svg_from_buffer(bytes, 1.0)
			if err == OK and img.get_width() > 0:
				# Re-rasterize so the longer side is large enough to crop and downscale well.
				var scale := clampf(float(SVG_RASTER_SIZE) / maxi(img.get_width(), img.get_height()), 0.05, 64.0)
				err = img.load_svg_from_buffer(bytes, scale)
	if err != OK or img.is_empty():
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


# --- External conversion ---------------------------------------------------------

## Converter executables available for [param fmt], best first: [{name, path}].
static func available_converters(fmt: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var names := Array(GENERIC_CONVERTERS)
	names.append_array(SPECIFIC_CONVERTERS.get(fmt, []))
	for n in names:
		# Windows has its own convert.exe (it converts FAT drives to NTFS); never call it.
		if n == "convert" and OS.get_name() == "Windows":
			continue
		var p := PlatformBackend.find_in_path(n)
		if p != "":
			out.append({"name": n, "path": p})
	return out


## Arguments that convert [param src] (its first frame/page) into a PNG at [param dst].
static func converter_args(tool_name: String, src: String, dst: String) -> PackedStringArray:
	match tool_name:
		"magick", "convert":
			# [0] = first frame of animations/multi-page files; -auto-orient applies EXIF rotation.
			return PackedStringArray([src + "[0]", "-auto-orient", "png32:" + dst])
		"vips":
			return PackedStringArray(["copy", src, dst])
		"ffmpeg":
			return PackedStringArray(["-y", "-loglevel", "error", "-i", src, "-frames:v", "1", dst])
		"heif-convert", "avifdec", "djxl":
			return PackedStringArray([src, dst])
	return PackedStringArray()


## Converts with the first converter that succeeds. Returns {ok, png_path, tool, error}.
static func convert_to_png(src: String, fmt: String, temp_dir := "") -> Dictionary:
	var converters := available_converters(fmt)
	if converters.is_empty():
		return {"ok": false, "error": "%s files need a converter, and none is installed. %s Install ImageMagick (magick) to open %s files." % [
				fmt.to_upper(), supported_text(), fmt.to_upper()]}
	var dir := temp_dir if temp_dir != "" else ProjectSettings.globalize_path("user://cache/icon-convert")
	DirAccess.make_dir_recursive_absolute(dir)
	var tried := PackedStringArray()
	for c in converters:
		var dst := dir.path_join("icon-%d-%s.png" % [Time.get_ticks_usec(), c.name])
		var output: Array = []
		var code := PlatformBackend.execute(c.path, converter_args(c.name, src, dst), output, true)
		if code == 0 and FileAccess.file_exists(dst) and FileAccess.get_file_as_bytes(dst).size() > 8:
			return {"ok": true, "png_path": dst, "tool": c.name}
		DirAccess.remove_absolute(dst)
		tried.append(c.name)
	return {"ok": false, "error": "Could not convert this %s file (tried %s). %s" % [fmt.to_upper(), ", ".join(tried), supported_text()]}


static func supported_text() -> String:
	return "PNG, JPEG, WebP, SVG, BMP and TGA always work; GIF, AVIF, HEIC, ICO, TIFF, JPEG XL and PSD work when a converter such as ImageMagick is installed."


# --- Cropping & rendering ----------------------------------------------------------

## Largest centred square inside an image of [param size] ("Fill": no empty space).
static func fill_crop(size: Vector2i) -> Rect2:
	var side := float(mini(size.x, size.y))
	return Rect2((Vector2(size) - Vector2(side, side)) * 0.5, Vector2(side, side))


## Smallest centred square containing the whole image ("Fit": transparent padding).
static func fit_crop(size: Vector2i) -> Rect2:
	var side := float(maxi(size.x, size.y))
	return Rect2((Vector2(size) - Vector2(side, side)) * 0.5, Vector2(side, side))


## Keeps a crop square valid: between [param min_side] pixels and the "fit" square.
## On each axis the square stays inside the image, unless it is larger than the image
## there, in which case the image stays inside the square (transparent padding).
static func clamp_crop(rect: Rect2, image_size: Vector2i, min_side := 1.0) -> Rect2:
	var max_side := float(maxi(image_size.x, image_size.y))
	var side := clampf(minf(rect.size.x, rect.size.y), minf(min_side, max_side), max_side)
	var pos := rect.position
	for axis in 2:
		var dim := float(image_size[axis])
		if side <= dim:
			pos[axis] = clampf(pos[axis], 0.0, dim - side)
		else:
			pos[axis] = clampf(pos[axis], dim - side, 0.0)
	return Rect2(pos, Vector2(side, side))


## Renders the crop square of [param image] into a 64×64 icon with transparency kept.
## Large sources are reduced in halving steps before a final Lanczos pass to avoid
## aliasing; [param pixel_art] keeps hard pixels (nearest neighbour).
static func render(image: Image, crop: Rect2, pixel_art := false, size := SIZE) -> Image:
	var src := image
	if src.get_format() != Image.FORMAT_RGBA8:
		src = image.duplicate() as Image
		src.convert(Image.FORMAT_RGBA8)
	var canvas := Image.create(size, size, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0, 0))
	var bounds := Rect2(Vector2.ZERO, Vector2(src.get_size()))
	var visible := crop.intersection(bounds)
	if visible.size.x < 1.0 or visible.size.y < 1.0 or crop.size.x <= 0.0:
		return canvas
	var scale := size / crop.size.x
	var region := Rect2i(visible.position.floor(), visible.size.round())
	region = region.intersection(Rect2i(Vector2i.ZERO, src.get_size()))
	var part := src.get_region(region)
	var target := Vector2i(maxi(roundi(region.size.x * scale), 1), maxi(roundi(region.size.y * scale), 1))
	_resize_quality(part, target, pixel_art)
	var offset := Vector2i(((Vector2(region.position) - crop.position) * scale).round())
	canvas.blit_rect(part, Rect2i(Vector2i.ZERO, part.get_size()), offset)
	return canvas


static func _resize_quality(img: Image, target: Vector2i, pixel_art: bool) -> void:
	if pixel_art:
		img.resize(target.x, target.y, Image.INTERPOLATE_NEAREST)
		return
	if img.get_width() <= target.x and img.get_height() <= target.y:
		img.resize(target.x, target.y, Image.INTERPOLATE_CUBIC)
		return
	# Premultiplied alpha keeps transparent pixels' colours from bleeding into edges.
	img.premultiply_alpha()
	while img.get_width() >= target.x * 2 and img.get_height() >= target.y * 2:
		img.resize(maxi(img.get_width() / 2, target.x), maxi(img.get_height() / 2, target.y), Image.INTERPOLATE_LANCZOS)
	img.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
	_unpremultiply(img)


static func _unpremultiply(img: Image) -> void:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.0 and c.a < 1.0:
				img.set_pixel(x, y, Color(minf(c.r / c.a, 1.0), minf(c.g / c.a, 1.0), minf(c.b / c.a, 1.0), c.a))


## Downscaled copy for interactive display (the cropper works on this; the final render
## uses the full image). Returns the copy and the factor from preview to full pixels.
static func preview_copy(image: Image, max_side := 1600) -> Dictionary:
	var longest := maxi(image.get_width(), image.get_height())
	if longest <= max_side:
		return {"image": image, "factor": 1.0}
	var factor := float(longest) / max_side
	var copy := image.duplicate() as Image
	var target := Vector2i(maxi(roundi(image.get_width() / factor), 1), maxi(roundi(image.get_height() / factor), 1))
	while copy.get_width() >= target.x * 2:
		copy.resize(copy.get_width() / 2, maxi(copy.get_height() / 2, 1), Image.INTERPOLATE_BILINEAR)
	copy.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
	return {"image": copy, "factor": float(image.get_width()) / copy.get_width()}


# --- Saving & reading ------------------------------------------------------------

## Writes a 64×64 icon to [param dir] atomically.
static func save(dir: String, icon: Image) -> Error:
	if icon.get_width() != SIZE or icon.get_height() != SIZE:
		return ERR_INVALID_PARAMETER
	var path := icon_path(dir)
	var tmp := path + ".tmp.png"
	var err := icon.save_png(tmp)
	if err != OK:
		return err
	err = DirAccess.rename_absolute(tmp, path)
	_texture_cache.erase(path)
	return err


static func remove(dir: String) -> Error:
	var path := icon_path(dir)
	_texture_cache.erase(path)
	if not FileAccess.file_exists(path):
		return OK
	return DirAccess.remove_absolute(path)


## {exists, valid (64×64 PNG), size: Vector2i}
static func info(dir: String) -> Dictionary:
	var path := icon_path(dir)
	if not FileAccess.file_exists(path):
		return {"exists": false, "valid": false, "size": Vector2i.ZERO}
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return {"exists": true, "valid": false, "size": Vector2i.ZERO}
	return {"exists": true, "valid": img.get_size() == Vector2i(SIZE, SIZE), "size": img.get_size()}


## The current icon as a texture, or null. Reloaded whenever the file changes (never
## through the resource cache, so a new icon shows immediately).
static func load_texture(dir: String) -> Texture2D:
	var path := icon_path(dir)
	if not FileAccess.file_exists(path):
		_texture_cache.erase(path)
		return null
	var mtime := FileAccess.get_modified_time(path)
	var cached: Dictionary = _texture_cache.get(path, {})
	if cached.get("mtime", -1) == mtime:
		return cached.texture
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	# Mipmaps keep the 64 px icon smooth when shown smaller (sidebar, cards).
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_texture_cache[path] = {"mtime": mtime, "texture": tex}
	return tex


static func _starts_with(bytes: PackedByteArray, sig: Array) -> bool:
	if bytes.size() < sig.size():
		return false
	for i in sig.size():
		if bytes[i] != sig[i]:
			return false
	return true


static func _ascii(bytes: PackedByteArray, start: int, length: int) -> String:
	if bytes.size() < start + length:
		return ""
	return bytes.slice(start, start + length).get_string_from_ascii()
