class_name ServerConfig
extends Resource
## Everything the manager knows about one server. Persisted as JSON in
## `<server dir>/.manager/instance.json` (JSON rather than .tres so a copied
## server folder can never smuggle in executable script resources).

enum JvmPreset { PAPER_RECOMMENDED, AIKAR, NONE }

const JVM_PRESET_NAMES := ["Paper recommended", "Aikar's flags", "None (heap only)"]
const META_DIR := ".manager"
const META_FILE := "instance.json"
const FORMAT_VERSION := 1

## Aikar's G1 flags (https://docs.papermc.io/paper/aikars-flags) for heaps up to 12 GB.
const AIKAR_FLAGS: PackedStringArray = [
	"-XX:+UseG1GC", "-XX:+ParallelRefProcEnabled", "-XX:MaxGCPauseMillis=200",
	"-XX:+UnlockExperimentalVMOptions", "-XX:+DisableExplicitGC", "-XX:+AlwaysPreTouch",
	"-XX:G1NewSizePercent=30", "-XX:G1MaxNewSizePercent=40", "-XX:G1HeapRegionSize=8M",
	"-XX:G1ReservePercent=20", "-XX:G1HeapWastePercent=5", "-XX:G1MixedGCCountTarget=4",
	"-XX:InitiatingHeapOccupancyPercent=15", "-XX:G1MixedGCLiveThresholdPercent=90",
	"-XX:G1RSetUpdatingPauseTimePercent=5", "-XX:SurvivorRatio=32", "-XX:+PerfDisableSharedMem",
	"-XX:MaxTenuringThreshold=1", "-Dusing.aikars.flags=https://mcflags.emc.gs", "-Daikars.new.flags=true",
]
## Replacements Aikar recommends once the heap exceeds 12 GB.
const AIKAR_LARGE_HEAP := {
	"-XX:G1NewSizePercent=30": "-XX:G1NewSizePercent=40",
	"-XX:G1MaxNewSizePercent=40": "-XX:G1MaxNewSizePercent=50",
	"-XX:G1HeapRegionSize=8M": "-XX:G1HeapRegionSize=16M",
	"-XX:G1ReservePercent=20": "-XX:G1ReservePercent=15",
	"-XX:InitiatingHeapOccupancyPercent=15": "-XX:InitiatingHeapOccupancyPercent=20",
}

@export var id := ""
@export var display_name := "New Server"
@export var color := Color("3fb97f")
## Absolute path of the server folder. Derived from where the config was loaded; not serialized.
@export var directory := ""
@export var created_unix := 0

@export_group("Software")
@export var mc_version := ""
@export var paper_build := 0
@export var build_channel := "STABLE"
@export var jar_file := "paper.jar"
@export var eula_accepted := false

@export_group("Java")
## Explicit java executable; empty selects automatically from [member java_min_version].
@export var java_path := ""
@export var java_min_version := 21
@export var jvm_preset: JvmPreset = JvmPreset.PAPER_RECOMMENDED
## Flags Paper recommended for this version (from the download API).
@export var recommended_flags := PackedStringArray()
@export var extra_jvm_args := ""
@export var extra_server_args := ""

@export_group("Resources")
@export var ram_min_mb := 1024
@export var ram_max_mb := 4096
## Enforce a hard memory ceiling (heap + JVM overhead) through a cgroup.
@export var memory_hard_cap := false
## Cores the JVM is told it has (0 = all).
@export var cpu_cores := 0
## Optional CPU list to pin the process to, e.g. "0-3" or "0,2,4".
@export var cpu_affinity := ""
## CPU quota in percent of one core (0 = unlimited, 200 = two full cores).
@export var cpu_quota_pct := 0
## Process niceness 0..19 (higher = lower priority).
@export var nice_level := 0

@export_group("Network")
@export var port := 25565
@export var rcon_port := 0
@export var rcon_password := ""

@export_group("Automation")
@export var auto_start := false
@export var auto_restart := true
@export var max_restarts := 3
@export var restart_window_sec := 600
@export var stop_timeout_sec := 60
## Automation rules (triggers → actions). Older configs' scheduled tasks are migrated into these.
@export var events: Array[EventRule] = []

