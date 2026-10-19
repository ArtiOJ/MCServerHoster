class_name LogArchive
extends RefCounted
## Finds, reads and summarises a server's log history: logs/latest.log (the current
## or last session), rotated logs/*.log.gz archives and crash-reports/*.txt.
## Everything here is static and thread-safe so it can run on a worker thread.

enum Kind { CURRENT, ARCHIVE, CRASH }

## Larger logs are refused (gz) or only their end is read (plain), to keep memory bounded.
const MAX_BYTES := 50 * 1024 * 1024
## Lines longer than this are shortened in the viewer (crash reports contain huge thread dumps).
const MAX_LINE_CHARS := 2000

static var _re_archive := RegEx.create_from_string("^(\\d{4})-(\\d{2})-(\\d{2})-(\\d+)\\.log\\.gz$")
static var _re_crash := RegEx.create_from_string("crash-(\\d{4})-(\\d{2})-(\\d{2})_(\\d{2})\\.(\\d{2})\\.(\\d{2})")


## Log files of the server in [param server_dir], newest first:
## [{path, name, kind, time (unix), size, label, session}].
static func list_entries(server_dir: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var logs_dir := server_dir.path_join("logs")
	for f in _files(logs_dir):
		var path := logs_dir.path_join(f)
		var m := _re_archive.search(f)
		if f == "latest.log":
			out.append(_entry(path, Kind.CURRENT, FileAccess.get_modified_time(path), 1 << 30))
		elif m != null:
			out.append(_entry(path, Kind.ARCHIVE, FileAccess.get_modified_time(path), m.get_string(4).to_int()))
		elif f.ends_with(".log") or f.ends_with(".log.gz"):
			out.append(_entry(path, Kind.ARCHIVE, FileAccess.get_modified_time(path), 0))
	var crash_dir := server_dir.path_join("crash-reports")
	for f in _files(crash_dir):
		if not f.ends_with(".txt"):
			continue
		var path := crash_dir.path_join(f)
		var t := crash_time_from_name(f)
		out.append(_entry(path, Kind.CRASH, t if t > 0 else FileAccess.get_modified_time(path), 0))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.kind == Kind.CURRENT or b.kind == Kind.CURRENT:
			return a.kind == Kind.CURRENT and b.kind != Kind.CURRENT
		if a.time != b.time:
			return a.time > b.time
		return a.session > b.session)
	return out


## Human-readable list label for an entry.
static func label_for(entry: Dictionary) -> String:
	match entry.kind:
		Kind.CURRENT:
			return "Current session"
		Kind.CRASH:
			return "Crash · %s" % Fmt.datetime(entry.time)
	var m := _re_archive.search(str(entry.name))
	if m != null:
		return "%s-%s-%s · session %d" % [m.get_string(1), m.get_string(2), m.get_string(3), m.get_string(4).to_int()]
	return str(entry.name)


## Unix time (UTC) encoded in a crash report file name (local time), or 0.
static func crash_time_from_name(file_name: String) -> int:
	var m := _re_crash.search(file_name)
	if m == null:
		return 0
	var dict := {
		"year": m.get_string(1).to_int(), "month": m.get_string(2).to_int(), "day": m.get_string(3).to_int(),
		"hour": m.get_string(4).to_int(), "minute": m.get_string(5).to_int(), "second": m.get_string(6).to_int(),
	}
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_unix_time_from_datetime_dict(dict) - bias


## Reads a log (plain or gzip). Returns {ok, text, truncated, error}.
static func read_text(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "text": "", "truncated": false, "error": "The file no longer exists."}
	if path.ends_with(".gz"):
		var packed := FileAccess.get_file_as_bytes(path)
		if packed.is_empty():
			return {"ok": true, "text": "", "truncated": false, "error": ""}
		var bytes := packed.decompress_dynamic(MAX_BYTES, FileAccess.COMPRESSION_GZIP)
		if bytes.is_empty():
			return {"ok": false, "text": "", "truncated": false,
					"error": "This archive could not be unpacked (it is damaged or larger than %s)." % Fmt.bytes(MAX_BYTES)}
		return {"ok": true, "text": bytes.get_string_from_utf8(), "truncated": false, "error": ""}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "text": "", "truncated": false, "error": error_string(FileAccess.get_open_error())}
	var length := f.get_length()
	var truncated := length > MAX_BYTES
	if truncated:
		f.seek(length - MAX_BYTES)
	var text := f.get_buffer(mini(length, MAX_BYTES)).get_string_from_utf8()
	if truncated:
		text = text.substr(text.find("\n") + 1)  # Drop the partial first line.
	return {"ok": true, "text": text, "truncated": truncated, "error": ""}


