extends TestCase


func _config() -> ServerConfig:
	var c := ServerConfig.new()
	c.id = "test"
	c.directory = "/srv/mc/test"
	c.ram_min_mb = 1024
	c.ram_max_mb = 4096
	c.recommended_flags = PackedStringArray(["-XX:+UseG1GC"])
	return c


func test_round_trip() -> void:
	var c := _config()
	c.display_name = "Survival"
	c.cpu_quota_pct = 250
	c.cpu_affinity = "0-3"
	var e := EventRule.new()
	e.action = EventRule.Action.COMMAND
	e.text = "say hi"
	e.weekdays = 0b0100010
	c.events.append(e)
	var back := ServerConfig.from_dict(JSON.parse_string(JSON.stringify(c.to_dict())), c.directory)
	check_eq(back.display_name, "Survival", "name")
	check_eq(back.cpu_quota_pct, 250, "quota")
	check_eq(back.cpu_affinity, "0-3", "affinity")
	check_eq(back.events.size(), 1, "events")
	check_eq(back.events[0].text, "say hi", "event text")
	check_eq(back.events[0].weekdays, 0b0100010, "event weekdays")
	check_eq(back.recommended_flags, PackedStringArray(["-XX:+UseG1GC"]), "flags")


func test_jvm_args() -> void:
	var c := _config()
	c.cpu_cores = 2
	c.extra_jvm_args = "-Dfoo=\"a b\" -Dbar=1"
	var args := c.build_jvm_args()
	check_eq(args[0], "-Xms1024M", "xms")
	check_eq(args[1], "-Xmx4096M", "xmx")
	check(args.has("-XX:ActiveProcessorCount=2"), "cpu cores flag")
	check(args.has("-XX:+UseG1GC"), "recommended flags")
	check(args.has("-Dfoo=a b"), "quoted extra arg")
	c.jvm_preset = ServerConfig.JvmPreset.AIKAR
	c.ram_max_mb = 16384
	check(c.build_jvm_args().has("-XX:G1HeapRegionSize=16M"), "aikar large heap variant")


func test_linux_launch_command() -> void:
	if OS.get_name() != "Linux":
		return
	var backend := LinuxBackend.new()
	var c := _config()
	var plain := backend.build_launch_command(c, "/usr/bin/java")
	check(str(plain.path).ends_with("env"), "env wrapper first when no limits: " + str(plain.path))
	check_eq(plain.args[0], "-C", "chdir flag")
	check_eq(plain.args[1], "/srv/mc/test", "chdir dir")
	check(plain.args.has("--nogui"), "nogui")
	c.cpu_quota_pct = 150
	c.memory_hard_cap = true
	c.cpu_affinity = "0-1"
	c.nice_level = 5
	var limited := backend.build_launch_command(c, "/usr/bin/java")
	if backend.supports_cpu_quota():
		check(str(limited.path).ends_with("systemd-run"), "systemd-run wrapper")
		check(limited.args.has("CPUQuota=150%"), "quota prop")
		check(limited.args.has("MemoryMax=%dM" % c.hard_cap_mb()), "memory cap prop")
	if backend.supports_affinity():
		check(limited.args.has("0-1"), "taskset cpu list")
	var java_idx := Array(limited.args).find("/usr/bin/java")
	check(java_idx > 0 and limited.args[java_idx + 1] == "-Xms1024M", "java follows wrappers")


func test_slug_and_args() -> void:
	check_eq(Fmt.slugify("My Cool Server!!"), "my-cool-server", "slug")
	check_eq(Fmt.slugify("***"), "server", "slug fallback")
	check_eq(Fmt.split_args("a 'b c'  d"), PackedStringArray(["a", "b c", "d"]), "split args")
	check_eq(Fmt.megabytes(6144), "6 GB", "megabytes")
	check_eq(Fmt.duration(3725), "1h 2m", "duration")


func test_execute_passes_arguments_literally() -> void:
	# Godot's OS.execute goes through a shell; PlatformBackend.execute must neutralise it.
	var tricky := ["a $HOME b", "x \"$1\" y", "back\\slash", "tick `id` z", "single 'q'", "$(echo pwned)"]
	var out: Array = []
	PlatformBackend.execute("/usr/bin/printf", ["[%s]"] + tricky, out, true)
	check_eq(str(out[0]), "[a $HOME b][x \"$1\" y][back\\slash][tick `id` z][single 'q'][$(echo pwned)]", "arguments unchanged")
	var packed: Array = []
	PlatformBackend.execute("/usr/bin/printf", PackedStringArray(["%s", "$PATH"]), packed, true)
	check_eq(str(packed[0]), "$PATH", "PackedStringArray arguments too")
