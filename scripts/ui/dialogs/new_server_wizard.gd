class_name NewServerWizard
extends Window
## Step-by-step creation of a new Paper server: name → version → resources →
## gameplay → EULA → download & install.

signal server_created(instance: ServerInstance)

enum Page { BASICS, VERSION, RESOURCES, GAMEPLAY, REVIEW, INSTALL }

const PAGE_TITLES: PackedStringArray = [
	"Name your server", "Choose a Minecraft version", "Resources & network", "Gameplay defaults",
	"Review & accept the EULA", "Installing",
]
const ROW_SCENE := preload("res://scenes/components/property_row.tscn")
const SECTION_SCENE := preload("res://scenes/components/section_header.tscn")
const COLORS: Array[Color] = [Color("3fb97f"), Color("5aa9f2"), Color("c678dd"), Color("f2b84b"), Color("e06c75"), Color("56b6c2")]

var _page: Page = Page.BASICS
var _versions: Array[Dictionary] = []
var _version_info := {}
var _build := {}
var _request_serial := 0
var _installing := false
var _created: ServerInstance
## Rows in the "More settings" section and the version they were built for.
var _more_rows: Array[PropertyRow] = []
var _more_sections := {}
var _more_version := "-"
## Analysis of the optional starting world (WorldImporter.analyze), or {}.
var _world := {}
var _world_serial := 0
## Icon chosen before the server exists; saved right after creation.
var _pending_icon: Image

@onready var _step_label: Label = %StepLabel
@onready var _title_label: Label = %PageTitle
@onready var _pages: TabContainer = %Pages
@onready var _name_edit: LineEdit = %NameEdit
@onready var _color_picker: ColorPickerButton = %ColorPicker
@onready var _folder_label: Label = %FolderLabel
@onready var _show_pre: CheckButton = %ShowPreCheck
@onready var _reload_button: Button = %ReloadVersionsButton
@onready var _version_list: ItemList = %VersionList
@onready var _version_details: Label = %VersionDetails
@onready var _ram_field: SliderField = %RamField
@onready var _port_spin: PortField = %PortSpin
@onready var _port_status: Label = %PortStatus
@onready var _auto_start_check: CheckButton = %AutoStartCheck
@onready var _main_rows: VBoxContainer = %MainRows
@onready var _more_settings: FoldableContainer = %MoreSettings
@onready var _more_search: LineEdit = %MoreSearch
@onready var _more_list: VBoxContainer = %MoreList
@onready var _summary_label: Label = %SummaryLabel
@onready var _eula_check: CheckBox = %EulaCheck
@onready var _install_status: Label = %InstallStatus
@onready var _install_progress: ProgressBar = %InstallProgress
@onready var _install_error: Label = %InstallError
@onready var _start_now_check: CheckBox = %StartNowCheck
@onready var _cancel_button: Button = %CancelButton
@onready var _back_button: Button = %BackButton
@onready var _next_button: Button = %NextButton
@onready var _icon_view: ServerIconView = %IconView
@onready var _icon_editor: IconEditorDialog = %IconEditorDialog
@onready var _world_zip_button: Button = %WorldZipButton
@onready var _world_folder_button: Button = %WorldFolderButton
@onready var _world_clear_button: Button = %WorldClearButton
@onready var _world_info: Label = %WorldInfo
@onready var _world_zip_dialog: FileDialog = %WorldZipDialog
@onready var _world_folder_dialog: FileDialog = %WorldFolderDialog


