class_name FirewallRuleRow
extends HBoxContainer
## One firewall rule that opens a port no server uses any more, with a Remove button.

signal remove_requested(rule: Dictionary)

var rule := {}

@onready var _label: Label = %RuleLabel
@onready var _remove_button: Button = %RemoveButton


func _ready() -> void:
	_remove_button.pressed.connect(func() -> void: remove_requested.emit(rule))


## [param busy] disables the button while a password prompt is open.
func setup(r: Dictionary, busy: bool) -> void:
	rule = r
	var where := "" if NetworkService._source_key(str(r.source)) == "anywhere" else " (from %s)" % r.source
	if r.origin == "app":
		_label.text = "Port %d%s — opened by Server Manager, no server uses it now." % [r.port, where]
		_remove_button.text = "Remove"
		_remove_button.theme_type_variation = &""
		_remove_button.tooltip_text = "Delete this firewall rule. Your desktop asks for your password (once per rule)."
	else:
		_label.text = "Port %d%s — allowed by a rule you added yourself; no server uses it now." % [r.port, where]
		_remove_button.text = "Remove…"
		_remove_button.theme_type_variation = &"DangerButton"
		_remove_button.tooltip_text = "Server Manager didn't create this rule. You'll be asked to confirm, then for your password."
	_remove_button.disabled = busy
