class_name WindowsBackend
extends PlatformBackend
## Windows 10/11 implementation. Godot cannot start a process in another folder, so each
## server starts from a small batch file (`.manager\launch.cmd`) that changes into the server
## folder and runs Java, optionally through `start` for priority and core pinning. The PID the
## app knows is that cmd.exe's; statistics and kills follow it to its java.exe child.
##
## Process and host statistics, sleep/resume events and keeping the computer awake come from
## one long-running PowerShell helper (see [constant MONITOR_SCRIPT]): the app tells it which
## PIDs to watch and whether to block sleep through two small files, and reads one JSON line
## per second from it. Occasional questions (routes, process details) run PowerShell once.

const LAUNCH_SCRIPT := "launch.cmd"
const POWERSHELL_ARGS: PackedStringArray = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass"]
## Cached answers of slow PowerShell queries are reused this long.
const ROUTE_TTL_MSEC := 30000
const PROCESS_TTL_MSEC := 4000
## Exit code of an elevated command whose UAC prompt was declined (ERROR_CANCELLED).
const UAC_CANCELLED := 1223

const MONITOR_SCRIPT := """
$ErrorActionPreference = 'SilentlyContinue'
$parent = __PARENT__
$watchFile = '__WATCH__'
$stateFile = '__STATE__'
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -Namespace SM -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
'@
Register-WmiEvent -Class Win32_PowerManagementEvent -SourceIdentifier SMPower | Out-Null
$info = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
$javaOf = @{}
while ($true) {
	if (-not (Get-Process -Id $parent)) { break }
	$idle = 0; $kernel = 0; $user = 0
	[SM.Native]::GetSystemTimes([ref]$idle, [ref]$kernel, [ref]$user) | Out-Null
	$block = (Test-Path $stateFile) -and ((Get-Content $stateFile -Raw) -match 'block')
	[SM.Native]::SetThreadExecutionState($(if ($block) { [uint32]2147483649 } else { [uint32]2147483648 })) | Out-Null
	$power = @()
	foreach ($e in @(Get-Event -SourceIdentifier SMPower)) {
		$power += [int]$e.SourceEventArgs.NewEvent.EventType
		Remove-Event -EventIdentifier $e.EventIdentifier
	}
	$procs = @{}
	$watch = @()
	if (Test-Path $watchFile) { $watch = @((Get-Content $watchFile -Raw) -split ',' | Where-Object { $_ -match '^\\d+$' }) }
	foreach ($w in $watch) {
		$id = [int]$w
		$java = $javaOf[$id]
		if (-not $java -or -not (Get-Process -Id $java)) {
			$child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$id AND (Name='java.exe' OR Name='javaw.exe')" | Select-Object -First 1
			$java = if ($child) { [int]$child.ProcessId } else { $id }
			$javaOf[$id] = $java
		}
		$p = Get-Process -Id $java
		if ($p) { $procs["$w"] = @{ cpu = $p.TotalProcessorTime.TotalSeconds; rss = $p.WorkingSet64; java = $java } }
	}
	$out = @{
		host = @{ busy = ($kernel + $user - $idle); total = ($kernel + $user); mem_total = $info.TotalPhysicalMemory; mem_available = $info.AvailablePhysicalMemory };
		procs = $procs; power = $power
	}
	[Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 4))
	[Console]::Out.Flush()
	Start-Sleep -Milliseconds 1000
}
"""

var _monitor := {}
var _buffer := PackedByteArray()
var _latest := {}
var _watched := PackedInt32Array()
var _block_sleep := false
var _power_events: Array[String] = []
var _route := {}
var _route_msec := -1
var _route_thread: Thread
var _processes: Array = []
var _processes_msec := -PROCESS_TTL_MSEC


