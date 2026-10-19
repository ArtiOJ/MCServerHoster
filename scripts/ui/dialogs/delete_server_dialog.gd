class_name DeleteServerDialog
extends ConfirmationDialog
## Confirms deleting a server; the user must type the server's name.

var _instance: ServerHandle

@onready var _message: Label = %Message
@onready var _name_edit: LineEdit = %NameEdit
@onready var _delete_files: CheckBox = %DeleteFilesCheck
@onready var _delete_backups: CheckBox = %DeleteBackupsCheck


func _ready() -> void:
	get_ok_button().theme_type_variation = &"DangerButton"
	_name_edit.text_changed.connect(func(_t: String) -> void: _validate())
	_name_edit.text_submitted.connect(func(_t: String) -> void:
		if not get_ok_button().disabled:
			_on_confirmed()
			hide())
	confirmed.connect(_on_confirmed)


func open(inst: ServerHandle) -> void:
	_instance = inst
	title = "Delete %s?" % inst.config.display_name
	var folder := inst.folder_path() + (" on " + inst.host_name() if inst.is_remote() else "")
	_message.text = "This permanently deletes \"%s\". It cannot be undone.\nFolder: %s\n\nType the server name to confirm." % [inst.config.display_name, folder]
	_name_edit.text = ""
	_name_edit.placeholder_text = inst.config.display_name
	_delete_files.button_pressed = true
	_delete_backups.button_pressed = false
	_validate()
	popup_centered()
	_name_edit.grab_focus.call_deferred()


func _validate() -> void:
	get_ok_button().disabled = _instance == null or _name_edit.text.strip_edges() != _instance.config.display_name


func _on_confirmed() -> void:
	if _instance == null:
		return
	var inst := _instance
	_instance = null
	var display := inst.config.display_name
	var source: ServerSource = (inst as RemoteServer).link if inst is RemoteServer else ServerManager
	var res: Dictionary = await source.delete_handle(inst, _delete_files.button_pressed, _delete_backups.button_pressed)
	if res.ok:
		Notifier.success("Deleted %s." % display)
	else:
		Notifier.error(str(res.get("error", "Could not delete %s." % display)))