func _ready() -> void:
	_icon_view.clicked.connect(func() -> void:
		_icon_editor.open_pending(_name_edit.text.strip_edges(), _motd_for_preview(), _pending_icon))
	_icon_editor.icon_ready.connect(func(icon: Image) -> void:
		_pending_icon = icon
		_refresh_icon_view())
	_color_picker.color_changed.connect(func(_c: Color) -> void: _refresh_icon_view())
	close_requested.connect(_on_cancel)
	_cancel_button.pressed.connect(_on_cancel)
	_back_button.pressed.connect(_on_back)
	_next_button.pressed.connect(_on_next)
	_name_edit.text_changed.connect(_on_name_changed)
	_name_edit.text_submitted.connect(func(_t: String) -> void: _on_next())
	_show_pre.toggled.connect(func(_on: bool) -> void: _populate_versions())
	_reload_button.pressed.connect(func() -> void: _load_versions(true))
	_version_list.item_selected.connect(_on_version_selected)
	_port_spin.port_changed.connect(func(_p: int, _ok: bool) -> void: _check_port())
	_eula_check.toggled.connect(func(_on: bool) -> void: _update_nav())
	_more_search.text_changed.connect(func(_t: String) -> void: _filter_more())
	_world_zip_button.pressed.connect(func() -> void: _world_zip_dialog.popup_centered())
	_world_folder_button.pressed.connect(func() -> void: _world_folder_dialog.popup_centered())
	_world_zip_dialog.file_selected.connect(_choose_world)
	_world_folder_dialog.dir_selected.connect(_choose_world)
	_world_clear_button.pressed.connect(_clear_world)
	var host_mb := PlatformBackend.get_current().host_memory_bytes() / 1048576
	_ram_field.max_value = maxi(1024, (host_mb / 256) * 256)


func open() -> void:
	_created = null
	_installing = false
	_build = {}
	_version_info = {}
	_name_edit.text = _suggest_name()
	_color_picker.color = COLORS[ServerManager.get_instances().size() % COLORS.size()]
	_pending_icon = null
	_ram_field.value = clampi(AppSettings.default_ram_mb, 1024, int(_ram_field.max_value))
	_port_spin.port = ServerManager.allocate_game_port()
	_auto_start_check.button_pressed = false
	_eula_check.button_pressed = false
	_show_pre.button_pressed = AppSettings.show_unstable_versions
	for row: PropertyRow in _main_rows.get_children():
		row.setup_entry(row.entry, str(row.entry.get("default", "")))
	_clear_more()
	_more_version = "-"
	_more_search.text = ""
	_more_settings.folded = true
	_install_error.visible = false
	_clear_world()
	_set_page(Page.BASICS)
	popup_centered()
	_name_edit.grab_focus.call_deferred()
	_name_edit.select_all.call_deferred()
	_on_name_changed(_name_edit.text)
	_check_port()
	if _versions.is_empty():
		_load_versions()


func _suggest_name() -> String:
	var n := ServerManager.get_instances().size() + 1
	return "Survival" if n == 1 else "Server %d" % n


func _set_page(page: Page) -> void:
	_page = page
	_pages.current_tab = page
	_step_label.text = "STEP %d OF %d" % [mini(page + 1, Page.INSTALL), Page.INSTALL] if page < Page.INSTALL else "INSTALLING"
	_title_label.text = PAGE_TITLES[page]
	if page == Page.GAMEPLAY and _more_version != _selected_version():
		rebuild_more_settings(_selected_version())
	if page == Page.REVIEW:
		_summary_label.text = _summary_text()
	_update_nav()


func _update_nav() -> void:
	_back_button.visible = _page > Page.BASICS and _page < Page.INSTALL
	_cancel_button.visible = _page < Page.INSTALL or (not _installing and _created == null)
	var can_next := true
	match _page:
		Page.BASICS:
			can_next = _name_edit.text.strip_edges().length() in range(1, 41)
		Page.VERSION:
			can_next = not _build.is_empty() and _world_problem() == ""
		Page.RESOURCES:
			can_next = _port_spin.is_valid() and ServerManager.port_owner(_port_spin.port) == null
		Page.REVIEW:
			can_next = _eula_check.button_pressed
		Page.INSTALL:
			can_next = not _installing
	_next_button.disabled = not can_next
	match _page:
		Page.REVIEW:
			_next_button.text = "Create server"
		Page.INSTALL:
			_next_button.text = "Open server" if _created != null else "Retry"
		_:
			_next_button.text = "Next"


func _on_next() -> void:
	if _next_button.disabled:
		return
	match _page:
		Page.REVIEW:
			_install()
		Page.INSTALL:
			if _created != null:
				hide()
				server_created.emit(_created)
			else:
				_install()
		_:
			_set_page((_page + 1) as Page)


func _on_back() -> void:
	if _page > Page.BASICS and not _installing:
		_set_page((_page - 1) as Page)


func _on_cancel() -> void:
	if _installing:
		return
	_clear_world()
	hide()
	if _created != null:
		server_created.emit(_created)


func _on_name_changed(text: String) -> void:
	_folder_label.text = "Folder: " + AppSettings.servers_root.path_join(Fmt.slugify(text))
	_refresh_icon_view()
	_update_nav()


