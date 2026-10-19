extends Node
## Application-wide preferences, persisted to user://settings.json.

signal changed

## DETACH quits the app and leaves servers running; they are re-attached on next launch.
enum ExitBehavior { ASK, STOP_ALL, MINIMIZE, DETACH }
## What happens when the computer tries to sleep while servers run (see PowerManager).
enum SleepPolicy { BLOCK_WHILE_PLAYERS, STOP_AND_SLEEP, BLOCK_WHILE_RUNNING, PAUSE }

const SLEEP_POLICY_NAMES: PackedStringArray = [
	"Block sleep while players are online", "Stop servers, then sleep",
	"Block sleep while any server runs", "Let it sleep (servers pause)",
]
const AUTOSTART_FILE := "server-manager.desktop"
## Windows: the per-user registry key of programs started at login.
const WINDOWS_RUN_KEY := "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
## When desktop notifications are shown (see Notifier).
enum NotifyWhen { ALWAYS, UNFOCUSED, NEVER }
const NOTIFY_WHEN_NAMES: PackedStringArray = ["Always", "When the window isn't focused", "Never"]
## Per-category desktop notification defaults (keys match Notifier.CATEGORY_KEYS).
## Backup failures are always shown; this toggle controls the success messages.
const DEFAULT_NOTIFY_CATEGORIES := {
	"crash": true, "server_state": false, "players": false, "wake": true,
	"backup": true, "update": true, "power": true, "event": true, "remote": true,
}

const DEFAULT_SETTINGS_PATH := "user://settings.json"

var servers_root := ""
var server_dirs := PackedStringArray()
var default_ram_mb := 4096
var console_max_lines := 5000
var exit_behavior: ExitBehavior = ExitBehavior.ASK
var check_updates_on_launch := true
var show_unstable_versions := false
var extra_java_paths := PackedStringArray()
var last_selected_server := ""
var sleep_policy: SleepPolicy = SleepPolicy.BLOCK_WHILE_PLAYERS
## Start servers that were stopped for sleep again after the computer wakes.
var restart_after_wake := true
## Launch Server Manager when the user logs in (XDG autostart entry).
var start_at_login := false
## Start with the window minimized (always the case when launched at login).
var start_minimized := false
## Wake the computer from sleep for events flagged "wake computer" (needs the wake helper).
var wake_for_events := true
## Experimental: wake on an incoming connection to a start-on-connect server (Wi-Fi WoWLAN).
var wake_on_connection := false
## LAN address the user confirmed is reserved for this computer in the router.
var reserved_lan_ip := ""
## Show notifications on the desktop (in addition to the in-app toasts).
var desktop_notifications := true
var notify_when: NotifyWhen = NotifyWhen.UNFOCUSED
## Category key -> enabled, see [constant DEFAULT_NOTIFY_CATEGORIES].
var notify_categories := DEFAULT_NOTIFY_CATEGORIES.duplicate()
## Server id -> newest Paper build already announced, so each update is notified once.
var notified_update_builds := {}
## Interface size (UI scale factor); 0 = automatic from the screen. See UiScale.
var ui_scale := 0.0
## Ports this app opened in the firewall (its own rules, safe to clean up later).
var firewall_app_ports := PackedInt32Array()
## Game ports managed servers used before (changed or deleted servers), so firewall rules
## left behind for them can be recognised as stale.
var previous_game_ports := PackedInt32Array()
## Running in tests or with `-- --no-autostart` skips auto-starting servers.
var autostart_enabled := true
## `-- --profile=<name>` keeps a separate settings file (used by integration tests).
var settings_path := DEFAULT_SETTINGS_PATH
## PID of another running Server Manager using the same settings profile, or -1.
## Two instances would fight over the same servers, so the second one must not start.
var other_instance_pid := -1
var _owns_lock := false


func _ready() -> void:
	servers_root = _default_servers_root()
	var args := OS.get_cmdline_user_args()
	autostart_enabled = not args.has("--no-autostart")
	for arg in args:
		if arg.begins_with("--profile="):
			settings_path = "user://settings-%s.json" % Fmt.slugify(arg.get_slice("=", 1))
	_acquire_instance_lock()
	load_settings()


