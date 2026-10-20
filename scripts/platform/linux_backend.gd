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


func build_launch_command(config: ServerConfig, java_executable: String, working_dir := "") -> Dictionary:
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
	argv.append_array([_env, "-C", working_dir if working_dir != "" else config.directory])
	if config.cpu_affinity.strip_edges() != "" and supports_affinity():
		argv.append_array([_taskset, "-c", config.cpu_affinity.strip_edges()])
	if config.nice_level > 0 and supports_priority():
		argv.append_array([_nice, "-n", str(config.nice_level)])
	argv.append(java_executable)
	argv.append_array(config.build_jvm_args())
	argv.append_array(config.build_server_args())
	return {"path": argv[0], "args": argv.slice(1)}


## `cp --reflink=auto` makes copies near-instant on copy-on-write filesystems (btrfs, XFS).
func copy_tree(src: String, dst: String) -> Error:
	if DirAccess.dir_exists_absolute(dst) or FileAccess.file_exists(dst):
		return ERR_ALREADY_EXISTS
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var output: Array = []
	if PlatformBackend.execute("cp", ["-a", "--reflink=auto", "--", src, dst], output, true) == 0:
		return OK
	push_warning("cp failed (%s); falling back to a portable copy" % str(output))
	FileOps.remove_path(dst)
	return FileOps.copy_tree_portable(src, dst)


## Through logind, like the desktop's own Sleep button; refused while something holds a
## block lock (e.g. Server Manager while players are online, depending on the sleep policy).
func suspend_computer() -> Dictionary:
	var output: Array = []
	var code := PlatformBackend.execute("systemctl", ["suspend"], output, true)
	return {"ok": code == 0, "message": "" if code == 0 else str(output[0]).strip_edges() if not output.is_empty() else "systemctl suspend failed (%d)" % code}


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
		PlatformBackend.execute("kill", ["-TERM", str(pid)])


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


func is_pid_alive(pid: int) -> bool:
	if pid <= 0 or not DirAccess.dir_exists_absolute("/proc/%d" % pid):
		return false
	var stat := PlatformBackend.read_text("/proc/%d/stat" % pid)
	# A zombie has exited; it only waits for its parent to collect the exit code.
	return stat != "" and stat.substr(stat.rfind(")") + 2, 1) != "Z"


func find_java_in_dir(dir: String) -> int:
	var target := dir.trim_suffix("/")
	for entry in DirAccess.get_directories_at("/proc"):
		if not entry.is_valid_int():
			continue
		var pid := entry.to_int()
		if PlatformBackend.read_text("/proc/%d/comm" % pid).strip_edges() != "java":
			continue
		if process_cwd(pid) == target and is_pid_alive(pid):
			return pid
	return -1


func process_age_seconds(pid: int) -> int:
	var stat := PlatformBackend.read_text("/proc/%d/stat" % pid)
	var uptime := PlatformBackend.read_text("/proc/uptime").get_slice(" ", 0).to_float()
	if stat == "" or uptime <= 0.0:
		return -1
	var rest := stat.substr(stat.rfind(")") + 2).split(" ")
	if rest.size() < 20:
		return -1
	return int(uptime - rest[19].to_int() / CLK_TCK)


func default_route() -> Dictionary:
	for line in PlatformBackend.read_text("/proc/net/route").split("\n"):
		var f := line.split("\t", false)
		# Default route: destination 0.0.0.0 with the gateway flag (0x2) set.
		if f.size() < 8 or f[1] != "00000000" or (f[3].hex_to_int() & 0x2) == 0:
			continue
		var gw := f[2].hex_to_int()  # Little-endian IPv4.
		var result := {
			"interface": f[0],
			"gateway": "%d.%d.%d.%d" % [gw & 0xFF, (gw >> 8) & 0xFF, (gw >> 16) & 0xFF, (gw >> 24) & 0xFF],
			"address": "", "dynamic": false,
		}
		for iface in IP.get_local_interfaces():
			if iface.name == f[0]:
				for addr in iface.addresses:
					if not addr.contains(":"):
						result.address = addr
						break
		var out: Array = []
		if PlatformBackend.execute("ip", ["-4", "-o", "addr", "show", "dev", f[0]], out) == 0 and not out.is_empty():
			result.dynamic = str(out[0]).contains(" dynamic ")
		return result
	return {}


func is_server_process(pid: int, dir: String) -> bool:
	return process_cwd(pid) == dir


func process_executable(pid: int) -> String:
	var dir := DirAccess.open("/proc/%d" % pid)
	return dir.read_link("/proc/%d/exe" % pid) if dir != null else ""


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
