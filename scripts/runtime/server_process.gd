class_name ServerProcess
extends Node
## Owns one child process: launches it with non-blocking stdio pipes, turns its
## output into lines, writes commands to stdin and reports when it exits.

signal line_received(text: String, is_stderr: bool)
signal exited(exit_code: int)

## Upper bound of bytes drained per pipe per poll, so a log flood can't stall a frame.
const MAX_BYTES_PER_POLL := 262144

var pid := -1

var _stdio: FileAccess
var _stderr: FileAccess
## Partial-line byte buffers keyed by is_stderr.
var _pending := {false: PackedByteArray(), true: PackedByteArray()}

@onready var _poll_timer: Timer = $PollTimer


func _ready() -> void:
	_poll_timer.timeout.connect(_poll)


func launch(path: String, args: PackedStringArray) -> Error:
	if is_running():
		return ERR_ALREADY_IN_USE
	var info := OS.execute_with_pipe(path, args, false)
	if info.is_empty():
		return ERR_CANT_FORK
	pid = int(info.pid)
	_stdio = info.stdio
	_stderr = info.stderr
	_pending = {false: PackedByteArray(), true: PackedByteArray()}
	_poll_timer.start()
	return OK


func is_running() -> bool:
	return pid > 0 and OS.is_process_running(pid)


func write_line(text: String) -> bool:
	if _stdio == null or not is_running():
		return false
	_stdio.store_string(text + "\n")
	_stdio.flush()
	return true


## Polite shutdown request (SIGTERM).
func terminate() -> void:
	if is_running():
		PlatformBackend.get_current().terminate(pid)


## Immediate kill.
func kill() -> void:
	if is_running():
		OS.kill(pid)


func _poll() -> void:
	_drain(_stdio, false)
	_drain(_stderr, true)
	if pid > 0 and not OS.is_process_running(pid):
		_drain(_stdio, false)
		_drain(_stderr, true)
		_flush_partial(false)
		_flush_partial(true)
		var code := OS.get_process_exit_code(pid)
		_poll_timer.stop()
		_stdio = null
		_stderr = null
		pid = -1
		exited.emit(code)


func _drain(pipe: FileAccess, is_stderr: bool) -> void:
	if pipe == null:
		return
	var buf: PackedByteArray = _pending[is_stderr]
	var total := 0
	while total < MAX_BYTES_PER_POLL:
		var chunk := pipe.get_buffer(65536)
		if chunk.is_empty():
			break
		total += chunk.size()
		buf.append_array(chunk)
	if total == 0:
		return
	var start := 0
	var nl := buf.find(10)
	while nl != -1:
		line_received.emit(buf.slice(start, nl).get_string_from_utf8().trim_suffix("\r"), is_stderr)
		start = nl + 1
		nl = buf.find(10, start)
	_pending[is_stderr] = buf.slice(start)


func _flush_partial(is_stderr: bool) -> void:
	var buf: PackedByteArray = _pending[is_stderr]
	if not buf.is_empty():
		line_received.emit(buf.get_string_from_utf8(), is_stderr)
	_pending[is_stderr] = PackedByteArray()
