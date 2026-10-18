extends Node
## Application-wide preferences, persisted to user://settings.json.

signal changed

enum ExitBehavior { ASK, STOP_ALL, MINIMIZE }

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
	}
	var f := FileAccess.open(settings_path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write settings: %s" % error_string(FileAccess.get_open_error()))
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	changed.emit()


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
