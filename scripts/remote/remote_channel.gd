class_name RemoteChannel
extends RefCounted
## One connection between two Server Managers: TCP, then optionally TLS, carrying framed
## JSON messages ([RemoteProtocol]). Never blocks; the owner calls [method poll] often.

enum Status { CONNECTING, OPEN, HANDSHAKING, SECURE, CLOSED }

## Give up on a slow reader instead of buffering without limit.
const MAX_PENDING_OUT := 64 * 1024 * 1024

var status := Status.CONNECTING
## Why the channel closed ("" while open or after a normal close).
var error := ""
var remote_address := ""
var reader := RemoteProtocol.FrameReader.new()
## When false, incoming bytes are left for [method take_byte] (the host reads the mode byte).
var framed := true

var _tcp := StreamPeerTCP.new()
var _tls: StreamPeerTLS
var _out := PackedByteArray()
var _port := 0
var _resolve_id := -1
var _close_when_flushed := false


## Starts connecting to [param host] (name or address) on [param port].
static func open(host: String, port: int) -> RemoteChannel:
	var ch := RemoteChannel.new()
	ch.remote_address = host
	ch._port = port
	if host.is_valid_ip_address():
		ch._connect_ip(host)
	else:
		ch._resolve_id = IP.resolve_hostname_queue_item(host)
	return ch


## Wraps a connection accepted by a TCPServer.
static func accepted(tcp: StreamPeerTCP) -> RemoteChannel:
	var ch := RemoteChannel.new()
	ch._tcp = tcp
	ch.remote_address = tcp.get_connected_host()
	ch.status = Status.OPEN
	return ch


func is_closed() -> bool:
	return status == Status.CLOSED


func is_secure() -> bool:
	return status == Status.SECURE


## Begins TLS as the client, trusting only [param cert] (the pinned host certificate).
func start_tls_client(cert: X509Certificate) -> void:
	_tls = StreamPeerTLS.new()
	var err := _tls.connect_to_stream(_tcp, RemoteProtocol.CERT_CN, TLSOptions.client(cert, RemoteProtocol.CERT_CN))
	if err != OK:
		_fail("Could not start a secure connection (%s)." % error_string(err))
		return
	status = Status.HANDSHAKING


## Begins TLS as the host.
func start_tls_server(key: CryptoKey, cert: X509Certificate) -> void:
	_tls = StreamPeerTLS.new()
	var err := _tls.accept_stream(_tcp, TLSOptions.server(key, cert))
	if err != OK:
		_fail("Could not start a secure connection (%s)." % error_string(err))
		return
	status = Status.HANDSHAKING


func send(message: Dictionary) -> void:
	if status == Status.CLOSED:
		return
	_out.append_array(RemoteProtocol.encode(message))
	if _out.size() > MAX_PENDING_OUT:
		_fail("The other side is not reading; connection dropped.")


func send_bytes(bytes: PackedByteArray) -> void:
	if status != Status.CLOSED:
		_out.append_array(bytes)


## Reads one raw byte (before framing starts), or -1 if none has arrived yet.
func take_byte() -> int:
	if status != Status.OPEN or _tcp.get_available_bytes() < 1:
		return -1
	var res := _tcp.get_partial_data(1)
	if res[0] != OK or (res[1] as PackedByteArray).is_empty():
		return -1
	return (res[1] as PackedByteArray)[0]


## Writes queued bytes now. Returns true when everything went out.
func flush() -> bool:
	if status == Status.OPEN or status == Status.SECURE:
		_flush()
	return _out.is_empty() and status != Status.CLOSED


## Sends what is queued, then closes.
func close_after_flush() -> void:
	_close_when_flushed = true


func close(reason := "") -> void:
	if status == Status.CLOSED:
		return
	if reason != "" and error == "":
		error = reason
	if _tls != null:
		_tls.disconnect_from_stream()
	_tcp.disconnect_from_host()
	status = Status.CLOSED


## Advances the connection and returns the messages that arrived.
func poll() -> Array[Dictionary]:
	var messages: Array[Dictionary] = []
	if status == Status.CLOSED:
		return messages
	if _resolve_id >= 0:
		_poll_resolve()
		return messages
	_tcp.poll()
	var tcp_status := _tcp.get_status()
	if tcp_status == StreamPeerTCP.STATUS_ERROR or tcp_status == StreamPeerTCP.STATUS_NONE:
		_fail("Could not connect to %s:%d." % [remote_address, _port] if status == Status.CONNECTING else "Connection lost.")
		return messages
	if status == Status.CONNECTING:
		if tcp_status != StreamPeerTCP.STATUS_CONNECTED:
			return messages
		_tcp.set_no_delay(true)
		status = Status.OPEN
	if _tls != null:
		_tls.poll()
		var tls_status := _tls.get_status()
		if tls_status == StreamPeerTLS.STATUS_HANDSHAKING:
			return messages
		if tls_status != StreamPeerTLS.STATUS_CONNECTED:
			_fail("The secure connection failed." if status == Status.HANDSHAKING else "Connection lost.")
			return messages
		status = Status.SECURE
	_flush()
	if status == Status.CLOSED:
		return messages
	if framed:
		_read_into(messages)
	if _close_when_flushed and _out.is_empty():
		close()
	return messages


func _peer() -> StreamPeer:
	return _tls if _tls != null else _tcp


func _connect_ip(ip: String) -> void:
	var err := _tcp.connect_to_host(ip, _port)
	if err != OK:
		_fail("Could not connect to %s:%d (%s)." % [remote_address, _port, error_string(err)])


func _poll_resolve() -> void:
	match IP.get_resolve_item_status(_resolve_id):
		IP.RESOLVER_STATUS_WAITING:
			return
		IP.RESOLVER_STATUS_DONE:
			var ip := IP.get_resolve_item_address(_resolve_id)
			IP.erase_resolve_item(_resolve_id)
			_resolve_id = -1
			if ip == "":
				_fail("Could not find %s." % remote_address)
			else:
				_connect_ip(ip)
		_:
			IP.erase_resolve_item(_resolve_id)
			_resolve_id = -1
			_fail("Could not find %s." % remote_address)


func _flush() -> void:
	while not _out.is_empty():
		var res := _peer().put_partial_data(_out)
		if res[0] != OK:
			_fail("Connection lost.")
			return
		var sent: int = res[1]
		if sent <= 0:
			return
		_out = _out.slice(sent)


func _read_into(messages: Array[Dictionary]) -> void:
	var peer := _peer()
	while true:
		var available := peer.get_available_bytes()
		if available <= 0:
			break
		var res := peer.get_partial_data(mini(available, 1 << 20))
		if res[0] != OK:
			_fail("Connection lost.")
			return
		reader.feed(res[1])
		if (res[1] as PackedByteArray).is_empty():
			break
	while true:
		var msg = reader.next()
		if msg == null:
			break
		messages.append(msg)
	if reader.error != "":
		_fail(reader.error)


func _fail(reason: String) -> void:
	if error == "":
		error = reason
	close()