# --- Versions -------------------------------------------------------------

func _load_versions(force := false) -> void:
	_version_details.text = "Loading versions from PaperMC…"
	_reload_button.disabled = true
	var res: Dictionary = await PaperApi.fetch_versions(force)
	_reload_button.disabled = false
	if not res.ok:
		_version_details.text = "Could not load versions: %s\nCheck your internet connection and press Reload." % res.error
		return
	_versions = res.versions
	_populate_versions()


func _populate_versions() -> void:
	var previous := _selected_version()
	_version_list.clear()
	var select_idx := -1
	for v in _versions:
		if v.prerelease and not _show_pre.button_pressed:
			continue
		var idx := _version_list.add_item(v.id + ("   pre-release" if v.prerelease else ""))
		_version_list.set_item_metadata(idx, v.id)
		if v.prerelease:
			_version_list.set_item_custom_fg_color(idx, Color("8b93a3"))
		if v.id == previous or (select_idx == -1 and previous == "" and not v.prerelease):
			select_idx = idx
	if select_idx >= 0:
		_version_list.select(select_idx)
		_version_list.ensure_current_is_visible()
		_on_version_selected(select_idx)
	if _world.get("ok", false) and previous == "":
		_select_version(str(_world.version))


func _selected_version() -> String:
	var sel := _version_list.get_selected_items()
	return str(_version_list.get_item_metadata(sel[0])) if not sel.is_empty() else ""


func _on_version_selected(idx: int) -> void:
	var version := str(_version_list.get_item_metadata(idx))
	_build = {}
	_version_info = {}
	_update_nav()
	_request_serial += 1
	var serial := _request_serial
	_version_details.text = "Checking Paper %s…" % version
	var info: Dictionary = await PaperApi.fetch_version_info(version)
	if serial != _request_serial:
		return
	var latest: Dictionary = await PaperApi.fetch_latest_build(version, true)
	if serial != _request_serial:
		return
	if not info.ok or not latest.ok:
		_version_details.text = "Could not load details for %s: %s" % [version, info.get("error", latest.get("error", "unknown error"))]
		return
	_version_info = info
	_build = latest.build
	var lines := PackedStringArray()
	lines.append("Paper %s — build #%d (%s), %s" % [version, _build.id, str(_build.channel).to_lower(), Fmt.bytes(_build.size)])
	var java := JavaRuntimes.best_for(info.java_min)
	if java != null:
		lines.append("Requires Java %d+ → will use %s" % [info.java_min, java.display_name()])
	else:
		lines.append("⚠ Requires Java %d+, which is not installed. You can still create the server and install Java later." % info.java_min)
	if info.support == "UNSUPPORTED":
		lines.append("⚠ This version no longer receives fixes or security updates from PaperMC.")
	if _build.channel != "STABLE":
		lines.append("⚠ This is an experimental (%s) build. Expect bugs and back up often." % str(_build.channel).to_lower())
	var world_problem := _world_problem()
	if world_problem != "":
		lines.append("✕ " + world_problem)
	elif _world.get("ok", false) and str(_world.version) != "" and Fmt.compare_versions(str(_world.version), version) < 0:
		lines.append("⚠ The world (saved in %s) will be upgraded to %s on first start." % [_world.version, version])
	_version_details.text = "\n".join(lines)
	_update_nav()


# --- Resources --------------------------------------------------------------

func _check_port() -> void:
	var port := _port_spin.port
	var clash := ServerManager.port_owner(port)
	if not _port_spin.is_valid():
		_port_status.text = "✕ " + _port_spin.error_text()
		_port_status.add_theme_color_override("font_color", Color("e05555"))
	elif clash != null:
		_port_status.text = "✕ Used by %s" % clash.config.display_name
		_port_status.add_theme_color_override("font_color", Color("e05555"))
	elif not PlatformBackend.is_port_free(port):
		_port_status.text = "⚠ Another program is listening on this port"
		_port_status.add_theme_color_override("font_color", Color("f2b84b"))
	else:
		_port_status.text = "✓ Available" + ("" if port == 25565 else " — players connect with :%d" % port)
		_port_status.add_theme_color_override("font_color", Color("3fb97f"))
	_update_nav()


# --- Review & install -----------------------------------------------------

