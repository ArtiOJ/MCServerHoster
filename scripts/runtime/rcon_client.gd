class_name RconClient
extends Node
## Minimal Source RCON client (https://developer.valvesoftware.com/wiki/Source_RCON_Protocol)
## used for silent status queries so polling never clutters the visible console.
## Keeps one persistent connection, since Paper logs every new RCON connection.

signal authenticated
signal disconnected

const TYPE_RESPONSE := 0
const TYPE_COMMAND := 2
const TYPE_LOGIN := 3
const REQUEST_TIMEOUT_MS := 5000
const MAX_CONNECT_ATTEMPTS := 5

var _peer: StreamPeerTCP
var _host := ""
var _port := 0
var _password := ""
var _authed := false
var _login_sent := false
var _login_id := -1
var _next_id := 1
var _attempts := 0
var _buffer := PackedByteArray()
## request id -> {"done": bool, "text": String}
var _pending := {}
## True while a command is waiting for its reply. Minecraft's RCON server expects each
## TCP read to hold exactly one packet and drops the connection otherwise, so commands
## are sent strictly one at a time.
var _in_flight := false

@onready var _retry_timer: Timer = %RetryTimer


func _ready() -> void:
	set_process(false)
	_retry_timer.timeout.connect(_open)


func connect_to(host: String, port: int, password: String) -> void:
	close()
	_host = host
	_port = port
	_password = password
	_attempts = 0
	_open()


func close() -> void:
	_retry_timer.stop()
	var was_authed := _authed
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null
	_authed = false
	_login_sent = false
	_buffer.clear()
	for entry in _pending.values():
		entry.done = true
	_pending.clear()
	set_process(false)
	if was_authed:
		disconnected.emit()


func is_ready() -> bool:
	return _authed


## Runs a command and returns its textual response ("" on failure or timeout).
func execute(command: String) -> String:
	# Wait for our turn: concurrent callers (status polling, events, the console) queue up.
	var queue_deadline := Time.get_ticks_msec() + REQUEST_TIMEOUT_MS * 4
	while _in_flight and _authed and Time.get_ticks_msec() < queue_deadline:
		await get_tree().process_frame
	if not _authed or _in_flight:
		return ""
	_in_flight = true
	var id := _send(TYPE_COMMAND, command)
	var entry := {"done": false, "text": ""}
	_pending[id] = entry
	var deadline := Time.get_ticks_msec() + REQUEST_TIMEOUT_MS
	while not entry.done and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_pending.erase(id)
	_in_flight = false
	return entry.text


func _open() -> void:
	if _port <= 0:
		return
	_attempts += 1
	_peer = StreamPeerTCP.new()
	_peer.big_endian = false
	_login_sent = false
	_buffer.clear()
	if _peer.connect_to_host(_host, _port) != OK:
		_schedule_retry()
		return
	set_process(true)


func _schedule_retry() -> void:
	set_process(false)
	_peer = null
	if _attempts < MAX_CONNECT_ATTEMPTS:
		_retry_timer.start(2.0 * _attempts)


func _process(_delta: float) -> void:
	if _peer == null:
		set_process(false)
		return
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTING:
			return
		StreamPeerTCP.STATUS_CONNECTED:
			if not _login_sent:
				_login_sent = true
				_login_id = _send(TYPE_LOGIN, _password)
			var available := _peer.get_available_bytes()
			if available > 0:
				var data: Array = _peer.get_partial_data(available)
				if data[0] == OK:
					_buffer.append_array(data[1])
					_parse_packets()
		_:
			if _authed:
				close()
			else:
				_schedule_retry()


func _send(type: int, body: String) -> int:
	var id := _next_id
	_next_id += 1
	var payload := body.to_utf8_buffer()
	var packet := PackedByteArray()
	packet.resize(12)
	packet.encode_s32(0, payload.size() + 10)
	packet.encode_s32(4, id)
	packet.encode_s32(8, type)
	packet.append_array(payload)
	packet.append_array(PackedByteArray([0, 0]))
	_peer.put_data(packet)
	return id


func _parse_packets() -> void:
	while _buffer.size() >= 4:
		var length := _buffer.decode_s32(0)
		if length < 10 or length > 1_048_576:
			close()
			return
		if _buffer.size() < length + 4:
			return
		var id := _buffer.decode_s32(4)
		var type := _buffer.decode_s32(8)
		var body := _buffer.slice(12, length + 2).get_string_from_utf8()
		_buffer = _buffer.slice(length + 4)
		if type == TYPE_COMMAND and not _authed:
			# Login response; id -1 means the password was rejected.
			if id == _login_id:
				_authed = true
				_attempts = 0
				authenticated.emit()
			else:
				push_warning("RCON authentication failed on port %d" % _port)
				close()
				return
		elif type == TYPE_RESPONSE and _pending.has(id):
			_pending[id].text += body
			_pending[id].done = true