func build_launch_command(config: ServerConfig, java_executable: String, working_dir := "") -> Dictionary:
	var dir := working_dir if working_dir != "" else config.directory
	# Windows consoles default to a legacy code page; the app reads output as UTF-8.
	var argv := PackedStringArray([java_executable, "-Dstdout.encoding=UTF-8", "-Dstderr.encoding=UTF-8"])
	argv.append_array(config.build_jvm_args())
	argv.append_array(config.build_server_args())
	var script := launch_script(dir, argv, config.nice_level if supports_priority() else 0,
			affinity_mask(config.cpu_affinity, OS.get_processor_count()) if supports_affinity() else 0)
	var path := config.meta_dir().path_join(LAUNCH_SCRIPT)
	return {"path": _comspec(), "args": PackedStringArray(["/d", "/c", windows_path(path)]), "script": script, "script_path": path}


## The batch file that starts a server: into [param dir], then [param argv] (Java first),
## through `start /b /wait` when a priority or core mask is wanted. Pure (unit-tested).
static func launch_script(dir: String, argv: PackedStringArray, nice_level: int, mask: int) -> String:
	var command := PackedStringArray()
	if nice_level > 0 or mask > 0:
		command.append_array(["start", "\"\"", "/b", "/wait"])
		if nice_level > 0:
			command.append("/low" if nice_level >= 10 else "/belownormal")
		if mask > 0:
			command.append("/affinity %x" % mask)
	for a in argv:
		command.append(batch_quote(a))
	return "\r\n".join([
		"@echo off",
		"rem Written by Server Manager each time the server starts.",
		"cd /d %s" % batch_quote(windows_path(dir)),
		" ".join(command),
		"exit /b %ERRORLEVEL%",
		"",
	])


## One batch-file argument: quoted, with % doubled (quotes inside can't be expressed and are dropped).
static func batch_quote(arg: String) -> String:
	return "\"%s\"" % arg.replace("\"", "").replace("%", "%%")


## Core mask for `start /affinity` from a list like "0-3" or "0,2,4" (0 = no pinning).
static func affinity_mask(spec: String, cores: int) -> int:
	var mask := 0
	for part in spec.replace(" ", "").split(",", false):
		var bounds := part.split("-")
		var from := bounds[0].to_int()
		var to := bounds[-1].to_int()
		for c in range(from, mini(mini(to, cores - 1), 62) + 1):
			mask |= 1 << c
	return mask


static func windows_path(path: String) -> String:
	return path.replace("/", "\\")


static func _comspec() -> String:
	var comspec := OS.get_environment("ComSpec")
	return comspec if comspec != "" else "cmd.exe"


func supports_affinity() -> bool:
	return true


func supports_priority() -> bool:
	return true


## Console programs without a window can't be asked to close; the stop command (stdin or
## RCON) is the polite way, so this only ends the wrapper's tree when that is all that's left.
func terminate(pid: int) -> void:
	if pid > 0:
		PlatformBackend.execute("taskkill", ["/PID", str(pid), "/T"])


func kill_tree(pid: int) -> void:
	if pid > 0:
		PlatformBackend.execute("taskkill", ["/PID", str(pid), "/T", "/F"])


func sample_process(pid: int) -> Dictionary:
	if not _watched.has(pid):
		_watched.append(pid)
		_write_watch_file()
	_drain()
	var p: Dictionary = _latest.get("procs", {}).get(str(pid), {})
	if p.is_empty():
		return {}
	return {"cpu_seconds": float(p.cpu), "rss_bytes": int(p.rss)}


## Stops watching [param pid] (its server exited).
func forget_process(pid: int) -> void:
	var idx := _watched.find(pid)
	if idx >= 0:
		_watched.remove_at(idx)
		_write_watch_file()


func sample_host() -> Dictionary:
	_drain()
	var h: Dictionary = _latest.get("host", {})
	if h.is_empty():
		return super.sample_host()
	return {"cpu_busy": int(h.busy), "cpu_total": int(h.total), "mem_total": int(h.mem_total), "mem_available": int(h.mem_available)}


## Keeps the computer from sleeping on its own (SetThreadExecutionState in the helper).
func set_sleep_block(on: bool) -> void:
	if on == _block_sleep and not _monitor.is_empty():
		return
	_block_sleep = on
	_ensure_monitor()
	var f := FileAccess.open(_state_file(), FileAccess.WRITE)
	if f != null:
		f.store_string("block" if on else "none")


