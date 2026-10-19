class_name EventRule
extends Resource
## An automation rule: when [member trigger] happens (and the optional conditions
## hold), perform [member action] on the server. Replaces the older ScheduleEntry.

enum Trigger {
	TIME, INTERVAL, APP_STARTED, SERVER_ONLINE, SERVER_STOPPED, SERVER_CRASHED,
	PLAYER_JOINED, PLAYER_LEFT, SERVER_EMPTY, PLAYERS_AT_LEAST, TPS_BELOW, SYSTEM_SLEEP, SYSTEM_WAKE,
}
## New actions are appended so saved rules keep their meaning.
enum Action { START, STOP, RESTART, COMMAND, BROADCAST, BACKUP_WORLD, BACKUP_FULL, NOTIFY }
enum StateFilter { ANY, ONLINE, OFFLINE }

const TRIGGER_NAMES: PackedStringArray = [
	"At a time of day", "Every interval", "Server Manager opens", "Server comes online", "Server stops",
	"Server crashes", "A player joins", "A player leaves", "Server is empty for", "Players online reach",
	"TPS drops below", "Computer goes to sleep", "Computer wakes up",
]
const ACTION_NAMES: PackedStringArray = [
	"Start server", "Stop server", "Restart server", "Run command", "Broadcast message",
	"Back up worlds", "Full backup", "Notify me",
]
const STATE_FILTER_NAMES: PackedStringArray = ["Any state", "Only while online", "Only while offline"]
## Godot weekday order (Time.get_datetime_dict_*: 0 = Sunday).
const DAY_NAMES: PackedStringArray = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const ALL_DAYS := 127
## Seconds of warning given before an event stops or restarts a server that has players.
const WARNING_SECONDS := 30

@export var enabled := true
## Optional user label; [method describe] is used when empty.
@export var label := ""
@export var trigger: Trigger = Trigger.TIME
## "HH:MM" for [constant Trigger.TIME].
@export var time_of_day := "18:00"
## Bitmask of allowed days (bit = Godot weekday, 0 = Sunday). Applies to every trigger.
@export var weekdays := ALL_DAYS
@export var interval_minutes := 60
## SERVER_EMPTY: minutes; PLAYERS_AT_LEAST: player count; TPS_BELOW: TPS (sustained for a minute).
@export var threshold := 15.0
## Only fire between [member window_start] and [member window_end] (may wrap past midnight).
@export var window_enabled := false
@export var window_start := "08:00"
@export var window_end := "23:00"
@export var state_filter: StateFilter = StateFilter.ANY
@export var action: Action = Action.START
## Console command (COMMAND) or message text (BROADCAST).
@export var text := ""
## Warn players in chat before a STOP/RESTART.
@export var warn_players := true
@export var delay_seconds := 0
## Wake the computer from sleep shortly before this (timed) event runs.
@export var wake_computer := false


func is_timed() -> bool:
	return trigger == Trigger.TIME or trigger == Trigger.INTERVAL


func describe() -> String:
	if label.strip_edges() != "":
		return label.strip_edges()
	return "%s → %s" % [describe_trigger(), describe_action()]


func describe_trigger() -> String:
	var when := ""
	match trigger:
		Trigger.TIME:
			when = "at %s" % time_of_day
		Trigger.INTERVAL:
			when = "every %s" % Fmt.duration(interval_minutes * 60)
		Trigger.SERVER_EMPTY:
			when = "empty for %d min" % int(threshold)
		Trigger.PLAYERS_AT_LEAST:
			when = "%d+ players online" % int(threshold)
		Trigger.TPS_BELOW:
			when = "TPS below %.1f" % threshold
		_:
			when = TRIGGER_NAMES[trigger].to_lower()
	var parts := PackedStringArray()
	if weekdays != ALL_DAYS:
		parts.append(days_text())
	parts.append(when)
	if window_enabled and not is_timed():
		parts.append("between %s–%s" % [window_start, window_end])
	if state_filter != StateFilter.ANY:
		parts.append("(%s)" % STATE_FILTER_NAMES[state_filter].to_lower())
	var s := " ".join(parts)
	return s.substr(0, 1).to_upper() + s.substr(1)


func describe_action() -> String:
	match action:
		Action.COMMAND:
			return "run \"/%s\"" % text.strip_edges().trim_prefix("/")
		Action.BROADCAST:
			return "say \"%s\"" % text.strip_edges()
		Action.NOTIFY:
			return "notify \"%s\"" % text.strip_edges()
	var s := ACTION_NAMES[action].to_lower()
	if delay_seconds > 0:
		s += " after %s" % Fmt.duration(delay_seconds)
	return s


func days_text() -> String:
	if weekdays == ALL_DAYS:
		return "Every day"
	if weekdays == 0b0111110:
		return "Weekdays"
	if weekdays == 0b1000001:
		return "Weekends"
	var names := PackedStringArray()
	for d in [1, 2, 3, 4, 5, 6, 0]:
		if weekdays & (1 << d):
			names.append(DAY_NAMES[d])
	return ", ".join(names) if not names.is_empty() else "Never"


func allows_day(local_unix: int) -> bool:
	var day: int = Time.get_datetime_dict_from_unix_time(local_unix).weekday
	return weekdays & (1 << day) != 0


## True when [param now] (UTC unix) satisfies the day and time-window conditions.
func conditions_met(now: int) -> bool:
	var local := now + _bias()
	if not allows_day(local):
		return false
	if window_enabled and not is_timed():
		var minute := posmod(local, 86400) / 60
		var start := _minutes(window_start)
		var end := _minutes(window_end)
		if start <= end:
			return minute >= start and minute < end
		return minute >= start or minute < end
	return true


