extends Node
## App-wide user notifications. UI listens to [signal notified] and shows toasts;
## depending on Preferences, messages are also shown as desktop notifications
## through `notify-send` (freedesktop notifications) or, on Windows, as toasts.

signal notified(message: String, level: Level)

enum Level { INFO, SUCCESS, WARNING, ERROR }
## What a notification is about; each category can be toggled in Preferences.
enum Category { GENERAL, CRASH, SERVER_STATE, PLAYERS, WAKE, BACKUP, UPDATE, POWER, EVENT, REMOTE }

## Settings keys per category (see AppSettings.DEFAULT_NOTIFY_CATEGORIES). GENERAL has no toggle.
const CATEGORY_KEYS: PackedStringArray = ["", "crash", "server_state", "players", "wake", "backup", "update", "power", "event", "remote"]
const APP_NAME := "Server Manager"
## Identical messages are delivered to the desktop at most once in this window.
const RATE_LIMIT_MS := 10000

## Test hook: -1 = ask the window manager, 0 = treat as unfocused, 1 = treat as focused.
var focus_override := -1

var _notify_send := ""
var _last_sent := {}


func _ready() -> void:
	_notify_send = PlatformBackend.find_in_path("notify-send")


func info(message: String, category := Category.GENERAL, title := "") -> void:
	notify(message, Level.INFO, category, title)


func success(message: String, category := Category.GENERAL, title := "") -> void:
	notify(message, Level.SUCCESS, category, title)


func warn(message: String, category := Category.GENERAL, title := "") -> void:
	push_warning(message)
	notify(message, Level.WARNING, category, title)


func error(message: String, category := Category.GENERAL, title := "") -> void:
	printerr(message)
	notify(message, Level.ERROR, category, title)


## Shows [param message] as a toast and, if the settings allow it, on the desktop.
## [param title] defaults to the app name; servers pass their display name.
func notify(message: String, level := Level.INFO, category := Category.GENERAL, title := "") -> void:
	# Player traffic can be chatty, so it only produces toasts when its category is on.
	if category != Category.PLAYERS or category_enabled(category):
		notified.emit(message, level)
	# Headless runs (tests, scripts) never reach the desktop unless a test opts in via focus_override.
	if DisplayServer.get_name() == "headless" and focus_override < 0:
		return
	if should_deliver(AppSettings.desktop_notifications, AppSettings.notify_when, AppSettings.notify_categories,
			category, level, _is_focused()):
		_send_desktop(title if title != "" else APP_NAME, message, level, category)


func is_desktop_available() -> bool:
	return _notify_send != "" or OS.get_name() == "Windows"


func category_enabled(category: Category) -> bool:
	var key := CATEGORY_KEYS[category]
	return key == "" or bool(AppSettings.notify_categories.get(key, true))


## Sends a desktop notification regardless of the category settings (Preferences "Send test").
func send_test() -> bool:
	return _send_desktop(APP_NAME, "This is how Server Manager notifications look.", Level.INFO, Category.GENERAL, true)


## Pure decision logic (unit-tested): should a notification reach the desktop?
static func should_deliver(enabled: bool, when: int, categories: Dictionary, category: Category, level: Level, focused: bool) -> bool:
	if not enabled or when == AppSettings.NotifyWhen.NEVER:
		return false
	if when == AppSettings.NotifyWhen.UNFOCUSED and focused:
		return false
	match category:
		Category.GENERAL:
			# Plain UI feedback ("Copied…", "Saved…") only matters on the desktop when something went wrong.
			return level == Level.WARNING or level == Level.ERROR
		Category.BACKUP:
			# Failed backups are always worth knowing about; successes follow the toggle.
			return level == Level.ERROR or bool(categories.get("backup", true))
	return bool(categories.get(CATEGORY_KEYS[category], true))


## Arguments for notify-send (unit-tested).
static func build_command(title: String, body: String, level: Level, category: Category, icon := "") -> PackedStringArray:
	var urgency := "normal"
	if category == Category.CRASH and level == Level.ERROR:
		urgency = "critical"
	elif category == Category.PLAYERS:
		urgency = "low"
	var args := PackedStringArray(["--app-name=" + APP_NAME, "--urgency=" + urgency])
	if icon != "":
		args.append("--icon=" + icon)
	args.append_array(["--", title, body])
	return args


## PowerShell that shows a Windows toast (as Windows PowerShell, which every Windows
## 10/11 has registered for notifications). Text goes in as XML-escaped literals.
static func windows_toast_script(title: String, body: String) -> String:
	var xml := "<toast><visual><binding template='ToastGeneric'><text>%s</text><text>%s</text></binding></visual></toast>" % [
			title.xml_escape(true), body.xml_escape(true)]
	return "\n".join([
		"[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null",
		"[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null",
		"$xml = New-Object Windows.Data.Xml.Dom.XmlDocument",
		"$xml.LoadXml('%s')" % xml.replace("'", "''"),
		"$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe'",
		"[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))",
	])


## True when this message was delivered within the rate-limit window; records it otherwise.
func is_rate_limited(key: String, now_msec: int) -> bool:
	var last: int = _last_sent.get(key, -RATE_LIMIT_MS - 1)
	if now_msec - last < RATE_LIMIT_MS:
		return true
	_last_sent[key] = now_msec
	return false


func _send_desktop(title: String, body: String, level: Level, category: Category, bypass_rate_limit := false) -> bool:
	if not is_desktop_available():
		return false
	if not bypass_rate_limit and is_rate_limited(title + "\n" + body, Time.get_ticks_msec()):
		return false
	if OS.get_name() == "Windows":
		var script := windows_toast_script(title, body)
		return OS.create_process("powershell.exe", WindowsBackend.POWERSHELL_ARGS + PackedStringArray(["-WindowStyle", "Hidden",
				"-EncodedCommand", Marshalls.raw_to_base64(script.to_utf16_buffer())])) > 0
	var icon := "" if OS.has_feature("template") else ProjectSettings.globalize_path("res://icon.svg")
	return OS.create_process(_notify_send, build_command(title, body, level, category, icon)) > 0


func _is_focused() -> bool:
	if focus_override >= 0:
		return focus_override == 1
	return DisplayServer.window_is_focused() and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MINIMIZED
