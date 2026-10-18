class_name LogParser
extends RefCounted
## Recognises interesting events in (ANSI-stripped) Paper console output.

enum Level { INFO, WARN, ERROR, OTHER, COMMAND, SYSTEM }

static var _re_level := RegEx.create_from_string("^\\[(\\d{2}:\\d{2}:\\d{2})(?: [\\w\\- /#]+?)? ?(INFO|WARN|ERROR|FATAL)\\]")
static var _re_done := RegEx.create_from_string("Done \\(([\\d.,]+)s\\)! For help")
static var _re_join := RegEx.create_from_string("\\]: ([A-Za-z0-9_.]{1,16}) joined the game")
static var _re_leave := RegEx.create_from_string("\\]: ([A-Za-z0-9_.]{1,16}) left the game")
static var _re_list := RegEx.create_from_string("There are (\\d+) (?:of a max of|/) ?(\\d+) players online:?(.*)")
static var _re_tps := RegEx.create_from_string("TPS from last [^:]*:\\s*\\*?([\\d.]+)")


static func level_of(plain: String) -> Level:
	var m := _re_level.search(plain)
	if m == null:
		return Level.OTHER
	match m.get_string(2):
		"INFO":
			return Level.INFO
		"WARN":
			return Level.WARN
		_:
			return Level.ERROR


## Returns the startup time in seconds when [param plain] is Paper's "Done" line, otherwise -1.
static func startup_seconds(plain: String) -> float:
	var m := _re_done.search(plain)
	return m.get_string(1).replace(",", ".").to_float() if m != null else -1.0


static func joined_player(plain: String) -> String:
	var m := _re_join.search(plain)
	return m.get_string(1) if m != null else ""


static func left_player(plain: String) -> String:
	var m := _re_leave.search(plain)
	return m.get_string(1) if m != null else ""


static func is_stopping(plain: String) -> bool:
	return plain.contains("]: Stopping the server") or plain.contains("]: Stopping server")


static func is_world_saved(plain: String) -> bool:
	return plain.contains("Saved the game")


## Parses the response of the vanilla `list` command.
## Returns {online: int, max: int, names: PackedStringArray} or an empty dictionary.
static func parse_list(text: String) -> Dictionary:
	var m := _re_list.search(Ansi.strip(text))
	if m == null:
		return {}
	var names := PackedStringArray()
	for n in m.get_string(3).split(",", false):
		var trimmed := n.strip_edges()
		if trimmed != "":
			names.append(trimmed)
	return {"online": m.get_string(1).to_int(), "max": m.get_string(2).to_int(), "names": names}


## Parses the 1-minute TPS figure from Paper's `tps` command. Returns -1 when not found.
static func parse_tps(text: String) -> float:
	var m := _re_tps.search(Ansi.strip(text))
	return m.get_string(1).to_float() if m != null else -1.0
