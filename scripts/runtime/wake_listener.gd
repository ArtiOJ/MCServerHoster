class_name WakeListener
extends Timer
## "Start on connect": while the server is stopped, listens on its port and answers
## like a sleeping server. Server-list pings get a custom MOTD; a join attempt gets a
## "starting, reconnect shortly" message and starts the real server (the listener
## releases the port first). Ticks every [member wait_time] seconds to service sockets.

## A player (or, optionally, a server-list ping) asked for the server.
signal wake_requested(reason: String)

const CLIENT_TIMEOUT_MS := 5000
const DEFAULT_MOTD := "§7Asleep §8— §ajoin to start the server"
const KICK_MESSAGE := "The server is starting up. Reconnect in about %d seconds."

var instance: ServerInstance
## Last problem binding the port, shown in the UI ("" when fine).
var last_error := ""

var _server: TCPServer
## Each: {peer: StreamPeerTCP, buffer: PackedByteArray, state: int, protocol: int, since: int}
var _clients: Array[Dictionary] = []
var _retry_at := 0
var _listening_port := 0


func _ready() -> void:
	instance = get_parent() as ServerInstance
	timeout.connect(_service)


func is_listening() -> bool:
	return _server != null and _server.is_listening()


## Starts or stops listening to match the server's settings and state.
func update() -> void:
	var want := instance.config.wake_on_connect and instance.state == ServerInstance.State.STOPPED \
			and not instance.is_process_alive() and instance.orphan_pid <= 0 and not instance.is_temporary()
	if want and is_listening() and _listening_port != instance.config.port:
		close()  # The port changed: move to the new one.
	if want and not is_listening():
		_listen()
	elif not want and is_listening():
		close()
		instance.state_changed.emit(instance.state)


## Releases the port (called right before the real server starts).
func close() -> void:
	for c in _clients:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	if _server != null:
		_server.stop()
	_server = null
	stop()


func _listen() -> void:
	if Time.get_ticks_msec() < _retry_at:
		if is_stopped():
			start()
		return
	_server = TCPServer.new()
	var bind := instance.get_properties().get_value("server-ip", "")
	var err := _server.listen(instance.config.port, bind if bind != "" else "*")
	if err != OK:
		_server = null
		last_error = "Port %d is in use by another program; retrying." % instance.config.port
		_retry_at = Time.get_ticks_msec() + 10000
		start()
		return
	last_error = ""
	_listening_port = instance.config.port
	start()
	instance.log_system("Asleep: listening on port %d and will start when a player joins." % instance.config.port)
	instance.state_changed.emit(instance.state)


func _service() -> void:
	if _server == null:
		update()
		return
	while _server != null and _server.is_connection_available():
		var peer := _server.take_connection()
		peer.set_no_delay(true)
		_clients.append({"peer": peer, "buffer": PackedByteArray(), "state": 0, "protocol": 0, "since": Time.get_ticks_msec()})
	var now := Time.get_ticks_msec()
	for c in _clients.duplicate():
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED or now - int(c.since) > CLIENT_TIMEOUT_MS:
			_drop(c)
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var data: Array = peer.get_partial_data(available)
			if data[0] == OK:
				# Packed arrays are values: append to a copy and store it back.
				var buffer: PackedByteArray = c.buffer
				buffer.append_array(data[1])
				c.buffer = buffer
		if not _handle_packets(c):
			_drop(c)
			if _server == null:
				return


## Processes complete packets for one client. Returns false when the connection should close.
func _handle_packets(c: Dictionary) -> bool:
	var buffer: PackedByteArray = c.buffer
	if c.state == 0 and not buffer.is_empty() and buffer[0] == 0xFE:
		return false  # Legacy (pre-1.7) server-list ping: not supported.
	while true:
		var pkt := McProtocol.take_packet(buffer)
		if pkt.is_empty():
			break
		if pkt.has("error"):
			return false
		buffer = buffer.slice(pkt.size)
		c.buffer = buffer
		match int(c.state):
			0:
				var hs := McProtocol.parse_handshake(pkt.payload)
				if pkt.id != 0x00 or hs.is_empty():
					return false
				c.protocol = hs.protocol
				c.state = hs.next_state
				if c.state == McProtocol.STATE_STATUS and instance.config.wake_on_ping:
					_wake("server-list ping from %s" % _ip(c))
			McProtocol.STATE_STATUS:
				if pkt.id == 0x00:
					_send(c, McProtocol.packet(0x00, McProtocol.write_string(_status_json(c.protocol))))
				elif pkt.id == 0x01:
					_send(c, McProtocol.packet(0x01, pkt.payload))  # Pong echoes the ping payload.
					return false
			McProtocol.STATE_LOGIN, McProtocol.STATE_TRANSFER:
				var player := ""
				if pkt.id == 0x00:
					var name_info := McProtocol.read_string(pkt.payload, 0)
					if not name_info.is_empty():
						player = name_info[0]
				_send(c, McProtocol.login_disconnect(KICK_MESSAGE % _expected_startup_seconds()))
				_wake("%s tried to join from %s" % [player if player != "" else "a player", _ip(c)])
				return false
			_:
				return false
	return true


func _status_json(protocol: int) -> String:
	var motd := instance.config.wake_motd.strip_edges()
	if motd == "":
		motd = DEFAULT_MOTD
	# Echo the client's protocol so the entry isn't shown as incompatible.
	return McProtocol.status_json("Asleep (%s)" % instance.config.mc_version, protocol, motd, maxi(instance.max_players, 1))


func _wake(reason: String) -> void:
	if _server == null:
		return
	instance.log_system("Waking up: %s." % reason)
	Notifier.info("%s — starting %s." % [reason.substr(0, 1).to_upper() + reason.substr(1), instance.config.display_name],
			Notifier.Category.WAKE, instance.config.display_name)
	wake_requested.emit(reason)
	# Defer so the disconnect message is flushed before the port is released.
	_start_server.call_deferred()


func _start_server() -> void:
	await get_tree().create_timer(0.3).timeout
	close()
	instance.start()


func _send(c: Dictionary, bytes: PackedByteArray) -> void:
	(c.peer as StreamPeerTCP).put_data(bytes)


func _drop(c: Dictionary) -> void:
	(c.peer as StreamPeerTCP).disconnect_from_host()
	_clients.erase(c)


func _ip(c: Dictionary) -> String:
	return (c.peer as StreamPeerTCP).get_connected_host()


func _expected_startup_seconds() -> int:
	var last := instance.startup_seconds
	return clampi(int(ceil(last + 5.0)) if last > 0.0 else 30, 10, 120)
