class_name PluginBrowserDialog
extends AcceptDialog
## Finds plugins on Modrinth for one server: plugins Server Manager integrates with first,
## then search results, each checked for a Paper/Spigot/Bukkit build that lists the server's
## Minecraft version (others are left out). Searching runs here; installing runs on the
## server's computer (ServerOps.plugin_install_modrinth), so remote servers work the same.

const ROW_SCENE := preload("res://scenes/components/plugin_result_row.tscn")

var _handle: ServerHandle
var _version := ""
var _offset := 0
var _total := 0
var _hidden := 0
var _checking := 0
## Bumped by every new search; results of older ones are dropped.
var _serial := 0
## Installed plugins that came from Modrinth: project id -> version id.
var _installed := {}
## plugin.yml names of every installed plugin, lower case (built-in integrations may come
## from their own site, which Modrinth doesn't recognise).
var _installed_names := {}
var _integration_ids := {}

@onready var _search_edit: LineEdit = %SearchEdit
@onready var _sort_option: OptionButton = %SortOption
@onready var _filter_label: Label = %FilterLabel
@onready var _scroll: ScrollContainer = %Scroll
@onready var _built_in_header: Label = %BuiltInHeader
@onready var _built_in_list: VBoxContainer = %BuiltInList
@onready var _results_header: Label = %ResultsHeader
@onready var _results_list: VBoxContainer = %ResultsList
@onready var _load_more_button: Button = %LoadMoreButton
@onready var _status_label: Label = %StatusLabel
@onready var _search_timer: Timer = %SearchTimer


func _ready() -> void:
	for name in ModrinthApi.SORT_NAMES:
		_sort_option.add_item(name)
	_search_edit.text_changed.connect(func(_t: String) -> void: _search_timer.start())
	_search_edit.text_submitted.connect(func(_t: String) -> void:
		_search_timer.stop()
		_search(true))
	_search_timer.timeout.connect(_search.bind(true))
	_sort_option.item_selected.connect(func(_i: int) -> void: _search(true))
	_load_more_button.pressed.connect(_search.bind(false))


## Shows plugins for [param handle]'s server.
func open(handle: ServerHandle) -> void:
	_handle = handle
	_version = handle.config.mc_version
	title = "Get plugins for %s" % handle.config.display_name
	_filter_label.text = "Paper, Spigot and Bukkit plugins for Minecraft %s, from modrinth.com" % _version
	_search_edit.text = ""
	_sort_option.select(0)
	popup_centered()
	_search_edit.grab_focus()
	await _load_installed()
	_search(true)


func _load_installed() -> void:
	_installed.clear()
	_installed_names.clear()
	var h := _handle
	var list: Dictionary = await h.call_op("plugins_list")
	if h != _handle or not list.ok:
		return
	var hashes := []
	for p in list.plugins:
		_installed_names[str(p.name).to_lower()] = true
		if str(p.get("sha1", "")) != "":
			hashes.append(str(p.sha1))
	var found: Dictionary = await ModrinthApi.lookup_sha1(self, hashes)
	if found.ok:
		for sha in found.found:
			_installed[str(found.found[sha].project_id)] = str(found.found[sha].version_id)


func _search(reset: bool) -> void:
	if _handle == null:
		return
	_serial += 1
	var serial := _serial
	var query := _search_edit.text.strip_edges()
	if reset:
		_offset = 0
		_hidden = 0
		for list in [_built_in_list, _results_list]:
			for child in list.get_children():
				child.queue_free()
		_scroll.scroll_vertical = 0
		await _show_integrations(query, serial)
		if serial != _serial:
			return
	_load_more_button.visible = false
	_status_label.text = "Searching…"
	var res: Dictionary = await ModrinthApi.search(self, query, _version, _offset, ModrinthApi.SORTS[_sort_option.selected])
	if serial != _serial:
		return
	if not res.ok:
		_status_label.text = str(res.error)
		return
	_total = int(res.total)
	_offset += ModrinthApi.PAGE_SIZE
	for hit in res.hits:
		if _integration_ids.has(hit.project_id):
			continue
		var row := _add_row(_results_list, hit, {})
		_check(row, serial)
	_results_header.visible = _results_list.get_child_count() > 0 or _total > 0
	_load_more_button.visible = _offset < _total
	_update_status()


