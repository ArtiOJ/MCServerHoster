class_name Prbm
extends RefCounted
## BlueMap's hires tile models (PRBM, a PRWM v1 variant) and texture list, turned into what
## the map viewer draws. A tile holds non-indexed triangles with the attributes position
## (float ×3), normal (int8 ×3), color (uint8 ×3), uv (float ×2), ao (uint8), blocklight and
## sunlight (int8, 0..15), and groups (material = index into textures.json, first vertex,
## count). Everything here runs on worker threads: no nodes, no scene tree.
##
## Per-vertex values other than position and uv are handed to the shader as small data
## textures read by VERTEX_ID (one texel per vertex), which avoids per-vertex loops in
## GDScript; block textures go into one atlas (a texture array would exceed NVIDIA's limit
## of 2048 layers: Minecraft has more block textures).

## Texels per row of the per-vertex data textures.
const DATA_WIDTH := 1024
## Every block texture is scaled to this size for the atlas.
const TEXTURE_SIZE := 16
## Textures per atlas row.
const ATLAS_COLUMNS := 64
## Most bytes a decompressed tile or texture list may have.
const MAX_BYTES := 256 * 1024 * 1024

const _TYPE_SIZES := {1: 4, 3: 1, 4: 2, 6: 4, 7: 1, 8: 2, 10: 4}


## Decompresses a stored map file by its suffix (.gz, .deflate, .zst or none).
static func decompress(bytes: PackedByteArray, suffix: String) -> PackedByteArray:
	match suffix:
		".gz":
			return bytes.decompress_dynamic(MAX_BYTES, FileAccess.COMPRESSION_GZIP)
		".deflate":
			return bytes.decompress_dynamic(MAX_BYTES, FileAccess.COMPRESSION_DEFLATE)
		".zst":
			return bytes.decompress_dynamic(MAX_BYTES, FileAccess.COMPRESSION_ZSTD)
	return bytes


## Parses a (decompressed) PRBM file: {ok, count, attributes: {name: PackedByteArray},
## groups: [[material, start, count]]} or {ok: false, error}.
static func parse(b: PackedByteArray) -> Dictionary:
	if b.size() < 8 or b[0] != 1:
		return {"ok": false, "error": "not a BlueMap tile"}
	var flags := b[1]
	if (flags >> 7) & 1 == 1 or (flags >> 5) & 1 == 1:
		return {"ok": false, "error": "indexed or big-endian tiles aren't supported"}
	var attr_count := flags & 0x1f
	var count := b[2] | (b[3] << 8) | (b[4] << 16)
	var pos := 8
	var attributes := {}
	for i in attr_count:
		var end := b.find(0, pos)
		if end < 0:
			return {"ok": false, "error": "damaged tile"}
		var name := b.slice(pos, end).get_string_from_ascii()
		pos = end + 1
		var f := b[pos]
		pos += 1
		var cardinality := ((f >> 4) & 3) + 1
		var size: int = _TYPE_SIZES.get(f & 0xf, 0)
		if size == 0:
			return {"ok": false, "error": "unknown attribute type"}
		pos = (pos + 3) & ~3
		var length := count * cardinality * size
		if pos + length > b.size():
			return {"ok": false, "error": "damaged tile"}
		attributes[name] = b.slice(pos, pos + length)
		pos += length
	pos = (pos + 3) & ~3
	var groups := []
	while pos + 4 <= b.size():
		var material := b.decode_s32(pos)
		if material == -1 or pos + 12 > b.size():
			break
		groups.append([material, b.decode_s32(pos + 4), b.decode_s32(pos + 8)])
		pos += 12
	for name in ["position", "color", "uv", "ao", "sunlight", "blocklight"]:
		if not attributes.has(name):
			return {"ok": false, "error": "tile without " + name}
	return {"ok": true, "count": count, "attributes": attributes, "groups": groups}


## The vertex data of a parsed tile split into an opaque and a transparent part (by
## [param transparent], material index -> true for half-transparent textures such as water
## and glass). Each part: {count, vertices: PackedVector3Array, uvs: PackedVector2Array,
## images: {color, ao, sun, block, material}} or {} when empty. [param cutout]: material
## index -> true for textures with holes (sampled without mipmaps so leaves stay leafy).
static func surfaces(tile: Dictionary, transparent: Dictionary, cutout: Dictionary) -> Array:
	var parts := [[], []]
	for g in tile.groups:
		parts[1 if transparent.get(g[0], false) else 0].append(g)
	var out := []
	for groups in parts:
		out.append(_surface(tile, groups, cutout) if not groups.is_empty() else {})
	return out


