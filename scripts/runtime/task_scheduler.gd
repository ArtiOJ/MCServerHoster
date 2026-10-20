class_name TaskScheduler
extends Timer
## Event engine for one server. Evaluates the server's [EventRule]s once per second
## for timed and condition-based triggers, and reacts to lifecycle triggers pushed
## in through [method fire] (server online/stopped/crashed, players, app start,
## system sleep/wake). Before timed stops and restarts it counts down in chat.

signal rule_ran(rule: EventRule)

## Seconds before a timed stop/restart at which online players are warned.
const WARNING_OFFSETS: Array[int] = [600, 300, 60, 30, 10, 5]
## TPS must stay below the threshold this long before TPS_BELOW fires.
const TPS_SUSTAIN_SEC := 60

var instance: ServerInstance

## EventRule -> next run (unix seconds) for timed rules
var _next_runs := {}
## EventRule -> offsets already announced for the current run
var _warned := {}
## Rules whose edge-triggered condition already fired (re-armed when it clears).
var _latched := {}
## Reference point for interval rules (server start or app start).
var _interval_base := 0
var _empty_since := 0
var _low_tps_since := 0
var _last_player_count := 0


func _ready() -> void:
	instance = get_parent() as ServerInstance
	_interval_base = int(Time.get_unix_time_from_system())
	timeout.connect(_tick)
	start()


## Recompute everything, e.g. after the rule list was edited.
func reset() -> void:
	_next_runs.clear()
	_warned.clear()
	_latched.clear()


func on_server_started() -> void:
	_interval_base = int(Time.get_unix_time_from_system())
	_empty_since = 0
	_low_tps_since = 0
	_last_player_count = 0
	reset()


## Next run time of a timed rule (unix seconds), or -1.
func next_run_of(rule: EventRule) -> int:
	if not rule.is_timed():
		return -1
	if not _next_runs.has(rule):
		_next_runs[rule] = rule.next_run_after(int(Time.get_unix_time_from_system()), _interval_base)
	return _next_runs[rule]


## Runs every enabled rule listening for [param trigger] whose conditions hold.
func fire(trigger: EventRule.Trigger) -> void:
	if instance == null or instance.config == null:
		return
	var now := int(Time.get_unix_time_from_system())
	for rule in instance.config.events:
		if rule.enabled and rule.trigger == trigger and _conditions_ok(rule, now):
			_run(rule)


func _tick() -> void:
	if instance == null or instance.config == null:
		return
	var now := int(Time.get_unix_time_from_system())
	_track_conditions(now)
	for rule in instance.config.events:
		if not rule.enabled:
			continue
		match rule.trigger:
			EventRule.Trigger.TIME, EventRule.Trigger.INTERVAL:
				_tick_timed(rule, now)
			EventRule.Trigger.SERVER_EMPTY:
				_edge(rule, now, _empty_since > 0 and now - _empty_since >= int(rule.threshold * 60.0))
			EventRule.Trigger.PLAYERS_AT_LEAST:
				_edge(rule, now, instance.is_online() and instance.players.size() >= int(rule.threshold))
			EventRule.Trigger.TPS_BELOW:
				_edge(rule, now, _low_tps_since > 0 and now - _low_tps_since >= TPS_SUSTAIN_SEC and instance.tps < rule.threshold)


func _tick_timed(rule: EventRule, now: int) -> void:
	var due := next_run_of(rule)
	if due < 0:
		return
	var warns := rule.warn_players and (rule.action == EventRule.Action.STOP or rule.action == EventRule.Action.RESTART)
	if warns and instance.is_online() and not instance.players.is_empty():
		_announce(rule, due - now)
	if now >= due:
		# A run missed by more than a few minutes (e.g. the computer was asleep) is skipped.
		if now - due < 300 and _conditions_ok(rule, now):
			_run(rule, true)
		_next_runs[rule] = rule.next_run_after(now, _interval_base)
		_warned.erase(rule)


