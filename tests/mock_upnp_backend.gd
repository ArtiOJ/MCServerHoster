extends UpnpBackend
## In-memory stand-in for a UPnP router (tests never touch the real network).

var has_gateway := true
var external_ip := "203.0.113.7"
## Ports the fake router refuses to forward.
var refuse_ports := {}
## port -> description of active forwards
var forwards := {}
var lease_seen := -1


func discover() -> Dictionary:
	if not has_gateway:
		return {"ok": false, "external_ip": "", "error": "No router with UPnP was found on this network (no devices answered)."}
	return {"ok": true, "external_ip": external_ip, "error": ""}


func is_ready() -> bool:
	return has_gateway


func add_mapping(port: int, description: String, lease_sec: int) -> int:
	lease_seen = lease_sec
	if refuse_ports.has(port):
		return UPNP.UPNP_RESULT_NOT_AUTHORIZED
	forwards[port] = description
	return UPNP.UPNP_RESULT_SUCCESS


func delete_mapping(port: int) -> int:
	forwards.erase(port)
	return UPNP.UPNP_RESULT_SUCCESS
