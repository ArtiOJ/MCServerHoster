class_name ServerSource
extends Node
## A set of servers the interface can show: this computer's ([code]ServerManager[/code]) or
## another computer's ([RemoteLink]) for someone connected as its system admin.

signal server_added(handle: ServerHandle)
signal server_removed(key: String)
signal server_state_changed(handle: ServerHandle)
## The load figures of the computer changed (see [method host_stats]).
signal host_stats_changed


## Name of the computer, as shown in the host switcher.
func source_name() -> String:
	return "This computer"


func is_remote_source() -> bool:
	return false


func get_handles() -> Array[ServerHandle]:
	return []


func find_handle(handle_key: String) -> ServerHandle:
	for h in get_handles():
		if h.key() == handle_key:
			return h
	return null


func running_count() -> int:
	return get_handles().filter(func(h: ServerHandle) -> bool: return h.is_process_alive()).size()


## RAM (MB) reserved by servers whose process is alive.
func allocated_ram_mb() -> int:
	var total := 0
	for h in get_handles():
		if h.is_process_alive():
			total += h.config.ram_max_mb
	return total


func start_all() -> void:
	pass


func stop_all() -> void:
	pass


## True when servers can be created, imported, duplicated and deleted here.
func can_manage_servers() -> bool:
	return true


## {cpu (percent), cores, mem_total, mem_used (bytes), allocated_mb}, or {} when the view
## should sample this computer itself.
func host_stats() -> Dictionary:
	return {}


## See ServerManager.create_server; [param spec] carries a "build_id" instead of the build.
func create_server_remote(_spec: Dictionary, _on_progress := Callable()) -> Dictionary:
	return {"ok": false, "error": "Not available."}


func delete_handle(_handle: ServerHandle, _delete_files := true, _delete_backups := false) -> Dictionary:
	return {"ok": false, "error": "Not available."}


func duplicate_handle(_handle: ServerHandle, _display_name: String, _copy_worlds := true, _copy_plugins := true, _on_status := Callable()) -> Dictionary:
	return {"ok": false, "error": "Not available."}