## Fires a condition rule once when [param active] becomes true; re-arms when it turns false.
func _edge(rule: EventRule, now: int, active: bool) -> void:
	if not active:
		_latched.erase(rule)
		return
	if _latched.has(rule):
		return
	_latched[rule] = true
	if _conditions_ok(rule, now):
		_run(rule)


func _track_conditions(now: int) -> void:
	var online := instance.is_online()
	var count := instance.players.size()
	if online and count == 0:
		if _empty_since == 0:
			_empty_since = now
	else:
		_empty_since = 0
	if online and instance.tps >= 0.0 and instance.tps < 20.0:
		if _low_tps_since == 0:
			_low_tps_since = now
	else:
		_low_tps_since = 0
	_last_player_count = count


func _conditions_ok(rule: EventRule, now: int) -> bool:
	if not rule.conditions_met(now):
		return false
	match rule.state_filter:
		EventRule.StateFilter.ONLINE:
			return instance.is_online()
		EventRule.StateFilter.OFFLINE:
			return not instance.is_process_alive()
	return true


func _announce(rule: EventRule, remaining: int) -> void:
	var done: Array = _warned.get(rule, [])
	for offset in WARNING_OFFSETS:
		if remaining <= offset and remaining > offset - 2 and not done.has(offset):
			done.append(offset)
			instance.send_command("say Scheduled %s in %s." % [_verb(rule), _span(offset)], false)
	_warned[rule] = done


## Performs a rule's action. [param pre_warned] is true when a timed countdown already ran.
func _run(rule: EventRule, pre_warned := false) -> void:
	rule_ran.emit(rule)
	instance.log_system("Event: " + rule.describe())
	if rule.delay_seconds > 0:
		await get_tree().create_timer(rule.delay_seconds).timeout
	match rule.action:
		EventRule.Action.START:
			if instance.is_busy() or instance.is_temporary():
				return
			instance.start()
		EventRule.Action.STOP, EventRule.Action.RESTART:
			if not instance.is_online():
				if rule.action == EventRule.Action.RESTART and not instance.is_busy() and not instance.is_temporary():
					instance.start()
				return
			if rule.warn_players and not pre_warned and not instance.players.is_empty():
				instance.send_command("say Server %s in %d seconds." % [_verb(rule), EventRule.WARNING_SECONDS], false)
				await get_tree().create_timer(EventRule.WARNING_SECONDS).timeout
				if not instance.is_online():
					return
			if rule.action == EventRule.Action.STOP:
				instance.stop()
			else:
				instance.restart()
		EventRule.Action.COMMAND:
			if instance.is_online() and rule.text.strip_edges() != "":
				instance.send_command(rule.text.strip_edges().trim_prefix("/"), false)
		EventRule.Action.BROADCAST:
			if instance.is_online() and rule.text.strip_edges() != "":
				instance.send_command("say " + rule.text.strip_edges(), false)
		EventRule.Action.BACKUP_WORLD, EventRule.Action.BACKUP_FULL:
			instance.backups.create_backup(rule.action == EventRule.Action.BACKUP_FULL)
		EventRule.Action.NOTIFY:
			var message := expand_placeholders(rule.text.strip_edges(), instance)
			if message == "":
				message = rule.describe()
			Notifier.notify(message, Notifier.Level.INFO, Notifier.Category.EVENT, instance.config.display_name)
		EventRule.Action.WAKE_ON_JOIN_ON, EventRule.Action.WAKE_ON_JOIN_OFF:
			_set_wake_on_join(rule.action == EventRule.Action.WAKE_ON_JOIN_ON)
		EventRule.Action.SET_MOTD:
			_set_property("motd", rule.text.strip_edges())
		EventRule.Action.SET_SETTING:
			var setting := EventRule.parse_setting(rule.text)
			if setting.is_empty():
				instance.log_system("Event skipped: \"%s\" isn't a setting events can change (use setting=value)." % rule.text.strip_edges())
			else:
				_set_property(setting[0], setting[1])
		EventRule.Action.WHITELIST_ON, EventRule.Action.WHITELIST_OFF:
			var res: Dictionary = ServerOps.whitelist_set(instance, rule.action == EventRule.Action.WHITELIST_ON, ServerOps.LOCAL_CONTEXT)
			if not res.ok:
				instance.log_system("Event: %s" % res.error)
		EventRule.Action.ENABLE_PLUGIN, EventRule.Action.DISABLE_PLUGIN:
			var res := ServerOps.plugin_set_enabled(instance, rule.text.strip_edges(), rule.action == EventRule.Action.ENABLE_PLUGIN, ServerOps.LOCAL_CONTEXT)
			if not res.ok:
				instance.log_system("Event skipped: %s" % res.error)
			elif res.get("changed", false) and instance.is_process_alive():
				instance.log_system("The plugin change applies at the next restart.")
		EventRule.Action.SET_ASLEEP_MOTD:
			if instance.config.wake_motd != rule.text.strip_edges():
				instance.config.wake_motd = rule.text.strip_edges()
				instance.save_config()
				instance.log_system("Asleep MOTD set to \"%s\"." % instance.config.wake_motd)
		EventRule.Action.SLEEP_COMPUTER:
			instance.log_system("Putting the computer to sleep.")
			Notifier.info("%s: putting the computer to sleep." % instance.config.display_name, Notifier.Category.POWER, instance.config.display_name)
			var res: Dictionary = await PowerManager.suspend_computer()
			if not res.ok:
				instance.log_system("The computer didn't go to sleep: %s." % res.message)


