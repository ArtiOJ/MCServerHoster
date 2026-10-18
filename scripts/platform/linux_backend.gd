class_name LinuxBackend
extends PlatformBackend
## Linux implementation: resource limits via `systemd-run --user --scope`
## (cgroups v2), `taskset` and `nice`; statistics from /proc.
##
## Every wrapper exec()s the next program, so the PID Godot receives is the
## JVM's own PID and /proc/<pid> monitoring works directly.

const CLK_TCK := 100.0

var _env := ""
var _systemd_run := ""
var _taskset := ""
var _nice := ""
var _cgroup_v2 := false


func _init() -> void:
	_env = _first_existing(["/usr/bin/env", "/bin/env"])
	_systemd_run = PlatformBackend.find_in_path("systemd-run")
	_taskset = PlatformBackend.find_in_path("taskset")
	_nice = PlatformBackend.find_in_path("nice")
	_cgroup_v2 = FileAccess.file_exists("/sys/fs/cgroup/cgroup.controllers")


func build_launch_command(config: ServerConfig, java_executable: String) -> Dictionary:
	var argv := PackedStringArray()
	var use_quota := config.cpu_quota_pct > 0 and supports_cpu_quota()
	var use_cap := config.memory_hard_cap and supports_memory_cap()
	if use_quota or use_cap:
		argv.append_array([_systemd_run, "--user", "--scope", "--quiet", "--collect"])
		if use_quota:
			argv.append_array(["-p", "CPUQuota=%d%%" % config.cpu_quota_pct])
		if use_cap:
			argv.append_array(["-p", "MemoryMax=%dM" % config.hard_cap_mb()])
		argv.append("--")
	# OS.execute_with_pipe() has no working-directory parameter, so `env -C` sets it.
	argv.append_array([_env, "-C", config.directory])
	if config.cpu_affinity.strip_edges() != "" and supports_affinity():
		argv.append_array([_taskset, "-c", config.cpu_affinity.strip_edges()])
	if config.nice_level > 0 and supports_priority():
		argv.append_array([_nice, "-n", str(config.nice_level)])
	argv.append(java_executable)
	argv.append_array(config.build_jvm_args())
	argv.append_array(config.build_server_args())
	return {"path": argv[0], "args": argv.slice(1)}


func supports_cpu_quota() -> bool:
	return _systemd_run != "" and _cgroup_v2


func supports_memory_cap() -> bool:
	return _systemd_run != "" and _cgroup_v2


func supports_affinity() -> bool:
	return _taskset != ""


func supports_priority() -> bool:
	return _nice != ""


func terminate(pid: int) -> void:
	if pid > 0:
		OS.execute("kill", ["-TERM", str(pid)])


func sample_process(pid: int) -> Dictionary:
	var stat := PlatformBackend.read_text("/proc/%d/stat" % pid)
	if stat.is_empty():
		return {}
	# Fields after the parenthesised command name; utime/stime are fields 14/15 overall.
	var rest := stat.substr(stat.rfind(")") + 2).split(" ")
	if rest.size() < 13:
		return {}
	var ticks := rest[11].to_int() + rest[12].to_int()
	var rss := 0
	for line in PlatformBackend.read_text("/proc/%d/status" % pid).split("\n"):
		if line.begins_with("VmRSS:"):
			rss = line.split(":")[1].strip_edges().split(" ")[0].to_int() * 1024
			break
	return {"cpu_seconds": ticks / CLK_TCK, "rss_bytes": rss}


func sample_host() -> Dictionary:
	var result := {"cpu_busy": 0, "cpu_total": 0, "mem_total": 0, "mem_available": 0}
	var stat := PlatformBackend.read_text("/proc/stat")
	var first := stat.get_slice("\n", 0)
	if first.begins_with("cpu "):
		var parts := first.split(" ", false)
		var total := 0
		for i in range(1, mini(parts.size(), 9)):
			total += parts[i].to_int()
		var idle := parts[4].to_int() + (parts[5].to_int() if parts.size() > 5 else 0)
		result.cpu_total = total
		result.cpu_busy = total - idle
	for line in PlatformBackend.read_text("/proc/meminfo").split("\n"):
		if line.begins_with("MemTotal:"):
			result.mem_total = line.split(":")[1].strip_edges().split(" ")[0].to_int() * 1024
		elif line.begins_with("MemAvailable:"):
			result.mem_available = line.split(":")[1].strip_edges().split(" ")[0].to_int() * 1024
	return result


func host_memory_bytes() -> int:
	var total := int(sample_host().mem_total)
	return total if total > 0 else super.host_memory_bytes()


func process_cwd(pid: int) -> String:
	var dir := DirAccess.open("/proc/%d" % pid)
	if dir == null:
		return ""
	return dir.read_link("/proc/%d/cwd" % pid)


func java_search_roots() -> PackedStringArray:
	var roots := super.java_search_roots()
	var home := OS.get_environment("HOME")
	for base in ["/usr/lib/jvm", "/usr/lib64/jvm", "/usr/java", "/opt/java", "/opt/jdk",
			home.path_join(".sdkman/candidates/java"), home.path_join(".jdks"), home.path_join(".local/share/jdks")]:
		var dir := DirAccess.open(base)
		if dir == null:
			continue
		for sub in dir.get_directories():
			roots.append(base.path_join(sub))
	return roots


static func _first_existing(paths: Array) -> String:
	for p in paths:
		if FileAccess.file_exists(p):
			return p
	return "env"