func _summary_text() -> String:
	var players := _main_value("max-players")
	var seed_text := _main_value("level-seed")
	var extra := _more_rows.filter(func(r: PropertyRow) -> bool: return r.is_modified()).size()
	var lines := PackedStringArray([
		"Name:  %s" % _name_edit.text.strip_edges(),
		"Software:  Paper %s, build #%d" % [_selected_version(), _build.get("id", 0)],
		"Memory:  %s heap" % Fmt.megabytes(int(_ram_field.value)),
		"Port:  %d" % _port_spin.port,
		"Game mode:  %s · %s · up to %s players" % [_main_value("gamemode"), _main_value("difficulty"), players],
		"World:  %s · seed %s" % [_main_value("level-type").trim_prefix("minecraft:"), seed_text if seed_text != "" else "random"],
		"MOTD:  %s" % _main_value("motd"),
	])
	if extra > 0:
		lines.append("%d additional setting%s changed" % [extra, "" if extra == 1 else "s"])
	if _world.get("ok", false):
		lines.append("Starting world:  %s (Minecraft %s) — its game mode and difficulty are applied" % [_world_title(), _world.version if _world.version != "" else "unknown"])
	lines.append("Folder:  %s" % AppSettings.servers_root.path_join(Fmt.slugify(_name_edit.text)))
	return "\n".join(lines)


func _main_value(id: String) -> String:
	for row: PropertyRow in _main_rows.get_children():
		if row.key == id:
			return row.get_value()
	return ""


## Settings that differ from the defaults (entry id -> value), passed to ServerManager.create_server().
func settings_spec() -> Dictionary:
	var out := {}
	for row: PropertyRow in _main_rows.get_children():
		if row.is_modified():
			out[row.key] = row.get_value()
	for row in _more_rows:
		if row.is_modified():
			out[row.key] = row.get_value()
	return out


# --- More settings ---------------------------------------------------------

## Fills the "More settings" section with every catalog setting that applies to
## [param version], keeping values the user already changed where they still apply.
func rebuild_more_settings(version: String) -> void:
	var kept := {}
	for row in _more_rows:
		if row.is_modified():
			kept[row.key] = row.get_value()
	_clear_more()
	_more_version = version
	var by_category := {}
	for e in SettingsCatalog.for_version(version):
		if SettingsCatalog.MAIN_IDS.has(e.id) or (e.source == "property" and PropertySchema.is_managed(e.key)):
			continue
		var cat := SettingsTab._category_of(e)
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(e)
	for cat in SettingsCatalog.CATEGORIES:
		if not by_category.has(cat):
			continue
		var section: SectionHeader = SECTION_SCENE.instantiate()
		section.title = cat
		_more_list.add_child(section)
		var rows: Array[PropertyRow] = []
		for e: Dictionary in by_category[cat]:
			var row: PropertyRow = ROW_SCENE.instantiate()
			row.setup_entry(e, str(e.get("default", "")))
			_more_list.add_child(row)
			if kept.has(e.id):
				row.set_value(kept[e.id])
			rows.append(row)
			_more_rows.append(row)
		_more_sections[section] = rows
	_filter_more()


## Row editing [param id] in the "More settings" section, or null.
func more_row(id: String) -> PropertyRow:
	for row in _more_rows:
		if row.key == id:
			return row
	return null


func _clear_more() -> void:
	for child in _more_list.get_children():
		_more_list.remove_child(child)
		child.queue_free()
	_more_rows.clear()
	_more_sections.clear()


func _filter_more() -> void:
	var filter := _more_search.text
	for section: SectionHeader in _more_sections:
		var any := false
		for row: PropertyRow in _more_sections[section]:
			row.visible = row.matches(filter)
			any = any or row.visible
		section.visible = any


