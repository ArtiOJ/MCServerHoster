class_name ScheduleEntry
extends Resource
## A recurring task attached to a server: restart, console command or backup.

enum Kind { RESTART, COMMAND, BACKUP }
enum Mode { DAILY, INTERVAL }

const KIND_NAMES := ["Restart", "Command", "Backup"]

@export var kind: Kind = Kind.RESTART
@export var mode: Mode = Mode.DAILY
@export var enabled := true
## Local time of day for [constant Mode.DAILY], "HH:MM".
@export var time_of_day := "04:00"
## Minutes between runs for [constant Mode.INTERVAL].
@export var interval_minutes := 360
## Console command for [constant Kind.COMMAND].
@export var command := ""
## Broadcast in-game countdown warnings before a scheduled restart.
@export var warn_players := true


func describe() -> String:
	var when := ("daily at " + time_of_day) if mode == Mode.DAILY else ("every " + Fmt.duration(interval_minutes * 60))
	match kind:
		Kind.COMMAND:
			return "Run \"%s\" %s" % [command, when]
		Kind.BACKUP:
			return "Back up worlds " + when
		_:
			return "Restart " + when


## Hours and minutes parsed from [member time_of_day]; invalid input falls back to 04:00.
func get_hour_minute() -> Vector2i:
	var parts := time_of_day.strip_edges().split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i(4, 0)
	return Vector2i(clampi(parts[0].to_int(), 0, 23), clampi(parts[1].to_int(), 0, 59))


## Next run time (unix seconds, UTC) strictly after [param now]. [param base] is the
## reference point for interval schedules (e.g. when the server started).
func next_run_after(now: int, base: int) -> int:
	if mode == Mode.INTERVAL:
		var step := maxi(interval_minutes, 1) * 60
		if base > now:
			return base
		var elapsed := now - base
		return base + (elapsed / step + 1) * step
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var local_now := now + bias
	var hm := get_hour_minute()
	var target := local_now - posmod(local_now, 86400) + hm.x * 3600 + hm.y * 60
	if target <= local_now:
		target += 86400
	return target - bias


func to_dict() -> Dictionary:
	return {
		"kind": kind, "mode": mode, "enabled": enabled, "time_of_day": time_of_day,
		"interval_minutes": interval_minutes, "command": command, "warn_players": warn_players,
	}


static func from_dict(d: Dictionary) -> ScheduleEntry:
	var e := ScheduleEntry.new()
	e.kind = clampi(int(d.get("kind", 0)), 0, Kind.size() - 1) as Kind
	e.mode = clampi(int(d.get("mode", 0)), 0, Mode.size() - 1) as Mode
	e.enabled = bool(d.get("enabled", true))
	e.time_of_day = str(d.get("time_of_day", "04:00"))
	e.interval_minutes = maxi(int(d.get("interval_minutes", 360)), 1)
	e.command = str(d.get("command", ""))
	e.warn_players = bool(d.get("warn_players", true))
	return e