## Sleep/resume notices since the last call: "sleep" or "wake".
func take_power_events() -> Array[String]:
	_drain()
	var out := _power_events
	_power_events = []
	return out


func find_java_in_dir(dir: String) -> int:
	var script := windows_path(dir.trim_suffix("/") + "/.manager/" + LAUNCH_SCRIPT).to_lower()
	for p: Dictionary in _process_table():
		if str(p.get("Name", "")).to_lower() != "cmd.exe" or not str(p.get("CommandLine", "")).to_lower().contains(script):
			continue
		var pid := int(p.ProcessId)
		if _process_table().any(func(c: Dictionary) -> bool: return int(c.get("ParentProcessId", -1)) == pid and str(c.get("Name", "")).to_lower().begins_with("java")):
			return pid
	return -1


func is_server_process(pid: int, dir: String) -> bool:
	_processes_msec = -PROCESS_TTL_MSEC
	return is_pid_alive(pid) and find_java_in_dir(dir) == pid


func process_age_seconds(pid: int) -> int:
	for p: Dictionary in _process_table():
		if int(p.ProcessId) == pid:
			return int(p.get("Age", -1))
	var out := run_powershell("$p = Get-Process -Id %d; if ($p) { [int]((Get-Date) - $p.StartTime).TotalSeconds }" % pid)
	return out.to_int() if out.is_valid_int() else -1


func process_executable(pid: int) -> String:
	return run_powershell("(Get-Process -Id %d -ErrorAction SilentlyContinue).Path" % pid).strip_edges().replace("\\", "/")


## Asked once synchronously, then refreshed on a worker thread when older than
## [constant ROUTE_TTL_MSEC], so the interface never waits for PowerShell again.
func default_route() -> Dictionary:
	if _route_thread != null and not _route_thread.is_alive():
		_route = _route_thread.wait_to_finish()
		_route_thread = null
	if _route_msec < 0:
		_route = _query_route()
		_route_msec = Time.get_ticks_msec()
	elif Time.get_ticks_msec() - _route_msec > ROUTE_TTL_MSEC and _route_thread == null:
		_route_msec = Time.get_ticks_msec()
		_route_thread = Thread.new()
		_route_thread.start(_query_route)
	return _route


static func _query_route() -> Dictionary:
	var text := run_powershell("""
$r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
if ($r) {
	$ip = Get-NetIPAddress -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
	$a = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue
	@{ gateway = $r.NextHop; interface = $r.InterfaceAlias; address = $ip.IPAddress; dynamic = ($ip.PrefixOrigin -eq 'Dhcp');
	   mac = ($a.MacAddress -replace '-', ':').ToLower(); wireless = ($a.PhysicalMediaType -match '802\\.11') } | ConvertTo-Json -Compress
}""")
	var data = JSON.parse_string(text) if text != "" else null
	return data if data is Dictionary else {}


func java_search_roots() -> PackedStringArray:
	var roots := super.java_search_roots()
	var bases := PackedStringArray()
	for env in ["ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"]:
		var pf := OS.get_environment(env).replace("\\", "/")
		if pf == "":
			continue
		for vendor in ["Eclipse Adoptium", "Java", "Microsoft", "Zulu", "BellSoft", "Amazon Corretto", "Semeru", "OpenJDK", "Eclipse Foundation"]:
			bases.append(pf.path_join(vendor))
	var profile := OS.get_environment("USERPROFILE").replace("\\", "/")
	if profile != "":
		bases.append(profile.path_join(".jdks"))
	var local := OS.get_environment("LOCALAPPDATA").replace("\\", "/")
	if local != "":
		bases.append(local.path_join("Programs/Eclipse Adoptium"))
	for base in bases:
		for sub in DirAccess.get_directories_at(base):
			if not roots.has(base.path_join(sub)):
				roots.append(base.path_join(sub))
	return roots


