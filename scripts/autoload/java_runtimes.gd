extends Node
## Detects installed Java runtimes and picks one that satisfies a server's
## minimum Java version.

signal runtimes_changed

var runtimes: Array[JavaRuntime] = []


func _ready() -> void:
	if not AppSettings.phone:
		rescan()


func rescan() -> void:
	var backend := PlatformBackend.get_current()
	var seen := {}
	var found: Array[JavaRuntime] = []
	var candidates := backend.java_search_roots()
	for extra in AppSettings.extra_java_paths:
		# Accept either a JDK home or a path to the java executable itself.
		candidates.append(extra.get_base_dir().get_base_dir() if extra.get_file().begins_with("java") else extra)
	for home in candidates:
		var exe := backend.java_executable_in(home)
		if not FileAccess.file_exists(exe) or seen.has(exe):
			continue
		seen[exe] = true
		var rt := _inspect(home, exe)
		# The same JDK is often reachable through symlinked paths (e.g. /usr/lib64 -> /usr/lib).
		if rt != null and not seen.has(rt.identity()):
			seen[rt.identity()] = true
			found.append(rt)
	if found.is_empty():
		var on_path := PlatformBackend.find_in_path("java")
		if on_path != "":
			var rt := _inspect(on_path.get_base_dir().get_base_dir(), on_path)
			if rt != null:
				found.append(rt)
	found.sort_custom(func(a: JavaRuntime, b: JavaRuntime) -> bool: return a.major < b.major)
	runtimes = found
	runtimes_changed.emit()


## Lowest installed major version >= [param min_major]: old Minecraft versions break
## on very new Java, so the closest compatible runtime is the safest choice.
func best_for(min_major: int) -> JavaRuntime:
	for rt in runtimes:
		if rt.major >= min_major:
			return rt
	return null


func find_by_executable(path: String) -> JavaRuntime:
	for rt in runtimes:
		if rt.executable == path:
			return rt
	return null


## Resolves the runtime a server should use: its explicit override when valid, otherwise automatic.
func resolve_for(config: ServerConfig) -> JavaRuntime:
	if config.java_path != "":
		var rt := find_by_executable(config.java_path)
		if rt == null and FileAccess.file_exists(config.java_path):
			rt = _inspect(config.java_path.get_base_dir().get_base_dir(), config.java_path)
		return rt
	return best_for(config.java_min_version)


func _inspect(home: String, exe: String) -> JavaRuntime:
	var rt := JavaRuntime.new()
	rt.home = home
	rt.executable = exe
	# The `release` file avoids spawning a JVM per candidate.
	var release := home.path_join("release")
	if FileAccess.file_exists(release):
		for line in FileAccess.get_file_as_string(release).split("\n"):
			if line.begins_with("JAVA_VERSION="):
				rt.version = line.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
			elif line.begins_with("IMPLEMENTOR="):
				rt.vendor = line.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	if rt.version == "":
		var output: Array = []
		if PlatformBackend.execute(exe, ["-version"], output, true) != 0 or output.is_empty():
			return null
		var m := RegEx.create_from_string("version \"([^\"]+)\"").search(str(output[0]))
		if m == null:
			return null
		rt.version = m.get_string(1)
	rt.major = _major_of(rt.version)
	return rt if rt.major > 0 else null


static func _major_of(version: String) -> int:
	var parts := version.split(".")
	if parts[0] == "1" and parts.size() > 1:
		return parts[1].to_int()
	return parts[0].to_int()
