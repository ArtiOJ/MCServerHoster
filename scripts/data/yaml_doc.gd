class_name YamlDoc
extends RefCounted
## Minimal line-based editor for block-style YAML mappings, as written by Paper,
## Spigot and Bukkit. Reads and writes scalar values at dotted paths while
## leaving every other line (comments, lists, ordering) untouched. Missing
## parent mappings are created. Not a general YAML parser: flow collections and
## multi-line scalars are only preserved, never edited.

const INDENT_STEP := 2

static var _re_key := RegEx.create_from_string("^( *)('[^']*'|\"[^\"]*\"|[^\\s#'\"\\-][^:#]*?|-[^\\s][^:#]*?) *:(?: +(.*?))? *$")
static var _re_plain := RegEx.create_from_string("^[A-Za-z0-9_./<>+-][^:#]*$")

var _lines := PackedStringArray()


static func load_file(path: String) -> YamlDoc:
	var doc := YamlDoc.new()
	if FileAccess.file_exists(path):
		doc.parse(FileAccess.get_file_as_string(path))
	return doc


func parse(text: String) -> void:
	_lines = text.replace("\r\n", "\n").split("\n")
	if not _lines.is_empty() and _lines[-1] == "":
		_lines.remove_at(_lines.size() - 1)


func is_empty() -> bool:
	return _lines.is_empty()


func has(path: String) -> bool:
	return _locate(path.split(".")).found


## Unquoted scalar at [param path], or [param default] when missing or not a scalar.
func get_value(path: String, default := "") -> String:
	var loc := _locate(path.split("."))
	if not loc.found or loc.value == "":
		return default
	return unquote(loc.value)


## Sets the scalar at [param path] to [param yaml_value] (already formatted, see [method format_scalar]).
func set_value(path: String, yaml_value: String) -> void:
	var segments := path.split(".")
	var loc := _locate(segments)
	if loc.found:
		var m := _re_key.search(_lines[loc.line])
		_lines[loc.line] = "%s%s: %s" % [m.get_string(1), m.get_string(2), yaml_value]
		return
	var depth: int = loc.depth
	var insert_at: int
	var indent: int
	if depth == 0:
		insert_at = _lines.size()
		indent = 0
	else:
		var parent_indent: int = loc.indent
		insert_at = _block_end(loc.line, parent_indent)
		indent = _child_indent(loc.line, parent_indent)
	var new_lines := PackedStringArray()
	for i in range(depth, segments.size()):
		var pad := " ".repeat(indent + (i - depth) * INDENT_STEP)
		if i == segments.size() - 1:
			new_lines.append("%s%s: %s" % [pad, segments[i], yaml_value])
		else:
			new_lines.append("%s%s:" % [pad, segments[i]])
	for j in new_lines.size():
		_lines.insert(insert_at + j, new_lines[j])


func to_text() -> String:
	return "\n".join(_lines) + "\n"


func save_file(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(to_text())
	f.close()
	return DirAccess.rename_absolute(tmp, path)


## Formats a value for writing. Booleans and numbers stay bare; strings are quoted when needed.
static func format_scalar(value: String, is_string: bool) -> String:
	if not is_string:
		return value
	var reserved := ["true", "false", "yes", "no", "on", "off", "null", "~"]
	if value != "" and _re_plain.search(value) != null and not reserved.has(value.to_lower()) \
			and not value.is_valid_float() and not value.ends_with(" "):
		return value
	return "'" + value.replace("'", "''") + "'"


static func unquote(raw: String) -> String:
	raw = raw.strip_edges()
	if raw.length() >= 2 and raw.begins_with("'") and raw.ends_with("'"):
		return raw.substr(1, raw.length() - 2).replace("''", "'")
	if raw.length() >= 2 and raw.begins_with("\"") and raw.ends_with("\""):
		return raw.substr(1, raw.length() - 2).replace("\\\"", "\"").replace("\\\\", "\\")
	return raw


## Walks the document. Returns {found, line, value, depth, indent}: when not found, depth is
## how many leading segments exist and line/indent describe the deepest existing one.
func _locate(segments: PackedStringArray) -> Dictionary:
	var result := {"found": false, "line": -1, "value": "", "depth": 0, "indent": -1}
	var stack: Array[Array] = []  # [indent, key]
	for i in _lines.size():
		var m := _re_key.search(_lines[i])
		if m == null:
			continue
		var indent := m.get_string(1).length()
		while not stack.is_empty() and stack[-1][0] >= indent:
			stack.pop_back()
		stack.append([indent, unquote(m.get_string(2))])
		var depth := stack.size()
		if depth > segments.size():
			continue
		var matches := true
		for k in depth:
			if stack[k][1] != segments[k]:
				matches = false
				break
		if not matches:
			continue
		if depth == segments.size():
			return {"found": true, "line": i, "value": m.get_string(3), "depth": depth, "indent": indent}
		if depth > result.depth and m.get_string(3) == "":
			result = {"found": false, "line": i, "value": "", "depth": depth, "indent": indent}
	return result


## Index just after the last line belonging to the mapping that starts at [param line].
func _block_end(line: int, parent_indent: int) -> int:
	var last := line
	for j in range(line + 1, _lines.size()):
		var text := _lines[j]
		var stripped := text.strip_edges()
		if stripped == "" or stripped.begins_with("#"):
			continue
		var indent := text.length() - text.lstrip(" ").length()
		if indent < parent_indent or (indent == parent_indent and not stripped.begins_with("- ")):
			break
		last = j
	return last + 1


func _child_indent(line: int, parent_indent: int) -> int:
	for j in range(line + 1, _lines.size()):
		var text := _lines[j]
		var stripped := text.strip_edges()
		if stripped == "" or stripped.begins_with("#"):
			continue
		var indent := text.length() - text.lstrip(" ").length()
		return indent if indent > parent_indent else parent_indent + INDENT_STEP
	return parent_indent + INDENT_STEP
