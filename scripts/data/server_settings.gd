class_name ServerSettings
extends RefCounted
## Reads and writes catalog settings for one server, whichever file stores them.
## server.properties and YAML files are edited in place (Paper fills in any keys a
## partial file lacks on boot, so this also works before the first start). Game
## rules live inside the world, so changes are queued in the server's config and
## applied through the console once the server is running.

var config: ServerConfig
var directory := ""

var _props: ServerProperties
var _props_dirty := false
var _docs := {}
var _dirty_docs := {}
var _rule_changes := {}


static func open(cfg: ServerConfig, dir := "") -> ServerSettings:
	var s := ServerSettings.new()
	s.config = cfg
	s.directory = dir if dir != "" else cfg.directory
	s._props = ServerProperties.load_file(s.directory.path_join("server.properties"))
	return s


## Catalog entries for this server's Minecraft version, plus unknown server.properties keys.
func entries() -> Array[Dictionary]:
	var out := SettingsCatalog.for_version(config.mc_version)
	var known := {}
	for e in out:
		if e.source == "property":
			known[e.key] = true
	for key in _props.keys():
		if not known.has(key) and not PropertySchema.is_managed(key) and SettingsCatalog.get_entry(key).is_empty():
			out.append(SettingsCatalog.unknown_property_entry(key, _props.get_value(key)))
	return out


func get_value(entry: Dictionary) -> String:
	match entry.source:
		"yaml":
			return _doc(entry.file).get_value(entry.key, entry.default)
		"gamerule":
			if _rule_changes.has(entry.id):
				return _rule_changes[entry.id]
			return str(config.pending_gamerules.get(entry.id, config.known_gamerules.get(entry.id, entry.default)))
	return _props.get_value(entry.key, entry.default)


## True when the value is stored explicitly (not just the catalog default).
func is_explicit(entry: Dictionary) -> bool:
	match entry.source:
		"yaml":
			return _doc(entry.file).has(entry.key)
		"gamerule":
			return config.pending_gamerules.has(entry.id) or config.known_gamerules.has(entry.id)
	return _props.has(entry.key)


func set_value(entry: Dictionary, value: String) -> void:
	match entry.source:
		"yaml":
			var is_string: bool = entry.type == PropertySchema.Type.STRING
			_doc(entry.file).set_value(entry.key, YamlDoc.format_scalar(value, is_string))
			_dirty_docs[entry.file] = true
		"gamerule":
			_rule_changes[entry.id] = value
		_:
			_props.set_value(entry.key, value)
			_props_dirty = true


func set_by_id(id: String, value: String) -> void:
	var entry := SettingsCatalog.get_entry(id)
	if entry.is_empty():
		entry = SettingsCatalog.unknown_property_entry(id, value)
	set_value(entry, value)


## Game rule changes made since opening (entry id -> value).
func gamerule_changes() -> Dictionary:
	return _rule_changes.duplicate()


func is_dirty() -> bool:
	return _props_dirty or not _dirty_docs.is_empty() or not _rule_changes.is_empty()


## Writes changed files. Game rule changes are queued in the config ([member ServerConfig.pending_gamerules]);
## the caller applies them immediately if the server is online.
func save() -> Error:
	if _props_dirty:
		var err := _props.save_file(directory.path_join("server.properties"))
		if err != OK:
			return err
	for file in _dirty_docs:
		var err := (_docs[file] as YamlDoc).save_file(directory.path_join(file))
		if err != OK:
			return err
	if not _rule_changes.is_empty():
		config.pending_gamerules.merge(_rule_changes, true)
		var err := config.save()
		if err != OK:
			return err
	_props_dirty = false
	_dirty_docs.clear()
	_rule_changes.clear()
	return OK


func _doc(file: String) -> YamlDoc:
	if not _docs.has(file):
		_docs[file] = YamlDoc.load_file(directory.path_join(file))
	return _docs[file]