## Writes a server.properties value; the server reads it at its next start.
func _set_property(key: String, value: String) -> void:
	var props := instance.get_properties()
	if props.get_value(key, "") == value:
		return
	props.set_value(key, value)
	var err := props.save_file(instance.config.properties_path())
	if err != OK:
		instance.log_system("Could not update server.properties: %s" % error_string(err))
		return
	instance.log_system("Set %s to \"%s\"%s." % [key, value, " (applies at the next start)" if instance.is_process_alive() else ""])
	instance.data_changed.emit(&"settings")


## Turns the server's wake on join (listening for players while stopped) on or off.
func _set_wake_on_join(on: bool) -> void:
	if instance.config.wake_on_connect == on:
		return
	instance.config.wake_on_connect = on
	instance.save_config()
	instance.log_system("Wake on join turned %s." % ("on" if on else "off"))


## Puts wake on join where the timed on/off events last left it, for runs missed while the
## computer slept or the app was closed: the most recent past "Turn on/off wake on join"
## time-of-day event wins. Called when the app starts and after the computer wakes.
func catch_up_wake_on_join() -> void:
	if instance == null or instance.config == null:
		return
	var now := int(Time.get_unix_time_from_system())
	var latest := -1
	var latest_rule: EventRule = null
	for rule in instance.config.events:
		if not rule.enabled or rule.action not in [EventRule.Action.WAKE_ON_JOIN_ON, EventRule.Action.WAKE_ON_JOIN_OFF]:
			continue
		var t := rule.last_run_at_or_before(now)
		if t > latest:
			latest = t
			latest_rule = rule
	if latest_rule != null:
		_set_wake_on_join(latest_rule.action == EventRule.Action.WAKE_ON_JOIN_ON)


## Replaces {server} and {players} in event texts.
static func expand_placeholders(text: String, inst: ServerInstance) -> String:
	return text.replace("{server}", inst.config.display_name).replace("{players}", str(inst.players.size()))


static func _verb(rule: EventRule) -> String:
	return "restart" if rule.action == EventRule.Action.RESTART else "shutdown"


static func _span(seconds: int) -> String:
	if seconds >= 60:
		var m := seconds / 60
		return "%d minute%s" % [m, "" if m == 1 else "s"]
	return "%d seconds" % seconds