## Keeps lines matching [param query] (case-insensitive) and the level filter
## (0 = all, 1 = warnings and errors, 2 = errors), at most the last [param max_lines].
## Returns {lines, total, matched, truncated}.
static func filter_lines(text: String, query: String, level_filter: int, max_lines: int) -> Dictionary:
	var all := text.replace("\r", "").split("\n")
	if not all.is_empty() and all[-1] == "":
		all.remove_at(all.size() - 1)
	var q := query.strip_edges()
	var kept := PackedStringArray()
	var current_level := LogParser.Level.INFO
	for line in all:
		var level := LogParser.level_of(Ansi.strip(line))
		# Continuation lines (stack traces) inherit the level of the line they belong to.
		if level == LogParser.Level.OTHER:
			level = current_level
		else:
			current_level = level
		if level_filter == 1 and level != LogParser.Level.WARN and level != LogParser.Level.ERROR:
			continue
		if level_filter == 2 and level != LogParser.Level.ERROR:
			continue
		if q != "" and not line.containsn(q):
			continue
		kept.append(line if line.length() <= MAX_LINE_CHARS else line.left(MAX_LINE_CHARS) + " …")
	var truncated := kept.size() > max_lines
	var matched := kept.size()
	if truncated:
		kept = kept.slice(kept.size() - max_lines)
	return {"lines": kept, "total": all.size(), "matched": matched, "truncated": truncated}


## Key facts from a Minecraft crash report:
## {time, description, exception, cause, minecraft, server, hint}.
static func summarize_crash(text: String) -> Dictionary:
	var out := {"time": "", "description": "", "exception": "", "cause": "", "minecraft": "", "server": "", "hint": ""}
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if out.time == "" and line.begins_with("Time:"):
			out.time = line.trim_prefix("Time:").strip_edges()
		elif out.description == "" and line.begins_with("Description:"):
			out.description = line.trim_prefix("Description:").strip_edges()
		elif out.exception == "" and out.description != "" and _looks_like_exception(line):
			out.exception = line
		elif out.cause == "" and line.begins_with("Caused by:"):
			out.cause = line.trim_prefix("Caused by:").strip_edges()
		elif out.minecraft == "" and line.begins_with("Minecraft Version:"):
			out.minecraft = line.trim_prefix("Minecraft Version:").strip_edges()
		elif out.server == "" and line.begins_with("Running:"):
			out.server = line.trim_prefix("Running:").strip_edges().get_slice(" (Implementing", 0)
	out.hint = crash_hint(text)
	return out


## Plain-language reason for a crash report, using the console's failure hints plus
## the wording crash reports use for the same problems.
static func crash_hint(text: String) -> String:
	var hint := ""
	for line in text.split("\n"):
		hint = LogParser.failure_hint(line)
		if hint != "":
			return hint
	if text.containsn("Failed to bind to port"):
		return LogParser.failure_hint("FAILED TO BIND TO PORT")
	if text.contains("Watchdog") and text.contains("Server has stopped responding"):
		return "The server stopped responding (a tick took too long), so the watchdog shut it down. A plugin or a heavy area may be causing lag."
	return ""


static func _looks_like_exception(line: String) -> bool:
	return (line.begins_with("java.") or line.begins_with("javax.") or line.begins_with("net.") or line.begins_with("org.") \
			or line.begins_with("io.") or line.begins_with("com.")) and (line.contains("Exception") or line.contains("Error"))


static func _entry(path: String, kind: Kind, time: int, session: int) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	var e := {"path": path, "name": path.get_file(), "kind": kind, "time": time, "size": f.get_length() if f != null else 0, "session": session}
	e.label = label_for(e)
	return e


static func _files(dir_path: String) -> PackedStringArray:
	var dir := DirAccess.open(dir_path)
	return dir.get_files() if dir != null else PackedStringArray()