## Plugins Server Manager integrates with, shown first when they match the search and have a
## build for this server.
func _show_integrations(query: String, serial: int) -> void:
	_integration_ids.clear()
	var shown := 0
	for integration in ModrinthApi.INTEGRATIONS:
		var res: Dictionary = await ModrinthApi.project(self, integration.slug)
		if serial != _serial:
			return
		if not res.ok:
			continue
		var p: Dictionary = res.project
		_integration_ids[p.project_id] = true
		var text := ("%s %s" % [p.title, p.description]).to_lower()
		var compatible: bool = (p.game_versions as Array).has(_version) and Array(ModrinthApi.LOADERS).any(func(l: String) -> bool: return (p.loaders as Array).has(l))
		if not compatible or (query != "" and not text.contains(query.to_lower())):
			continue
		var row := _add_row(_built_in_list, p, integration)
		_check(row, serial)
		shown += 1
	_built_in_header.visible = shown > 0


func _add_row(list: VBoxContainer, hit: Dictionary, integration: Dictionary) -> PluginResultRow:
	var row: PluginResultRow = ROW_SCENE.instantiate()
	row.setup(hit, integration)
	list.add_child(row)
	row.install_requested.connect(_install)
	row.set_status(PluginResultRow.Status.CHECKING)
	_load_icon(row, str(hit.icon_url))
	return row


func _load_icon(row: PluginResultRow, url: String) -> void:
	var tex := await ModrinthApi.icon(self, url)
	if is_instance_valid(row):
		row.set_icon(tex)


## Finds the build this server would get; rows without one are left out.
func _check(row: PluginResultRow, serial: int) -> void:
	_checking += 1
	var res: Dictionary = await ModrinthApi.compatible_version(self, str(row.hit.project_id), _version)
	_checking -= 1
	if serial != _serial or not is_instance_valid(row):
		return
	if res.ok and (res.version as Dictionary).is_empty():
		_hidden += 1
		row.queue_free()
	else:
		row.version = res.get("version", {})
		_show_status(row)
	_update_status()


func _show_status(row: PluginResultRow) -> void:
	var pid := str(row.hit.project_id)
	if not row.integration.is_empty() and _installed_names.has(str(row.integration.plugin_name).to_lower()):
		row.set_status(PluginResultRow.Status.INSTALLED)
	elif not _installed.has(pid):
		row.set_status(PluginResultRow.Status.INSTALL)
	elif row.version.is_empty() or _installed[pid] == str(row.version.get("id", "")) or not row.integration.is_empty():
		row.set_status(PluginResultRow.Status.INSTALLED)
	else:
		row.set_status(PluginResultRow.Status.UPDATE)


func _update_status() -> void:
	var shown := 0
	for list in [_built_in_list, _results_list]:
		for child in list.get_children():
			if not child.is_queued_for_deletion():
				shown += 1
	var parts := PackedStringArray()
	if _checking > 0:
		parts.append("Checking which plugins run on %s…" % _version)
	elif shown <= 0 and _offset >= _total:
		parts.append("No plugins found for Minecraft %s." % _version)
	if _hidden > 0:
		parts.append("%d left out: no build for Minecraft %s." % [_hidden, _version])
	_status_label.text = " ".join(parts)


func _install(row: PluginResultRow) -> void:
	var h := _handle
	row.set_status(PluginResultRow.Status.BUSY)
	var title := str(row.hit.title)
	var op := str(row.integration.get("install_op", ""))
	var res: Dictionary = await h.call_op(op, {}) if op != "" else await h.call_op("plugin_install_modrinth", {"project_id": str(row.hit.project_id)})
	if not is_instance_valid(row):
		return
	if not res.ok:
		Notifier.error(str(res.error))
		_show_status(row)
		return
	_installed[str(row.hit.project_id)] = str(row.version.get("id", ""))
	if not row.integration.is_empty():
		_installed_names[str(row.integration.plugin_name).to_lower()] = true
	row.set_status(PluginResultRow.Status.INSTALLED)
	var names := PackedStringArray()
	for d in res.get("installed", []):
		names.append("%s %s" % [d.title, d.version])
		_installed[str(d.get("project_id", ""))] = ""
	var what := ", ".join(names) if not names.is_empty() else title
	var when := "Restart %s to load it." % h.config.display_name if h.is_process_alive() else "It loads when %s starts." % h.config.display_name
	Notifier.success("Installed %s. %s" % [what, when])
	for warning in res.get("warnings", []):
		Notifier.warn(str(warning))
