class_name Nbt
extends RefCounted
## Minimal reader for Minecraft's Named Binary Tag format (as used by level.dat).
## Compounds become Dictionaries, lists and arrays become Arrays, numbers become
## int/float, strings become String. Malformed or truncated data yields an empty result.
## Reference: https://minecraft.wiki/w/NBT_format

const TAG_END := 0
const TAG_BYTE := 1
const TAG_SHORT := 2
const TAG_INT := 3
const TAG_LONG := 4
const TAG_FLOAT := 5
const TAG_DOUBLE := 6
const TAG_BYTE_ARRAY := 7
const TAG_STRING := 8
const TAG_LIST := 9
const TAG_COMPOUND := 10
const TAG_INT_ARRAY := 11
const TAG_LONG_ARRAY := 12

const MAX_DEPTH := 64
## Upper bound on decompressed size (level.dat is a few KB; this guards against zip bombs).
const MAX_SIZE := 16 * 1024 * 1024

var _data := PackedByteArray()
var _pos := 0
var _failed := false


## Reads a gzip-compressed (or uncompressed) NBT file. Returns the root compound, or {} on failure.
static func read_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var raw := f.get_buffer(mini(f.get_length(), MAX_SIZE))
	return parse(raw)


## Parses NBT bytes (gzip-compressed or not). Returns the root compound, or {} on failure.
static func parse(raw: PackedByteArray) -> Dictionary:
	var data := raw
	if raw.size() >= 2 and raw[0] == 0x1F and raw[1] == 0x8B:
		data = raw.decompress_dynamic(MAX_SIZE, FileAccess.COMPRESSION_GZIP)
	if data.is_empty():
		return {}
	var reader := Nbt.new()
	reader._data = data
	var root = reader._read_root()
	return root if root is Dictionary and not reader._failed else {}


## Follows a path of keys through nested compounds, e.g. dig(root, ["Data", "Version", "Name"]).
static func dig(root: Dictionary, keys: Array, default: Variant = null) -> Variant:
	var node: Variant = root
	for key in keys:
		if not node is Dictionary or not (node as Dictionary).has(key):
			return default
		node = node[key]
	return node


func _read_root() -> Variant:
	var type := _u8()
	if _failed or type != TAG_COMPOUND:
		_failed = true
		return null
	_string()  # Root name (usually empty).
	return _payload(TAG_COMPOUND, 0)


func _payload(type: int, depth: int) -> Variant:
	if _failed:
		return null
	if depth > MAX_DEPTH:
		_failed = true
		return null
	match type:
		TAG_BYTE:
			var v := _u8()
			return v - 256 if v > 127 else v
		TAG_SHORT:
			var v := _u16()
			return v - 65536 if v > 32767 else v
		TAG_INT:
			return _i32()
		TAG_LONG:
			return _i64()
		TAG_FLOAT:
			var b := _take(4)
			b.reverse()
			return b.decode_float(0) if b.size() == 4 else 0.0
		TAG_DOUBLE:
			var b := _take(8)
			b.reverse()
			return b.decode_double(0) if b.size() == 8 else 0.0
		TAG_BYTE_ARRAY:
			var n := _length()
			return Array(_take(n))
		TAG_STRING:
			return _string()
		TAG_LIST:
			var elem := _u8()
			var n := _length()
			var out := []
			for i in n:
				if _failed:
					break
				out.append(_payload(elem, depth + 1))
			return out
		TAG_COMPOUND:
			var out := {}
			while not _failed:
				var t := _u8()
				if t == TAG_END:
					break
				var name := _string()
				out[name] = _payload(t, depth + 1)
			return out
		TAG_INT_ARRAY:
			var n := _length()
			var out := []
			for i in n:
				out.append(_i32())
			return out
		TAG_LONG_ARRAY:
			var n := _length()
			var out := []
			for i in n:
				out.append(_i64())
			return out
	_failed = true
	return null


func _take(n: int) -> PackedByteArray:
	if n < 0 or _pos + n > _data.size():
		_failed = true
		return PackedByteArray()
	var out := _data.slice(_pos, _pos + n)
	_pos += n
	return out


func _u8() -> int:
	if _pos >= _data.size():
		_failed = true
		return 0
	_pos += 1
	return _data[_pos - 1]


func _u16() -> int:
	var b := _take(2)
	return (b[0] << 8) | b[1] if b.size() == 2 else 0


func _i32() -> int:
	var b := _take(4)
	if b.size() != 4:
		return 0
	var v := (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]
	return v - 0x100000000 if v > 0x7FFFFFFF else v


func _i64() -> int:
	var b := _take(8)
	if b.size() != 8:
		return 0
	b.reverse()
	return b.decode_s64(0)


## Array/list lengths must fit in the remaining data, which also rejects absurd values.
func _length() -> int:
	var n := _i32()
	if n < 0 or n > _data.size() - _pos:
		_failed = true
		return 0
	return n


func _string() -> String:
	var n := _u16()
	return _take(n).get_string_from_utf8()
