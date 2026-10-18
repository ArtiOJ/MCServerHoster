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
## Running in tests or with `-- --no-autostart` skips auto-starting servers.
var autostart_enabled := true
## `-- --profile=<name>` keeps a separate settings file (used by integration tests).
var settings_path := DEFAULT_SETTINGS_PATH


func _ready() -> void:
	servers_root = _default_servers_root()
	var args := OS.get_cmdline_user_args()
	autostart_enabled = not args.has("--no-autostart")
	for arg in args:
		if arg.begins_with("--profile="):
			settings_path = "user://settings-%s.json" % Fmt.slugify(arg.get_slice("=", 1))
	load_settings()


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


## Creates or removes the XDG autostart entry to match [member start_at_login].
func apply_autostart() -> Error:
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
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	if home == "":
		return ProjectSettings.globalize_path("user://servers")
	return home.path_join("MinecraftServers")