## Runs a PowerShell script and returns what it printed (stdout). Blocking.
static func run_powershell(script: String) -> String:
	var output: Array = []
	var encoded := Marshalls.raw_to_base64(script.to_utf16_buffer())
	PlatformBackend.execute("powershell.exe", POWERSHELL_ARGS + PackedStringArray(["-EncodedCommand", encoded]), output)
	return str(output[0]).strip_edges() if not output.is_empty() else ""


## Runs a PowerShell script elevated (the UAC prompt appears). Returns its exit code;
## [constant UAC_CANCELLED] when the prompt was declined.
static func run_elevated(script: String) -> int:
	var encoded := Marshalls.raw_to_base64(script.to_utf16_buffer())
	var outer := "try { $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','%s'; exit $p.ExitCode } catch { exit %d }" % [encoded, UAC_CANCELLED]
	var out_encoded := Marshalls.raw_to_base64(outer.to_utf16_buffer())
	return PlatformBackend.execute("powershell.exe", POWERSHELL_ARGS + PackedStringArray(["-EncodedCommand", out_encoded]))


## Java and cmd.exe processes: [{ProcessId, ParentProcessId, Name, CommandLine, Age}], cached briefly.
func _process_table() -> Array:
	if Time.get_ticks_msec() - _processes_msec < PROCESS_TTL_MSEC:
		return _processes
	_processes_msec = Time.get_ticks_msec()
	var text := run_powershell("@(Get-CimInstance Win32_Process -Filter \"Name='java.exe' OR Name='javaw.exe' OR Name='cmd.exe'\" | ForEach-Object { @{ ProcessId = $_.ProcessId; ParentProcessId = $_.ParentProcessId; Name = $_.Name; CommandLine = $_.CommandLine; Age = [int]((Get-Date) - $_.CreationDate).TotalSeconds } }) | ConvertTo-Json -Compress -Depth 3")
	var data = JSON.parse_string(text) if text != "" else null
	_processes = data if data is Array else ([data] if data is Dictionary else [])
	return _processes


func _monitor_dir() -> String:
	var dir := ProjectSettings.globalize_path("user://windows-helper")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _watch_file() -> String:
	return _monitor_dir().path_join("watch-%d.txt" % OS.get_process_id())


func _state_file() -> String:
	return _monitor_dir().path_join("power-%d.txt" % OS.get_process_id())


func _write_watch_file() -> void:
	_ensure_monitor()
	var f := FileAccess.open(_watch_file(), FileAccess.WRITE)
	if f != null:
		f.store_string(",".join(Array(_watched).map(func(p: int) -> String: return str(p))))


## Starts the PowerShell helper once; it ends by itself when this app exits.
func _ensure_monitor() -> void:
	if not _monitor.is_empty() and OS.is_process_running(int(_monitor.pid)):
		return
	var script := MONITOR_SCRIPT.replace("__PARENT__", str(OS.get_process_id())) \
			.replace("__WATCH__", windows_path(_watch_file()).replace("'", "''")) \
			.replace("__STATE__", windows_path(_state_file()).replace("'", "''"))
	var encoded := Marshalls.raw_to_base64(script.to_utf16_buffer())
	_monitor = OS.execute_with_pipe("powershell.exe", POWERSHELL_ARGS + PackedStringArray(["-EncodedCommand", encoded]), false)
	_buffer.clear()


## Reads what the helper printed since last time and keeps the newest report.
func _drain() -> void:
	_ensure_monitor()
	if _monitor.is_empty():
		return
	var pipe: FileAccess = _monitor.stdio
	var chunk := pipe.get_buffer(65536)
	while not chunk.is_empty():
		_buffer.append_array(chunk)
		chunk = pipe.get_buffer(65536)
	var nl := _buffer.find(10)
	while nl != -1:
		var data = JSON.parse_string(_buffer.slice(0, nl).get_string_from_utf8())
		_buffer = _buffer.slice(nl + 1)
		nl = _buffer.find(10)
		if data is Dictionary:
			_latest = data
			var power = data.get("power", [])
			for t in (power if power is Array else [power]):
				match int(t):
					4:
						_power_events.append("sleep")
					7, 18:
						if _power_events.is_empty() or _power_events[-1] != "wake":
							_power_events.append("wake")