## Next run strictly after [param now] for timed triggers, or -1. Interval runs are
## aligned to [param base]; time-of-day runs skip days that are not allowed.
func next_run_after(now: int, base: int) -> int:
	match trigger:
		Trigger.INTERVAL:
			var step := maxi(interval_minutes, 1) * 60
			var t := base if base > now else base + ((now - base) / step + 1) * step
			for i in 10080:  # Skip disallowed days (at most a week of steps).
				if allows_day(t + _bias()):
					return t
				t += step
			return -1
		Trigger.TIME:
			if weekdays & ALL_DAYS == 0:
				return -1
			var bias := _bias()
			var local_now := now + bias
			var target := local_now - posmod(local_now, 86400) + _minutes(time_of_day) * 60
			if target <= local_now:
				target += 86400
			for i in 8:
				if allows_day(target):
					return target - bias
				target += 86400
	return -1


func to_dict() -> Dictionary:
	return {
		"enabled": enabled, "label": label, "trigger": trigger, "time_of_day": time_of_day,
		"weekdays": weekdays, "interval_minutes": interval_minutes, "threshold": threshold,
		"window_enabled": window_enabled, "window_start": window_start, "window_end": window_end,
		"state_filter": state_filter, "action": action, "text": text, "warn_players": warn_players,
		"delay_seconds": delay_seconds, "wake_computer": wake_computer,
	}


static func from_dict(d: Dictionary) -> EventRule:
	var r := EventRule.new()
	r.enabled = bool(d.get("enabled", true))
	r.label = str(d.get("label", ""))
	r.trigger = clampi(int(d.get("trigger", 0)), 0, Trigger.size() - 1) as Trigger
	r.time_of_day = str(d.get("time_of_day", "18:00"))
	r.weekdays = int(d.get("weekdays", ALL_DAYS)) & ALL_DAYS
	r.interval_minutes = maxi(int(d.get("interval_minutes", 60)), 1)
	r.threshold = float(d.get("threshold", 15.0))
	r.window_enabled = bool(d.get("window_enabled", false))
	r.window_start = str(d.get("window_start", "08:00"))
	r.window_end = str(d.get("window_end", "23:00"))
	r.state_filter = clampi(int(d.get("state_filter", 0)), 0, StateFilter.size() - 1) as StateFilter
	r.action = clampi(int(d.get("action", 0)), 0, Action.size() - 1) as Action
	r.text = str(d.get("text", ""))
	r.warn_players = bool(d.get("warn_players", true))
	r.delay_seconds = maxi(int(d.get("delay_seconds", 0)), 0)
	# Starting a server at a set time only makes sense if the computer is awake, so Start
	# events wake it unless told otherwise.
	r.wake_computer = bool(d.get("wake_computer", r.action == Action.START))
	return r


## Converts a legacy scheduled task into an equivalent event.
static func from_schedule(s: ScheduleEntry) -> EventRule:
	var r := EventRule.new()
	r.enabled = s.enabled
	r.trigger = Trigger.TIME if s.mode == ScheduleEntry.Mode.DAILY else Trigger.INTERVAL
	r.time_of_day = s.time_of_day
	r.interval_minutes = s.interval_minutes
	r.warn_players = s.warn_players
	match s.kind:
		ScheduleEntry.Kind.COMMAND:
			r.action = Action.COMMAND
			r.text = s.command
		ScheduleEntry.Kind.BACKUP:
			r.action = Action.BACKUP_WORLD
		_:
			r.action = Action.RESTART
	return r


## Ready-made rules offered by the "Add event" menu: [name, dictionary].
static func templates() -> Array:
	return [
		["Start at a time", {"trigger": Trigger.TIME, "time_of_day": "18:00", "action": Action.START}],
		["Stop at a time", {"trigger": Trigger.TIME, "time_of_day": "23:00", "action": Action.STOP}],
		["Restart daily", {"trigger": Trigger.TIME, "time_of_day": "04:00", "action": Action.RESTART}],
		["Stop when empty", {"trigger": Trigger.SERVER_EMPTY, "threshold": 15.0, "action": Action.STOP}],
		["Start when Server Manager opens", {"trigger": Trigger.APP_STARTED, "action": Action.START}],
		["Back up every 6 hours", {"trigger": Trigger.INTERVAL, "interval_minutes": 360, "action": Action.BACKUP_WORLD}],
		["Welcome joining players", {"trigger": Trigger.PLAYER_JOINED, "action": Action.BROADCAST, "text": "Welcome!"}],
		["Notify when a player joins", {"trigger": Trigger.PLAYER_JOINED, "action": Action.NOTIFY, "text": "Someone joined {server} ({players} online)"}],
		["Restart when lagging", {"trigger": Trigger.TPS_BELOW, "threshold": 12.0, "action": Action.RESTART}],
		["Back up before sleep", {"trigger": Trigger.SYSTEM_SLEEP, "action": Action.BACKUP_WORLD}],
		["Custom event", {}],
	]


static func from_template(values: Dictionary) -> EventRule:
	var d := EventRule.new().to_dict()
	d.erase("wake_computer")  # Let from_dict pick the per-action default unless given.
	d.merge(values, true)
	return from_dict(d)


static func _minutes(hhmm: String) -> int:
	var parts := hhmm.strip_edges().split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return 0
	return clampi(parts[0].to_int(), 0, 23) * 60 + clampi(parts[1].to_int(), 0, 59)


static func _bias() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60