func _install() -> void:
	_installing = true
	_install_error.visible = false
	_install_progress.value = 0.0
	_set_page(Page.INSTALL)
	var ram := int(_ram_field.value)
	var res: Dictionary = await ServerManager.create_server({
		"name": _name_edit.text.strip_edges(),
		"color": _color_picker.color,
		"version": _selected_version(),
		"build": _build,
		"version_info": _version_info,
		"ram_max_mb": ram,
		"ram_min_mb": clampi(ram / 4, 512, ram),
		"port": _port_spin.port,
		"settings": settings_spec(),
	}, func(stage: String, fraction: float) -> void:
		_install_status.text = stage
		_install_progress.value = fraction * 100.0)
	_installing = false
	if res.ok:
		_created = res.instance
		_created.config.auto_start = _auto_start_check.button_pressed
		_created.save_config()
		if _pending_icon != null and ServerIcon.save(_created.config.directory, _pending_icon) == OK:
			_created.config_changed.emit()
		var world_ok := await _import_world_into(_created)
		_install_status.text = "%s is ready." % _created.config.display_name
		_install_progress.value = 100.0
		Notifier.success("Created %s." % _created.config.display_name)
		if _start_now_check.button_pressed and world_ok:
			_created.start()
	else:
		_install_status.text = "Installation failed."
		_install_error.text = res.error
		_install_error.visible = true
	_update_nav()


# --- Starting world ---------------------------------------------------------

func _choose_world(path: String) -> void:
	_world_serial += 1
	var serial := _world_serial
	WorldImporter.cleanup(_world)
	_world = {}
	_world_info.text = "Reading the world…"
	_world_info.tooltip_text = path
	var result: Dictionary = await WorldImporter.analyze(self, path, "")
	if serial != _world_serial:
		WorldImporter.cleanup(result)
		return
	if not result.ok:
		WorldImporter.cleanup(result)
		_world_info.text = "✕ " + result.error
		_world_clear_button.visible = true
		return
	_world = result
	var dims := ", ".join(result.dimensions) if not result.dimensions.is_empty() else "no terrain yet"
	_world_info.text = "%s — Minecraft %s (%s)" % [_world_title(), result.version if result.version != "" else "unknown", dims]
	_world_info.tooltip_text = "%s\n%s" % [path, "\n".join(result.warnings)]
	_world_clear_button.visible = true
	var world_name := WorldImporter.display_name(result)
	if _name_edit.text.strip_edges() == _suggest_name() and world_name.to_lower() != "world":
		_name_edit.text = world_name.left(40)
		_on_name_changed(_name_edit.text)
	if result.version != "":
		_select_version(str(result.version))
	_update_nav()


func _clear_world() -> void:
	_world_serial += 1
	WorldImporter.cleanup(_world)
	_world = {}
	_world_info.text = "New world"
	_world_info.tooltip_text = ""
	_world_clear_button.visible = false
	_update_nav()


func _world_title() -> String:
	return WorldImporter.display_name(_world)


## Selects [param version] on the Version page if Paper offers it.
func _select_version(version: String) -> void:
	for i in _version_list.item_count:
		if str(_version_list.get_item_metadata(i)) == version:
			_version_list.select(i)
			_version_list.ensure_current_is_visible()
			_on_version_selected(i)
			return


## Why the chosen starting world can't run on the selected version, or "".
func _world_problem() -> String:
	if not _world.get("ok", false):
		return ""
	var version := _selected_version()
	if version == "" or str(_world.version) == "":
		return ""
	if Fmt.compare_versions(str(_world.version), version) > 0:
		return "The starting world was saved in Minecraft %s; pick %s or newer." % [_world.version, _world.version]
	if _world.layout == WorldImporter.Layout.DIMENSIONS and Fmt.compare_versions(version, "26.1") < 0:
		return "The starting world uses the Minecraft 26+ format; pick a 26.x version."
	return ""


## Imports the starting world (if any) into a freshly created server. Returns false if it failed.
func _import_world_into(inst: ServerInstance) -> bool:
	if not _world.get("ok", false):
		return true
	_install_status.text = "Importing the world…"
	var result: Dictionary = await WorldImporter.import_into(inst, _world, WorldImporter.Mode.REPLACE, true,
			func(text: String) -> void: _install_status.text = text)
	WorldImporter.cleanup(_world)
	_world = {}
	if not result.ok:
		_install_error.text = "The server was created, but importing the world failed: %s" % result.error
		_install_error.visible = true
		return false
	return true


# --- Server icon ------------------------------------------------------------

func _refresh_icon_view() -> void:
	var tex: Texture2D = ImageTexture.create_from_image(_pending_icon) if _pending_icon != null else null
	_icon_view.show_texture(tex, _name_edit.text, _color_picker.color)


func _motd_for_preview() -> String:
	for row: PropertyRow in _main_rows.get_children():
		if row.key == "motd":
			return row.get_value()
	return "A Minecraft Server"
