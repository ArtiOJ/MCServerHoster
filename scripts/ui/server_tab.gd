class_name ServerTab
extends MarginContainer
## Base class for the tabs inside the server view. [method bind] switches which
## server the tab shows; signal connections made through [method watch] are
## dropped automatically when the bound server changes.
##
## Tabs that work through [ServerHandle] alone set [member remote_ready] and use
## [member handle]; they also show servers on other computers. The others use
## [member instance] (this computer's servers only) and are hidden for remote servers.

## True when the tab works for servers on other computers too.
@export var remote_ready := false

## The server shown, local or remote.
var handle: ServerHandle
## The server shown when it runs on this computer, else null.
var instance: ServerInstance

var _connections: Array[Array] = []


## Shows [param h]. Returns false when this tab cannot show it (a remote server in a
## tab that is not [member remote_ready]); the view hides the tab then.
func bind(h: ServerHandle) -> bool:
	for pair in _connections:
		var sig: Signal = pair[0]
		if not sig.is_null() and sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	_connections.clear()
	var usable := h == null or h is ServerInstance or remote_ready
	handle = h if usable else null
	instance = h as ServerInstance if usable else null
	if handle != null:
		_on_bound()
	return usable


## Connects [param callable] to [param sig] for as long as the current server is bound.
func watch(sig: Signal, callable: Callable) -> void:
	sig.connect(callable)
	_connections.append([sig, callable])


## Override: connect signals with watch() and refresh the UI for [member instance].
func _on_bound() -> void:
	pass