func _exit_tree() -> void:
	if _owns_lock:
		DirAccess.remove_absolute(_lock_path())


func _lock_path() -> String:
	return settings_path.get_basename() + ".lock"


func _acquire_instance_lock() -> void:
	var path := _lock_path()
	if FileAccess.file_exists(path):
		var pid := FileAccess.get_file_as_string(path).strip_edges().to_int()
		var backend := PlatformBackend.get_current()
		var exe := backend.process_executable(pid) if pid > 0 and pid != OS.get_process_id() and backend.is_pid_alive(pid) else "-"
		# Windows paths aren't case-sensitive.
		var same := exe == "" or (exe.to_lower() == OS.get_executable_path().to_lower() if OS.get_name() == "Windows" else exe == OS.get_executable_path())
		if exe != "-" and same:
			other_instance_pid = pid
			return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(str(OS.get_process_id()))
		_owns_lock = true


## A per-profile file next to the settings file, e.g. "remote-access.json" becomes
## "user://remote-access-test.json" under `--profile=test`.
func profile_path(file_name: String) -> String:
	var suffix := settings_path.get_file().get_basename().trim_prefix("settings")
	return settings_path.get_base_dir().path_join(file_name.get_basename() + suffix + "." + file_name.get_extension())


## Writes [param text] to [param path] readable only by this user (secrets).
static func write_private(path: String, text: String) -> Error:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.close()
	FileAccess.set_unix_permissions(tmp, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	f = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	return DirAccess.rename_absolute(tmp, path)


func backups_root() -> String:
	return servers_root.path_join("_backups")


func load_settings() -> void:
	if not FileAccess.file_exists(settings_path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(settings_path))
	if not data is Dictionary:
		push_warning("Ignoring unreadable settings file")
		return
	servers_root = str(data.get("servers_root", servers_root))
	server_dirs = PackedStringArray(data.get("server_dirs", []))
	default_ram_mb = int(data.get("default_ram_mb", default_ram_mb))
	console_max_lines = clampi(int(data.get("console_max_lines", console_max_lines)), 500, 100000)
	exit_behavior = clampi(int(data.get("exit_behavior", exit_behavior)), 0, ExitBehavior.size() - 1) as ExitBehavior
	check_updates_on_launch = bool(data.get("check_updates_on_launch", check_updates_on_launch))
	show_unstable_versions = bool(data.get("show_unstable_versions", show_unstable_versions))
	extra_java_paths = PackedStringArray(data.get("extra_java_paths", []))
	last_selected_server = str(data.get("last_selected_server", ""))
	sleep_policy = clampi(int(data.get("sleep_policy", sleep_policy)), 0, SleepPolicy.size() - 1) as SleepPolicy
	restart_after_wake = bool(data.get("restart_after_wake", restart_after_wake))
	start_at_login = bool(data.get("start_at_login", start_at_login))
	start_minimized = bool(data.get("start_minimized", start_minimized))
	reserved_lan_ip = str(data.get("reserved_lan_ip", reserved_lan_ip))
	wake_for_events = bool(data.get("wake_for_events", wake_for_events))
	wake_on_connection = bool(data.get("wake_on_connection", wake_on_connection))
	desktop_notifications = bool(data.get("desktop_notifications", desktop_notifications))
	notify_when = clampi(int(data.get("notify_when", notify_when)), 0, NotifyWhen.size() - 1) as NotifyWhen
	notify_categories = DEFAULT_NOTIFY_CATEGORIES.duplicate()
	var saved_categories = data.get("notify_categories", {})
	if saved_categories is Dictionary:
		for key in saved_categories:
			if notify_categories.has(key):
				notify_categories[key] = bool(saved_categories[key])
	var saved_updates = data.get("notified_update_builds", {})
	notified_update_builds = saved_updates if saved_updates is Dictionary else {}
	ui_scale = clampf(float(data.get("ui_scale", ui_scale)), 0.0, 3.0)
	firewall_app_ports = PackedInt32Array(data.get("firewall_app_ports", []))
	previous_game_ports = PackedInt32Array(data.get("previous_game_ports", []))


func save_settings() -> void:
	var data := {
		"servers_root": servers_root,
		"server_dirs": Array(server_dirs),
		"default_ram_mb": default_ram_mb,
		"console_max_lines": console_max_lines,
		"exit_behavior": exit_behavior,
		"check_updates_on_launch": check_updates_on_launch,
		"show_unstable_versions": show_unstable_versions,
		"extra_java_paths": Array(extra_java_paths),
		"last_selected_server": last_selected_server,
		"sleep_policy": sleep_policy,
		"restart_after_wake": restart_after_wake,
		"start_at_login": start_at_login,
		"start_minimized": start_minimized,
		"reserved_lan_ip": reserved_lan_ip,
		"wake_for_events": wake_for_events,
		"wake_on_connection": wake_on_connection,
		"desktop_notifications": desktop_notifications,
		"notify_when": notify_when,
		"notify_categories": notify_categories,
		"notified_update_builds": notified_update_builds,
		"ui_scale": ui_scale,
		"firewall_app_ports": Array(firewall_app_ports),
		"previous_game_ports": Array(previous_game_ports),
	}
	var f := FileAccess.open(settings_path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write settings: %s" % error_string(FileAccess.get_open_error()))
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	changed.emit()


## True when this launch should begin minimized (setting, or launched at login).
func launched_minimized() -> bool:
	return start_minimized or OS.get_cmdline_user_args().has("--start-minimized")


## Creates or removes the login autostart entry to match [member start_at_login]: an XDG
## autostart file on Linux, the user's Run registry key on Windows.
func apply_autostart() -> Error:
	if OS.get_name() == "Windows":
		return _apply_windows_autostart()
	var config_home := OS.get_environment("XDG_CONFIG_HOME")
	if config_home == "":
		config_home = OS.get_environment("HOME").path_join(".config")
	var path := config_home.path_join("autostart").path_join(AUTOSTART_FILE)
	if not start_at_login:
		if FileAccess.file_exists(path):
			return DirAccess.remove_absolute(path)
		return OK
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var exec := PackedStringArray([_desktop_quote(OS.get_executable_path())])
	if not OS.has_feature("template"):
		# Running from source: launch the engine with this project.
		exec.append_array(["--path", _desktop_quote(ProjectSettings.globalize_path("res://").trim_suffix("/"))])
	exec.append_array(["--", "--start-minimized"])
	var icon := ProjectSettings.globalize_path("res://icon.svg") if not OS.has_feature("template") else ""
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string("\n".join([
		"[Desktop Entry]", "Type=Application", "Name=Server Manager",
		"Comment=Minecraft server manager (starts minimized)", "Exec=" + " ".join(exec),
		"Icon=" + icon, "Terminal=false", "X-GNOME-Autostart-enabled=true", "",
	]))
	return OK


func _apply_windows_autostart() -> Error:
	var script := "Remove-ItemProperty -Path '%s' -Name 'Server Manager' -ErrorAction SilentlyContinue; 'ok'" % WINDOWS_RUN_KEY
	if start_at_login:
		var command := "\"%s\"" % OS.get_executable_path().replace("/", "\\")
		if not OS.has_feature("template"):
			command += " --path \"%s\"" % ProjectSettings.globalize_path("res://").trim_suffix("/").replace("/", "\\")
		command += " -- --start-minimized"
		script = "Set-ItemProperty -Path '%s' -Name 'Server Manager' -Value '%s'; if ($?) { 'ok' }" % [WINDOWS_RUN_KEY, command.replace("'", "''")]
	return OK if WindowsBackend.run_powershell(script).ends_with("ok") else FAILED


static func _desktop_quote(arg: String) -> String:
	for c in " \t\"'\\$`":
		if arg.contains(c):
			return "\"" + arg.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$").replace("`", "\\`") + "\""
	return arg


func register_server_dir(dir: String) -> void:
	if not server_dirs.has(dir):
		server_dirs.append(dir)
		save_settings()


func unregister_server_dir(dir: String) -> void:
	var idx := server_dirs.find(dir)
	if idx >= 0:
		server_dirs.remove_at(idx)
		save_settings()


static func _default_servers_root() -> String:
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("HOME") if OS.get_name() == "Windows" else OS.get_environment("USERPROFILE")
	home = home.replace("\\", "/")
	if home == "":
		return ProjectSettings.globalize_path("user://servers")
	return home.path_join("MinecraftServers")
