class_name ServerProcess
extends Node
## Owns one server process. Normally it launches the process with non-blocking
## stdio pipes, turns output into lines and writes commands to stdin. It can also
## re-attach to a server that is already running (started by an earlier session of
## the manager, or outside it): output then comes from tailing logs/latest.log and
## commands must go through RCON instead of stdin.

signal line_received(text: String, is_stderr: bool)
## [param exit_code] is -1 when unknown (attached processes are not our children).
signal exited(exit_code: int)

## Upper bound of bytes drained per pipe per poll, so a log flood can't stall a frame.
const MAX_BYTES_PER_POLL := 262144
## Lines of existing log shown when attaching, for context.
const ATTACH_BACKLOG_BYTES := 16384

var pid := -1

var _stdio: FileAccess
var _stderr: FileAccess
## Partial-line byte buffers keyed by is_stderr.
var _pending := {false: PackedByteArray(), true: PackedByteArray()}
var _attached := false
var _log_path := ""
var _log: FileAccess
var _log_pos := 0

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
	_attached = false
	_stdio = info.stdio
	_stderr = info.stderr
	_pending = {false: PackedByteArray(), true: PackedByteArray()}
	_poll_timer.start()
	return OK


## Takes over an already-running process: follows [param log_path] for output and
## watches [param running_pid] for exit.
func attach(running_pid: int, log_path: String) -> Error:
	if is_running():
		return ERR_ALREADY_IN_USE
	if not PlatformBackend.get_current().is_pid_alive(running_pid):
		return ERR_DOES_NOT_EXIST
	pid = running_pid
	_attached = true
	_stdio = null
	_stderr = null
	_log_path = log_path
	_pending = {false: PackedByteArray(), true: PackedByteArray()}
	_open_log(true)
	_poll_timer.start()
	return OK


func is_attached() -> bool:
	return _attached and pid > 0


func is_running() -> bool:
	if pid <= 0:
		return false
	if _attached:
		return PlatformBackend.get_current().is_pid_alive(pid)
	return OS.is_process_running(pid)


## Writes a line to the server's stdin. Not possible for attached processes (use RCON).
func write_line(text: String) -> bool:
	if _attached or _stdio == null or not is_running():
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
	if _attached:
		_follow_log()
		if not is_running():
			_follow_log()
			_flush_partial(false)
			_finish(-1)
		return
	_drain(_stdio, false)
	_drain(_stderr, true)
	if pid > 0 and not OS.is_process_running(pid):
		_drain(_stdio, false)
		_drain(_stderr, true)
		_flush_partial(false)
		_flush_partial(true)
		_finish(OS.get_process_exit_code(pid))


func _finish(code: int) -> void:
	_poll_timer.stop()
	_stdio = null
	_stderr = null
	_log = null
	_attached = false
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
	_emit_lines(buf, is_stderr)


func _emit_lines(buf: PackedByteArray, is_stderr: bool) -> void:
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


# --- Attached mode: follow logs/latest.log ---------------------------------------

func _open_log(with_backlog: bool) -> void:
	_log = FileAccess.open(_log_path, FileAccess.READ)
	if _log == null:
		_log_pos = 0
		return
	var length := _log.get_length()
	# Start a little before the end so the console shows recent context.
	_log_pos = maxi(length - ATTACH_BACKLOG_BYTES, 0) if with_backlog else 0
	if with_backlog and _log_pos > 0:
		_log.seek(_log_pos)
		var skip := _log.get_buffer(mini(4096, length - _log_pos)).find(10)
		_log_pos += skip + 1 if skip >= 0 else 0


func _follow_log() -> void:
	if _log == null:
		_open_log(false)
		if _log == null:
			return
	var length := _log.get_length()
	if length < _log_pos:
		# The log was rotated (a new latest.log); start reading the new file from the top.
		_open_log(false)
		if _log == null:
			return
		length = _log.get_length()
	if length == _log_pos:
		return
	_log.seek(_log_pos)
	var chunk := _log.get_buffer(mini(length - _log_pos, MAX_BYTES_PER_POLL))
	_log_pos += chunk.size()
	var buf: PackedByteArray = _pending[false]
	buf.append_array(chunk)
	_emit_lines(buf, false)
