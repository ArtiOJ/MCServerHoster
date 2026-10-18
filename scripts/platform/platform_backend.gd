class_name PlatformBackend
extends RefCounted
## OS-specific operations: building the launch command (with resource limits),
## process/host statistics and Java discovery. Only Linux is implemented; other
## platforms get a degraded but functional generic backend.

static var _current: PlatformBackend


static func get_current() -> PlatformBackend:
	if _current == null:
		_current = LinuxBackend.new() if OS.get_name() == "Linux" else PlatformBackend.new()
	return _current


## Returns {"path": String, "args": PackedStringArray} ready for OS.execute_with_pipe().
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


## Resolves an executable name through PATH. Returns "" if not found.
static func find_in_path(name: String) -> String:
	var sep := ";" if OS.get_name() == "Windows" else ":"
	for dir in OS.get_environment("PATH").split(sep, false):
		var candidate := dir.path_join(name)
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