@export_group("Game rules")
## Game rule changes waiting to be applied on the next start (catalog id -> value).
@export var pending_gamerules := {}
## Last game rule values seen on the running server (catalog id -> value).
@export var known_gamerules := {}

@export_group("Temporary run")
## Folder of a temporary copy that is running or waiting for a keep/discard decision ("" = none).
@export var temp_run_dir := ""

@export_group("Backups")
@export var backup_retention := 10
@export var backup_full := false


func meta_dir() -> String:
	return directory.path_join(META_DIR)


func jar_path(dir := "") -> String:
	return (dir if dir != "" else directory).path_join(jar_file)


func properties_path() -> String:
	return directory.path_join("server.properties")


## Ceiling for the cgroup memory limit: heap plus generous room for metaspace,
## thread stacks, direct buffers and the code cache.
func hard_cap_mb() -> int:
	return ram_max_mb + maxi(768, int(ram_max_mb * 0.25))


func build_jvm_args() -> PackedStringArray:
	var args := PackedStringArray()
	args.append("-Xms%dM" % clampi(ram_min_mb, 128, ram_max_mb))
	args.append("-Xmx%dM" % ram_max_mb)
	if cpu_cores > 0:
		args.append("-XX:ActiveProcessorCount=%d" % cpu_cores)
	match jvm_preset:
		JvmPreset.PAPER_RECOMMENDED:
			args.append_array(recommended_flags if not recommended_flags.is_empty() else _aikar_flags())
		JvmPreset.AIKAR:
			args.append_array(_aikar_flags())
	# Plain line-oriented console output on the pipe, keeping colours as ANSI codes.
	args.append("-Dterminal.jline=false")
	args.append("-Dterminal.ansi=true")
	args.append_array(Fmt.split_args(extra_jvm_args))
	return args


func build_server_args() -> PackedStringArray:
	var args := PackedStringArray(["-jar", jar_file, "--nogui"])
	args.append_array(Fmt.split_args(extra_server_args))
	return args


func _aikar_flags() -> PackedStringArray:
	if ram_max_mb <= 12 * 1024:
		return AIKAR_FLAGS
	var flags := PackedStringArray()
	for f in AIKAR_FLAGS:
		flags.append(AIKAR_LARGE_HEAP.get(f, f))
	return flags


func to_dict() -> Dictionary:
	var event_dicts: Array = []
	for e in events:
		event_dicts.append(e.to_dict())
	return {
		"format": FORMAT_VERSION,
		"id": id, "display_name": display_name, "color": color.to_html(false), "created_unix": created_unix,
		"mc_version": mc_version, "paper_build": paper_build, "build_channel": build_channel,
		"jar_file": jar_file, "eula_accepted": eula_accepted,
		"java_path": java_path, "java_min_version": java_min_version, "jvm_preset": jvm_preset,
		"recommended_flags": Array(recommended_flags), "extra_jvm_args": extra_jvm_args,
		"extra_server_args": extra_server_args,
		"ram_min_mb": ram_min_mb, "ram_max_mb": ram_max_mb, "memory_hard_cap": memory_hard_cap,
		"cpu_cores": cpu_cores, "cpu_affinity": cpu_affinity, "cpu_quota_pct": cpu_quota_pct,
		"nice_level": nice_level,
		"port": port, "rcon_port": rcon_port, "rcon_password": rcon_password,
		"auto_start": auto_start, "auto_restart": auto_restart, "max_restarts": max_restarts,
		"restart_window_sec": restart_window_sec, "stop_timeout_sec": stop_timeout_sec,
		"events": event_dicts,
		"backup_retention": backup_retention, "backup_full": backup_full,
		"pending_gamerules": pending_gamerules, "known_gamerules": known_gamerules,
		"temp_run_dir": temp_run_dir,
	}


