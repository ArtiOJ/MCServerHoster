class_name PluginResultRow
extends PanelContainer
## One plugin in the plugin browser: icon, name, author, description and downloads, with
## an Install / Update button once its compatibility with the server is known.

signal install_requested(row: PluginResultRow)

enum Status { CHECKING, INSTALL, UPDATE, INSTALLED, BUSY }

## The Modrinth search hit (see ModrinthApi.search).
var hit := {}
## The build that would be installed (ModrinthApi.compatible_version), once known.
var version := {}
## The built-in integration this plugin has ({} for others).
var integration := {}

@onready var _icon: TextureRect = %Icon
@onready var _title: Label = %TitleLabel
@onready var _badge: Label = %BadgeLabel
@onready var _author: Label = %AuthorLabel
@onready var _desc: Label = %DescLabel
@onready var _meta: Label = %MetaLabel
@onready var _install_button: Button = %InstallButton
@onready var _page_button: Button = %PageButton


func _ready() -> void:
	_install_button.pressed.connect(func() -> void: install_requested.emit(self))
	_page_button.pressed.connect(func() -> void: OS.shell_open(ModrinthApi.SITE + str(hit.get("slug", hit.get("project_id", "")))))
	_show()


func setup(p_hit: Dictionary, p_integration := {}) -> void:
	hit = p_hit
	integration = p_integration
	if is_node_ready():
		_show()


func _show() -> void:
	_title.text = str(hit.get("title", ""))
	_author.text = "by %s" % hit.author if str(hit.get("author", "")) != "" else ""
	_desc.text = str(hit.get("description", ""))
	_desc.tooltip_text = _desc.text
	var parts := PackedStringArray()
	parts.append("%s downloads" % _count(int(hit.get("downloads", 0))))
	if str(hit.get("date_modified", "")) != "":
		parts.append("updated %s" % str(hit.date_modified).left(10))
	_meta.text = " · ".join(parts)
	_badge.visible = not integration.is_empty()
	_badge.text = "Built in: %s" % integration.get("feature", "")
	_badge.tooltip_text = "Server Manager has its own %s for this plugin." % integration.get("feature", "")


static func _count(n: int) -> String:
	if n >= 1_000_000:
		return "%.1fM" % (n / 1_000_000.0)
	if n >= 1_000:
		return "%.1fk" % (n / 1_000.0)
	return str(n)


func set_icon(tex: Texture2D) -> void:
	if tex != null:
		_icon.texture = tex


## Shows what the button would do: install, update the installed build, or nothing.
func set_status(status: Status) -> void:
	_install_button.disabled = status in [Status.CHECKING, Status.INSTALLED, Status.BUSY]
	_install_button.text = ["Checking…", "Install", "Update", "Installed", "Installing…"][status]
	_install_button.theme_type_variation = &"AccentButton" if status in [Status.INSTALL, Status.UPDATE] else &""
	var build := str(version.get("version_number", ""))
	_install_button.tooltip_text = ("Version %s for this server" % build) if build != "" else ""
	if status == Status.INSTALL and not integration.is_empty():
		_install_button.tooltip_text = "Installs the latest release from the plugin's own site."
