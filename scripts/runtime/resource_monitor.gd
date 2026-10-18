class_name ResourceMonitor
extends Timer
## Samples CPU and memory usage of a running server process once per tick and
## keeps a short history for graphs.

signal sampled(cpu_percent: float, rss_bytes: int)

const HISTORY_SIZE := 120

## CPU usage as a percentage of the whole host (all cores = 100 %).
var cpu_percent := 0.0
## CPU usage in cores (1.0 = one full core).
var cpu_cores_used := 0.0
var rss_bytes := 0
var cpu_history := PackedFloat32Array()
var ram_history := PackedFloat32Array()

var _pid := -1
var _last_cpu_seconds := -1.0
var _last_usec := 0


func _ready() -> void:
	timeout.connect(_sample)


func track(pid: int) -> void:
	_pid = pid
	_last_cpu_seconds = -1.0
	cpu_history.clear()
	ram_history.clear()
	start()
	_sample()


func untrack() -> void:
	stop()
	_pid = -1
	cpu_percent = 0.0
	cpu_cores_used = 0.0
	rss_bytes = 0
	sampled.emit(0.0, 0)


func _sample() -> void:
	if _pid <= 0:
		return
	var s := PlatformBackend.get_current().sample_process(_pid)
	if s.is_empty():
		return
	var now := Time.get_ticks_usec()
	if _last_cpu_seconds >= 0.0:
		var dt := (now - _last_usec) / 1_000_000.0
		if dt > 0.0:
			cpu_cores_used = maxf(float(s.cpu_seconds) - _last_cpu_seconds, 0.0) / dt
			cpu_percent = cpu_cores_used * 100.0 / maxi(OS.get_processor_count(), 1)
	_last_cpu_seconds = s.cpu_seconds
	_last_usec = now
	rss_bytes = s.rss_bytes
	_push(cpu_history, cpu_percent)
	_push(ram_history, rss_bytes / 1048576.0)
	sampled.emit(cpu_percent, rss_bytes)


static func _push(arr: PackedFloat32Array, value: float) -> void:
	arr.append(value)
	if arr.size() > HISTORY_SIZE:
		arr.remove_at(0)
