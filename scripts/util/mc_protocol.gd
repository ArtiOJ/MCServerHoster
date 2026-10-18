class_name McProtocol
extends RefCounted
## Just enough of the Minecraft Java protocol for the wake-on-connect listener:
## packet framing, VarInts, strings, and the handshake/status/login packets.
## Reference: https://minecraft.wiki/w/Java_Edition_protocol

const STATE_STATUS := 1
const STATE_LOGIN := 2
const STATE_TRANSFER := 3


static func write_varint(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	var v := value & 0xFFFFFFFF
	while true:
		if v & ~0x7F == 0:
			out.append(v)
			return out
		out.append((v & 0x7F) | 0x80)
		v >>= 7
	return out


## Reads a VarInt at [param offset]. Returns [value, bytes_used], or [] if incomplete/invalid.
static func read_varint(data: PackedByteArray, offset: int) -> Array:
	var value := 0
	for i in 5:
		if offset + i >= data.size():
			return []
		var b := data[offset + i]
		value |= (b & 0x7F) << (7 * i)
		if b & 0x80 == 0:
			if value & 0x80000000:
				value -= 0x100000000
			return [value, i + 1]
	return []


static func write_string(text: String) -> PackedByteArray:
	var bytes := text.to_utf8_buffer()
	var out := write_varint(bytes.size())
	out.append_array(bytes)
	return out


## Reads a length-prefixed UTF-8 string. Returns [text, bytes_used], or [] if incomplete.
static func read_string(data: PackedByteArray, offset: int) -> Array:
	var len_info := read_varint(data, offset)
	if len_info.is_empty() or len_info[0] < 0:
		return []
	var start: int = offset + len_info[1]
	var end: int = start + len_info[0]
	if end > data.size():
		return []
	return [data.slice(start, end).get_string_from_utf8(), end - offset]


## Frames a packet: VarInt length, VarInt packet id, payload.
static func packet(id: int, payload := PackedByteArray()) -> PackedByteArray:
	var body := write_varint(id)
	body.append_array(payload)
	var out := write_varint(body.size())
	out.append_array(body)
	return out


## Splits the first complete packet off [param buffer].
## Returns {"id", "payload", "size"} or {} when more bytes are needed; {"error": true} if malformed.
static func take_packet(buffer: PackedByteArray) -> Dictionary:
	var len_info := read_varint(buffer, 0)
	if len_info.is_empty():
		return {"error": true} if buffer.size() >= 5 else {}
	var length: int = len_info[0]
	if length <= 0 or length > 32768:
		return {"error": true}
	var total: int = len_info[1] + length
	if buffer.size() < total:
		return {}
	var id_info := read_varint(buffer, len_info[1])
	if id_info.is_empty():
		return {"error": true}
	return {"id": id_info[0], "payload": buffer.slice(len_info[1] + id_info[1], total), "size": total}


## Parses a Handshake payload into {protocol, address, port, next_state}, or {} if malformed.
static func parse_handshake(payload: PackedByteArray) -> Dictionary:
	var proto := read_varint(payload, 0)
	if proto.is_empty():
		return {}
	var addr := read_string(payload, proto[1])
	if addr.is_empty():
		return {}
	var offset: int = proto[1] + addr[1]
	if offset + 2 > payload.size():
		return {}
	var port := (payload[offset] << 8) | payload[offset + 1]
	var next := read_varint(payload, offset + 2)
	if next.is_empty():
		return {}
	return {"protocol": proto[0], "address": addr[0], "port": port, "next_state": next[0]}


static func handshake(protocol: int, address: String, port: int, next_state: int) -> PackedByteArray:
	var payload := write_varint(protocol)
	payload.append_array(write_string(address))
	payload.append_array(PackedByteArray([(port >> 8) & 0xFF, port & 0xFF]))
	payload.append_array(write_varint(next_state))
	return packet(0x00, payload)


## Status response JSON, as shown in the client's server list.
static func status_json(version_name: String, protocol: int, motd: String, max_players: int, online := 0) -> String:
	return JSON.stringify({
		"version": {"name": version_name, "protocol": protocol},
		"players": {"max": max_players, "online": online, "sample": []},
		"description": {"text": motd},
		"enforcesSecureChat": false,
	})


## Login-state Disconnect packet carrying a JSON text component.
static func login_disconnect(message: String) -> PackedByteArray:
	return packet(0x00, write_string(JSON.stringify({"text": message})))