static func from_dict(d: Dictionary, dir: String) -> ServerConfig:
	var c := ServerConfig.new()
	c.directory = dir
	c.id = str(d.get("id", Fmt.slugify(dir.get_file())))
	c.display_name = str(d.get("display_name", dir.get_file()))
	c.color = Color.from_string(str(d.get("color", "3fb97f")), Color("3fb97f"))
	c.created_unix = int(d.get("created_unix", 0))
	c.mc_version = str(d.get("mc_version", ""))
	c.paper_build = int(d.get("paper_build", 0))
	c.build_channel = str(d.get("build_channel", "STABLE"))
	c.jar_file = str(d.get("jar_file", "paper.jar"))
	c.eula_accepted = bool(d.get("eula_accepted", false))
	c.java_path = str(d.get("java_path", ""))
	c.java_min_version = int(d.get("java_min_version", 21))
	c.jvm_preset = clampi(int(d.get("jvm_preset", 0)), 0, JvmPreset.size() - 1) as JvmPreset
	c.recommended_flags = PackedStringArray(d.get("recommended_flags", []))
	c.extra_jvm_args = str(d.get("extra_jvm_args", ""))
	c.extra_server_args = str(d.get("extra_server_args", ""))
	c.ram_max_mb = maxi(int(d.get("ram_max_mb", 4096)), 512)
	c.ram_min_mb = clampi(int(d.get("ram_min_mb", 1024)), 128, c.ram_max_mb)
	c.memory_hard_cap = bool(d.get("memory_hard_cap", false))
	c.cpu_cores = maxi(int(d.get("cpu_cores", 0)), 0)
	c.cpu_affinity = str(d.get("cpu_affinity", ""))
	c.cpu_quota_pct = maxi(int(d.get("cpu_quota_pct", 0)), 0)
	c.nice_level = clampi(int(d.get("nice_level", 0)), 0, 19)
	c.port = clampi(int(d.get("port", 25565)), 1, 65535)
	c.rcon_port = clampi(int(d.get("rcon_port", 0)), 0, 65535)
	c.rcon_password = str(d.get("rcon_password", ""))
	c.auto_start = bool(d.get("auto_start", false))
	c.auto_restart = bool(d.get("auto_restart", true))
	c.max_restarts = maxi(int(d.get("max_restarts", 3)), 0)
	c.restart_window_sec = maxi(int(d.get("restart_window_sec", 600)), 30)
	c.stop_timeout_sec = maxi(int(d.get("stop_timeout_sec", 60)), 5)
	var rules: Array[EventRule] = []
	if d.has("events"):
		for e in d.events:
			if e is Dictionary:
				rules.append(EventRule.from_dict(e))
	else:
		for s in d.get("schedules", []):
			if s is Dictionary:
				rules.append(EventRule.from_schedule(ScheduleEntry.from_dict(s)))
	c.events = rules
	c.backup_retention = maxi(int(d.get("backup_retention", 10)), 0)
	c.backup_full = bool(d.get("backup_full", false))
	c.pending_gamerules = _string_dict(d.get("pending_gamerules", {}))
	c.known_gamerules = _string_dict(d.get("known_gamerules", {}))
	c.temp_run_dir = str(d.get("temp_run_dir", ""))
	return c


static func _string_dict(value: Variant) -> Dictionary:
	var out := {}
	if value is Dictionary:
		for k in value:
			out[str(k)] = str(value[k])
	return out


## Writes the keys the manager owns (ports, RCON) into server.properties in [param dir]
## (defaults to the server folder).
func write_managed_properties(dir := "") -> Error:
	var path := (dir if dir != "" else directory).path_join("server.properties")
	var props := ServerProperties.load_file(path)
	props.set_value("server-port", port)
	props.set_value("query.port", port)
	props.set_value("enable-rcon", true)
	props.set_value("rcon.port", rcon_port)
	props.set_value("rcon.password", rcon_password)
	props.set_value("broadcast-rcon-to-ops", false)
	return props.save_file(path)


func save() -> Error:
	var err := DirAccess.make_dir_recursive_absolute(meta_dir())
	if err != OK:
		return err
	var path := meta_dir().path_join(META_FILE)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	return DirAccess.rename_absolute(tmp, path)


## Loads the config stored in [param dir], or returns null if there is none.
static func load_from_dir(dir: String) -> ServerConfig:
	var path := dir.path_join(META_DIR).path_join(META_FILE)
	if not FileAccess.file_exists(path):
		return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_warning("Invalid server config: " + path)
		return null
	return from_dict(data, dir)
