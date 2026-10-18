class_name ServerProperties
extends RefCounted
## Reads and writes `server.properties` while preserving line order, comments
## and keys the manager does not know about.

## Each entry: {"key": String, "value": String} for properties, {"raw": String} for comments/blank lines.
var _lines: Array[Dictionary] = []
var _index := {}


static func load_file(path: String) -> ServerProperties:
	var props := ServerProperties.new()
	if FileAccess.file_exists(path):
		props.parse(FileAccess.get_file_as_string(path))
	return props


func parse(text: String) -> void:
	_lines.clear()
	_index.clear()
	for line in text.replace("\r\n", "\n").split("\n"):
		var stripped := line.strip_edges(true, false)
		if stripped.is_empty() or stripped.begins_with("#") or stripped.begins_with("!"):
			_lines.append({"raw": line})
			continue
		var sep := _find_separator(stripped)
		var key := unescape(stripped.substr(0, sep).strip_edges()) if sep >= 0 else unescape(stripped.strip_edges())
		var value := unescape(stripped.substr(sep + 1).strip_edges(true, false)) if sep >= 0 else ""
		if _index.has(key):
			_lines[_index[key]].value = value
		else:
			_index[key] = _lines.size()
			_lines.append({"key": key, "value": value})
	# Drop the trailing empty line produced by the final newline.
	if not _lines.is_empty() and _lines[-1].has("raw") and _lines[-1].raw == "":
		_lines.pop_back()


func has(key: String) -> bool:
	return _index.has(key)


func get_value(key: String, default := "") -> String:
	return _lines[_index[key]].value if _index.has(key) else default


func get_bool(key: String, default := false) -> bool:
	if not _index.has(key):
		return default
	return get_value(key).to_lower() == "true"


func get_int(key: String, default := 0) -> int:
	var v := get_value(key)
	return v.to_int() if v.is_valid_int() else default


func set_value(key: String, value: Variant) -> void:
	var text := str(value).to_lower() if value is bool else str(value)
	if _index.has(key):
		_lines[_index[key]].value = text
	else:
		_index[key] = _lines.size()
		_lines.append({"key": key, "value": text})


func erase(key: String) -> void:
	if not _index.has(key):
		return
	_lines.remove_at(_index[key])
	_reindex()


func keys() -> PackedStringArray:
	var out := PackedStringArray()
	for l in _lines:
		if l.has("key"):
			out.append(l.key)
	return out


func to_dict() -> Dictionary:
	var d := {}
	for l in _lines:
		if l.has("key"):
			d[l.key] = l.value
	return d


func to_text() -> String:
	var out := PackedStringArray()
	for l in _lines:
		if l.has("key"):
			out.append(escape(l.key, true) + "=" + escape(l.value, false))
		else:
			out.append(l.raw)
	return "\n".join(out) + "\n"


func save_file(path: String) -> Error:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(to_text())
	f.close()
	return DirAccess.rename_absolute(tmp, path)


func _reindex() -> void:
	_index.clear()
	for i in _lines.size():
		if _lines[i].has("key"):
			_index[_lines[i].key] = i


static func _find_separator(line: String) -> int:
	var i := 0
	while i < line.length():
		var c := line[i]
		if c == "\\":
			i += 2
			continue
		if c == "=" or c == ":":
			return i
		i += 1
	return -1


## Java .properties escaping; non-ASCII is written as \uXXXX so the file reads
## correctly whether the server loads it as UTF-8 or ISO-8859-1.
static func escape(text: String, is_key: bool) -> String:
	var out := ""
	for i in text.length():
		var c := text[i]
		var code := text.unicode_at(i)
		match c:
			"\\":
				out += "\\\\"
			"\n":
				out += "\\n"
			"\r":
				out += "\\r"
			"\t":
				out += "\\t"
			"=", ":":
				out += ("\\" + c) if is_key else c
			" ":
				out += "\\ " if is_key or i == 0 else " "
			_:
				if code > 0xFFFF:
					var v := code - 0x10000
					out += "\\u%04x\\u%04x" % [0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)]
				elif code > 0x7E or code < 0x20:
					out += "\\u%04x" % code
				else:
					out += c
	return out


static func unescape(text: String) -> String:
	if not text.contains("\\"):
		return text
	var out := ""
	var i := 0
	var pending_high := 0
	while i < text.length():
		var c := text[i]
		if c != "\\" or i + 1 >= text.length():
			out += c
			i += 1
			continue
		var n := text[i + 1]
		i += 2
		match n:
			"n":
				out += "\n"
			"t":
				out += "\t"
			"r":
				out += "\r"
			"f":
				out += "\f"
			"u":
				var hex := text.substr(i, 4)
				if hex.length() == 4 and hex.is_valid_hex_number():
					var code := hex.hex_to_int()
					i += 4
					if code >= 0xD800 and code <= 0xDBFF:
						pending_high = code
						continue
					if code >= 0xDC00 and code <= 0xDFFF and pending_high != 0:
						code = 0x10000 + ((pending_high - 0xD800) << 10) + (code - 0xDC00)
					pending_high = 0
					out += String.chr(code)
				else:
					out += "u"
			_:
				out += n
	return out
