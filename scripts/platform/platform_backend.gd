class_name PlatformBackend
extends RefCounted
## OS-specific operations: building the launch command (with resource limits),
## process/host statistics and Java discovery. Linux and Windows have their own
## backends; other platforms get a degraded but functional generic one.

static var _current: PlatformBackend


static func get_current() -> PlatformBackend:
	if _current == null:
		match OS.get_name():
			"Linux":
				_current = LinuxBackend.new()
			"Windows":
				_current = WindowsBackend.new()
			_:
				_current = PlatformBackend.new()
	return _current


## Returns {"path": String, "args": PackedStringArray} ready for OS.execute_with_pipe(), plus
## {"script": text, "script_path": path} when a launcher file must be written first (Windows).
func build_launch_command(config: ServerConfig, java_executable: String, _working_dir := "") -> Dictionary:
	var args := config.build_jvm_args()
	args.append_array(config.build_server_args())
	return {"path": java_executable, "args": args}


func supports_cpu_quota() -> bool:
	return false


func supports_memory_cap() -> bool:
	return false


func supports_affinity() -> bool:
	return false


func supports_priority() -> bool:
	return false


## Copies a directory tree to a new location. Thread-safe.
func copy_tree(src: String, dst: String) -> Error:
	return FileOps.copy_tree_portable(src, dst)


## Asks a process to shut down (SIGTERM on POSIX).
func terminate(pid: int) -> void:
	OS.kill(pid)


## Ends a process and everything it started (the server's launcher and its Java).
func kill_tree(pid: int) -> void:
	if pid > 0:
		OS.kill(pid)


## Stops watching a process whose statistics were sampled (it exited).
func forget_process(_pid: int) -> void:
	pass


## Puts the computer to sleep now. Returns {ok, message}.
func suspend_computer() -> Dictionary:
	return {"ok": false, "message": "Putting the computer to sleep isn't supported here."}


## Keeps the computer from going to sleep by itself while [param on] (Windows; Linux uses logind).
func set_sleep_block(_on: bool) -> void:
	pass


## Sleep/resume notices since the last call ("sleep", "wake"), where the OS reports them here.
func take_power_events() -> Array[String]:
	return []


## {"cpu_seconds": float, "rss_bytes": int} or empty when unavailable.
func sample_process(_pid: int) -> Dictionary:
	return {}


## {"cpu_busy": int, "cpu_total": int, "mem_total": int, "mem_available": int} (bytes) or empty.
func sample_host() -> Dictionary:
	var info := OS.get_memory_info()
	return {"cpu_busy": 0, "cpu_total": 0, "mem_total": int(info.get("physical", 0)), "mem_available": int(info.get("free", 0))}


func host_memory_bytes() -> int:
	return int(OS.get_memory_info().get("physical", 0))


## True while [param pid] exists (works for processes that are not our children).
func is_pid_alive(pid: int) -> bool:
	return pid > 0 and OS.is_process_running(pid)


## The route to the internet: {"gateway": router IP, "interface": name, "address": this
## computer's IPv4 on that interface, "dynamic": assigned by DHCP}. Empty when unknown.
func default_route() -> Dictionary:
	return {}


## True while [param pid] is still the server running in [param dir] (not a reused PID).
func is_server_process(pid: int, dir: String) -> bool:
	var cwd := process_cwd(pid)
	return is_pid_alive(pid) and (cwd == "" or cwd == dir)


## Executable path of a running process, or "" if unknown.
func process_executable(_pid: int) -> String:
	return ""


## PID of a Java process whose working directory is [param dir], or -1.
func find_java_in_dir(_dir: String) -> int:
	return -1


## Seconds since [param pid] started, or -1 when unknown.
func process_age_seconds(_pid: int) -> int:
	return -1


## Absolute path of the server's process working directory, or "" if unknown.
func process_cwd(_pid: int) -> String:
	return ""


## Candidate Java home directories to inspect.
func java_search_roots() -> PackedStringArray:
	var roots := PackedStringArray()
	var java_home := OS.get_environment("JAVA_HOME")
	if java_home != "":
		roots.append(java_home)
	return roots


func java_executable_in(home: String) -> String:
	var exe := "java.exe" if OS.get_name() == "Windows" else "java"
	return home.path_join("bin").path_join(exe)


## Runs a program and waits for it, passing every argument through literally. Use this
## instead of OS.execute(): on Linux, Godot 4.7's OS.execute() hands the command to a shell
## inside double quotes, so `$`, backticks, `"` and `\` in arguments would be expanded or
## eaten (a file name like `$(rm …).png` would even run a command). Escaping those four
## characters makes the shell pass each argument through unchanged. Windows has no such
## shell step (Godot quotes each argument itself), so arguments go through as they are.
static func execute(path: String, args, output: Array = [], read_stderr := false) -> int:
	var safe := PackedStringArray()
	for a in args:
		safe.append(str(a) if OS.get_name() == "Windows" else str(a).replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$").replace("`", "\\`"))
	return OS.execute(path, safe, output, read_stderr)


## Resolves an executable name through PATH (on Windows also trying .exe/.cmd/.bat).
## Returns "" if not found.
static func find_in_path(name: String) -> String:
	var windows := OS.get_name() == "Windows"
	var suffixes := ["", ".exe", ".cmd", ".bat"] if windows and name.get_extension() == "" else [""]
	for dir in OS.get_environment("PATH").split(";" if windows else ":", false):
		for suffix in suffixes:
			var candidate := dir.replace("\\", "/").path_join(name + suffix)
			if FileAccess.file_exists(candidate):
				return candidate
	return ""


## Reads a pseudo-file such as /proc/<pid>/stat (size reported as 0, so read line by line).
static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var lines := PackedStringArray()
	while true:
		var line := f.get_line()
		if f.eof_reached():
			if line != "":
				lines.append(line)
			break
		lines.append(line)
	return "\n".join(lines)


## True when nothing on this machine is listening on [param port] (TCP).
static func is_port_free(port: int) -> bool:
	var server := TCPServer.new()
	var ok := server.listen(port, "*") == OK
	server.stop()
	return ok
