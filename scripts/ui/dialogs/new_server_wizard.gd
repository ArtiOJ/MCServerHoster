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
const COLORS: Array[Color] = [Color("3fb97f"), Color("5aa9f2"), Color("c678dd"), Color("f2b84b"), Color("e06c75"), Color("56b6c2")]

var _page: Page = Page.BASICS
var _versions: Array[Dictionary] = []
var _version_info := {}
var _build := {}
var _request_serial := 0
var _installing := false
var _created: ServerInstance

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
@onready var _port_spin: SpinBox = %PortSpin
@onready var _port_status: Label = %PortStatus
@onready var _auto_start_check: CheckButton = %AutoStartCheck
@onready var _gamemode: OptionButton = %GamemodeOption
@onready var _difficulty: OptionButton = %DifficultyOption
@onready var _world_type: OptionButton = %WorldTypeOption
@onready var _max_players: SpinBox = %MaxPlayersSpin
@onready var _motd_edit: LineEdit = %MotdEdit
@onready var _seed_edit: LineEdit = %SeedEdit
@onready var _online_check: CheckButton = %OnlineModeCheck
@onready var _whitelist_check: CheckButton = %WhitelistCheck
@onready var _pvp_check: CheckButton = %PvpCheck
@onready var _hardcore_check: CheckButton = %HardcoreCheck
@onready var _summary_label: Label = %SummaryLabel
@onready var _eula_check: CheckBox = %EulaCheck
@onready var _install_status: Label = %InstallStatus
@onready var _install_progress: ProgressBar = %InstallProgress
@onready var _install_error: Label = %InstallError
@onready var _start_now_check: CheckBox = %StartNowCheck
@onready var _cancel_button: Button = %CancelButton
@onready var _back_button: Button = %BackButton
@onready var _next_button: Button = %NextButton


func _ready() -> void:
	close_requested.connect(_on_cancel)
	_cancel_button.pressed.connect(_on_cancel)
	_back_button.pressed.connect(_on_back)
	_next_button.pressed.connect(_on_next)
	_name_edit.text_changed.connect(_on_name_changed)
	_name_edit.text_submitted.connect(func(_t: String) -> void: _on_next())
	_show_pre.toggled.connect(func(_on: bool) -> void: _populate_versions())
	_reload_button.pressed.connect(func() -> void: _load_versions(true))
	_version_list.item_selected.connect(_on_version_selected)
	_port_spin.value_changed.connect(func(_v: float) -> void: _check_port())
	_eula_check.toggled.connect(func(_on: bool) -> void: _update_nav())
	var host_mb := PlatformBackend.get_current().host_memory_bytes() / 1048576
	_ram_field.max_value = maxi(1024, (host_mb / 256) * 256)


func open() -> void:
	_created = null
	_installing = false
	_build = {}
	_version_info = {}
	_name_edit.text = _suggest_name()
	_color_picker.color = COLORS[ServerManager.get_instances().size() % COLORS.size()]
	_ram_field.value = clampi(AppSettings.default_ram_mb, 1024, int(_ram_field.max_value))
	_port_spin.value = ServerManager.allocate_game_port()
	_auto_start_check.button_pressed = false
	_eula_check.button_pressed = false
	_show_pre.button_pressed = AppSettings.show_unstable_versions
	_motd_edit.text = ""
	_seed_edit.text = ""
	_install_error.visible = false
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
			can_next = not _build.is_empty()
		Page.RESOURCES:
			can_next = ServerManager.port_owner(int(_port_spin.value)) == null
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
	hide()
	if _created != null:
		server_created.emit(_created)


func _on_name_changed(text: String) -> void:
	_folder_label.text = "Folder: " + AppSettings.servers_root.path_join(Fmt.slugify(text))
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
	_version_details.text = "\n".join(lines)
	_update_nav()


# --- Resources --------------------------------------------------------------

func _check_port() -> void:
	var port := int(_port_spin.value)
	var clash := ServerManager.port_owner(port)
	if clash != null:
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
	return "\n".join([
		"Name:  %s" % _name_edit.text.strip_edges(),
		"Software:  Paper %s, build #%d" % [_selected_version(), _build.get("id", 0)],
		"Memory:  %s heap" % Fmt.megabytes(int(_ram_field.value)),
		"Port:  %d" % int(_port_spin.value),
		"Game mode:  %s · %s · up to %d players" % [_gamemode.get_item_text(_gamemode.selected), _difficulty.get_item_text(_difficulty.selected), int(_max_players.value)],
		"Online mode:  %s" % ("on (Mojang-verified accounts)" if _online_check.button_pressed else "OFF — anyone can join with any name"),
		"Folder:  %s" % AppSettings.servers_root.path_join(Fmt.slugify(_name_edit.text)),
	])


func _properties() -> Dictionary:
	var props := {
		"gamemode": _gamemode.get_item_text(_gamemode.selected).to_lower(),
		"difficulty": _difficulty.get_item_text(_difficulty.selected).to_lower(),
		"level-type": ["minecraft:normal", "minecraft:flat", "minecraft:large_biomes", "minecraft:amplified"][_world_type.selected],
		"max-players": str(int(_max_players.value)),
		"online-mode": str(_online_check.button_pressed).to_lower(),
		"white-list": str(_whitelist_check.button_pressed).to_lower(),
		"pvp": str(_pvp_check.button_pressed).to_lower(),
		"hardcore": str(_hardcore_check.button_pressed).to_lower(),
		"level-seed": _seed_edit.text.strip_edges(),
	}
	if _motd_edit.text.strip_edges() != "":
		props["motd"] = _motd_edit.text.strip_edges()
	return props


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
		"port": int(_port_spin.value),
		"properties": _properties(),
	}, func(stage: String, fraction: float) -> void:
		_install_status.text = stage
		_install_progress.value = fraction * 100.0)
	_installing = false
	if res.ok:
		_created = res.instance
		_created.config.auto_start = _auto_start_check.button_pressed
		_created.save_config()
		_install_status.text = "%s is ready." % _created.config.display_name
		_install_progress.value = 100.0
		Notifier.success("Created %s." % _created.config.display_name)
		if _start_now_check.button_pressed:
			_created.start()
	else:
		_install_status.text = "Installation failed."
		_install_error.text = res.error
		_install_error.visible = true
	_update_nav()
