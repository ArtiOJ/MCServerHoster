class_name LogParser
extends RefCounted
## Recognises interesting events in (ANSI-stripped) Paper console output.

enum Level { INFO, WARN, ERROR, OTHER, COMMAND, SYSTEM }

# Matches the console format "[12:00:00 INFO]:" and the log-file format "[12:00:00] [Server thread/INFO]:".
static var _re_level := RegEx.create_from_string("^\\[(\\d{2}:\\d{2}:\\d{2})(?:\\] \\[[^\\]]*/| [\\w\\- /#]+?)? ?(INFO|WARN|ERROR|FATAL)\\]")
static var _re_done := RegEx.create_from_string("Done \\(([\\d.,]+)s\\)! For help")
# Newer versions prefix broadcast messages with "System chat: ".
static var _re_join := RegEx.create_from_string("\\]: (?:System chat: )?([A-Za-z0-9_.]{1,16}) joined the game")
static var _re_leave := RegEx.create_from_string("\\]: (?:System chat: )?([A-Za-z0-9_.]{1,16}) left the game")
static var _re_gamerule := RegEx.create_from_string("currently set to:? *(\\S+)")
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


## Parses the reply to `gamerule <name>` ("Gamerule pvp is currently set to: true" or
## "Game rule pvp is currently set to true"). Returns "" when not found.
static func parse_gamerule(text: String) -> String:
	var m := _re_gamerule.search(Ansi.strip(text))
	return m.get_string(1) if m != null else ""


## True for Paper's lines announcing a crash (written even when it then shuts down "cleanly").
static func is_crash_report(plain: String) -> bool:
	return plain.contains("This crash report has been saved to") or plain.contains("Encountered an unexpected exception")


## Plain-language explanation for well-known fatal console lines, or "".
static func failure_hint(plain: String, port := 0) -> String:
	if plain.contains("FAILED TO BIND TO PORT"):
		return "Port %d is already in use by another program or server." % port if port > 0 else "The server's port is already in use."
	if plain.contains("UnsupportedClassVersionError") or plain.contains("has been compiled by a more recent version of the Java Runtime"):
		return "The selected Java is too old for this Paper version. Pick a newer Java in Resources."
	if plain.contains("You need to agree to the EULA"):
		return "The Minecraft EULA has not been accepted."
	if plain.contains("java.lang.OutOfMemoryError"):
		return "The server ran out of memory. Give it more RAM in Resources."
	if plain.contains("Could not reserve enough space for object heap") or plain.contains("Initial heap size set to a larger value"):
		return "Java could not reserve the requested memory. Lower the RAM setting in Resources."
	if plain.contains("Unable to access jarfile"):
		return "The server jar is missing."
	if plain.contains("Failed to load level.dat") or plain.contains("Failed to load datapacks"):
		return "The world failed to load; it may be corrupt or from a newer Minecraft version. Restore a backup if needed."
	return ""


## Explanation for an exit code when the console gave no clue, or "".
static func exit_code_hint(code: int) -> String:
	match code:
		137:
			return "The process was killed (SIGKILL), most often by the out-of-memory killer or the hard memory limit in Resources."
		143:
			return "The process was terminated (SIGTERM) by something outside Server Manager."
		-1:
			return "The process ended while re-attached; its exit code is unknown."
	return ""