static func _surface(tile: Dictionary, groups: Array, cutout: Dictionary) -> Dictionary:
	var a: Dictionary = tile.attributes
	var pos := PackedByteArray()
	var uv := PackedByteArray()
	var color := PackedByteArray()
	var ao := PackedByteArray()
	var sun := PackedByteArray()
	var block := PackedByteArray()
	var material := PackedFloat32Array()
	var count := 0
	for g in groups:
		var start: int = g[1]
		var n: int = mini(g[2], tile.count - start)
		if start < 0 or n <= 0:
			continue
		pos.append_array(a.position.slice(start * 12, (start + n) * 12))
		uv.append_array(a.uv.slice(start * 8, (start + n) * 8))
		color.append_array(a.color.slice(start * 3, (start + n) * 3))
		ao.append_array(a.ao.slice(start, start + n))
		sun.append_array(a.sunlight.slice(start, start + n))
		block.append_array(a.blocklight.slice(start, start + n))
		var m := PackedFloat32Array()
		m.resize(n)
		m.fill(float(g[0] * 2 + (1 if cutout.get(g[0], false) else 0)))
		material.append_array(m)
		count += n
	if count == 0:
		return {}
	return {
		"count": count,
		"vertices": bytes_to_var(_header(TYPE_PACKED_VECTOR3_ARRAY, count) + pos),
		"uvs": bytes_to_var(_header(TYPE_PACKED_VECTOR2_ARRAY, count) + uv),
		"images": {
			"color": _rgba(_data_image(color, 3, Image.FORMAT_RGB8)),
			"ao": _data_image(ao, 1, Image.FORMAT_R8),
			"sun": _data_image(sun, 1, Image.FORMAT_R8),
			"block": _data_image(block, 1, Image.FORMAT_R8),
			"material": _data_image(material.to_byte_array(), 4, Image.FORMAT_RF),
		},
	}


## RGB8 textures read as black in the Compatibility renderer; RGBA8 works.
static func _rgba(img: Image) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	return img


## Variant encoding header of a packed array (type, element count), so packed floats
## become a PackedVector3Array / PackedVector2Array without a loop.
static func _header(type: int, count: int) -> PackedByteArray:
	var h := PackedByteArray()
	h.resize(8)
	h.encode_u32(0, type)
	h.encode_u32(4, count)
	return h


## One texel per vertex, DATA_WIDTH texels per row.
static func _data_image(bytes: PackedByteArray, texel_size: int, format: int) -> Image:
	var texels := bytes.size() / texel_size
	var height := maxi(1, ceili(float(texels) / DATA_WIDTH))
	bytes.resize(DATA_WIDTH * height * texel_size)
	return Image.create_from_data(DATA_WIDTH, height, false, format, bytes)


## The block textures of a (decompressed) textures.json: {ok, atlas: Image (ATLAS_COLUMNS
## TEXTURE_SIZE squares per row, by index; first animation frame), transparent:
## {index: true}, cutout: {index: true}} or {ok: false, error}.
static func textures(json_bytes: PackedByteArray) -> Dictionary:
	var list: Variant = JSON.parse_string(json_bytes.get_string_from_utf8())
	if not list is Array or list.is_empty():
		return {"ok": false, "error": "the map has no textures yet"}
	var rows := ceili(float(list.size()) / ATLAS_COLUMNS)
	var atlas := Image.create_empty(ATLAS_COLUMNS * TEXTURE_SIZE, rows * TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var transparent := {}
	var cutout := {}
	for i in list.size():
		var t: Dictionary = list[i] if list[i] is Dictionary else {}
		var img := Image.new()
		var data := str(t.get("texture", ""))
		var loaded := ERR_INVALID_DATA
		if data.begins_with("data:image/png;base64,"):
			loaded = img.load_png_from_buffer(Marshalls.base64_to_raw(data.substr(22)))
		if loaded != OK or img.get_width() == 0:
			var c: Array = t.get("color", [1, 0, 1, 1])
			img = Image.create_empty(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
			img.fill(Color(float(c[0]), float(c[1]), float(c[2]), float(c[3])) if c.size() >= 4 else Color.MAGENTA)
		img.convert(Image.FORMAT_RGBA8)
		if img.get_height() > img.get_width():
			img = img.get_region(Rect2i(0, 0, img.get_width(), img.get_width()))  # First animation frame.
		if img.get_width() != TEXTURE_SIZE or img.get_height() != TEXTURE_SIZE:
			img.resize(TEXTURE_SIZE, TEXTURE_SIZE, Image.INTERPOLATE_NEAREST)
		atlas.blit_rect(img, Rect2i(0, 0, TEXTURE_SIZE, TEXTURE_SIZE), Vector2i(i % ATLAS_COLUMNS, i / ATLAS_COLUMNS) * TEXTURE_SIZE)
		if bool(t.get("halfTransparent", false)):
			transparent[i] = true
		else:
			var color: Array = t.get("color", [0, 0, 0, 1])
			if color.size() < 4 or float(color[3]) < 1.0:
				cutout[i] = true
	return {"ok": true, "atlas": atlas, "transparent": transparent, "cutout": cutout}
