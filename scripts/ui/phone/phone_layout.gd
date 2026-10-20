class_name PhoneLayout
extends RefCounted
## Refits screens built for the desktop window to a phone's narrow portrait screen: rows of
## controls wrap onto more lines, two-column forms stack, side-by-side panes go one above
## the other and fixed widths shrink. The phone app applies it to each screen and dialog,
## and again when rows are added to them later.

## Widest a fixed-width field or label may stay.
const MAX_FIXED_WIDTH := 150.0
## Name of the wrapping row put inside a too-wide HBoxContainer.
const FLOW_NAME := "PhoneFlow"
## Name of the column put inside a too-wide HSplitContainer.
const STACK_NAME := "PhoneStack"
## Smallest width an option list keeps once it stops sizing itself to its longest item.
const MIN_OPTION_WIDTH := 110.0
## Desktop wording that reads differently on a touch screen.
const TOUCH_WORDING := {"Hover a setting for details.": "Touch and hold a setting for details."}
## Hints that only make sense with a mouse (by node name).
const DESKTOP_ONLY: PackedStringArray = ["DropHint"]


## Refits [param root] and everything below it to [param width] (UI units). Tightens the
## limit step by step until the whole tree fits, since padding around nested rows adds up.
static func adapt(root: Node, width: float) -> void:
	var limit := width
	for i in 6:
		_adapt_node(root, limit)
		var control := root as Control
		if control == null or control.get_combined_minimum_size().x <= width or limit < 200.0:
			return
		limit -= 24.0


static func _adapt_node(node: Node, limit: float) -> void:
	if node is Window:
		return  # Dialogs are refitted when they open (see PhoneMain).
	# A strip that scrolls sideways may be as wide as it likes.
	if node is ScrollContainer and (node as ScrollContainer).vertical_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED:
		return
	for child in node.get_children():
		_adapt_node(child, limit)
	var control := node as Control
	if control == null:
		return
	if DESKTOP_ONLY.has(str(control.name)):
		control.visible = false
		return
	if control is Label:
		_adapt_label(control as Label, limit)
	elif control is LineEdit or control is SpinBox or control is OptionButton or control is MenuButton:
		if control.custom_minimum_size.x > MAX_FIXED_WIDTH:
			control.custom_minimum_size.x = MAX_FIXED_WIDTH
		if control is OptionButton:
			var option := control as OptionButton
			if option.get_combined_minimum_size().x > limit * 0.6:
				option.fit_to_longest_item = false
				option.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				option.custom_minimum_size.x = maxf(option.custom_minimum_size.x, MIN_OPTION_WIDTH)
	elif control is Button:
		if (control as Button).get_combined_minimum_size().x > limit * 0.8:
			(control as Button).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			(control as Button).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	elif control is HSplitContainer:
		_stack_split(control as HSplitContainer, limit)
	elif control is SplitContainer and not control is VSplitContainer:
		if control.get_combined_minimum_size().x > limit:
			(control as SplitContainer).vertical = true
	elif control is GridContainer:
		var grid := control as GridContainer
		if grid.get_combined_minimum_size().x > limit and grid.columns > 1:
			grid.columns = 1 if grid.columns <= 2 else grid.columns / 2
	elif control is HBoxContainer:
		_wrap_row(control as HBoxContainer, limit)
	if control.custom_minimum_size.x > limit:
		control.custom_minimum_size.x = 0.0


## Lets a wide label wrap instead of widening its screen.
static func _adapt_label(label: Label, limit: float) -> void:
	for desktop: String in TOUCH_WORDING:
		if label.text.contains(desktop):
			label.text = label.text.replace(desktop, TOUCH_WORDING[desktop])
	if label.custom_minimum_size.x > MAX_FIXED_WIDTH:
		label.custom_minimum_size.x = 0.0
	if label.autowrap_mode == TextServer.AUTOWRAP_OFF and label.get_combined_minimum_size().x > limit * 0.7:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		# A wrapping label shrinks to nothing in a row unless it may take the free space.
		if label.get_parent() is BoxContainer and not label.get_parent() is VBoxContainer or label.get_parent() is FlowContainer:
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.custom_minimum_size.x = minf(limit * 0.6, 200.0)


## A row too wide for the screen: its children move into a wrapping row inside it, so the
## row itself (which scripts may hold) stays where it is. Children added later move too.
static func _wrap_row(row: HBoxContainer, limit: float) -> void:
	var flow := row.get_node_or_null(FLOW_NAME) as HFlowContainer
	if flow != null:
		for child in row.get_children():
			if child != flow and child is Control:
				child.reparent(flow, false)
		return
	if row.get_combined_minimum_size().x <= limit:
		return
	flow = HFlowContainer.new()
	flow.name = FLOW_NAME
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.size_flags_vertical = Control.SIZE_EXPAND_FILL if row.size_flags_vertical & Control.SIZE_EXPAND else Control.SIZE_FILL
	var gap := row.get_theme_constant("separation")
	flow.add_theme_constant_override("h_separation", gap)
	flow.add_theme_constant_override("v_separation", maxi(gap, 6))
	match row.alignment:
		BoxContainer.ALIGNMENT_CENTER:
			flow.alignment = FlowContainer.ALIGNMENT_CENTER
		BoxContainer.ALIGNMENT_END:
			flow.alignment = FlowContainer.ALIGNMENT_END
	var children := row.get_children()
	row.add_child(flow)
	for child in children:
		if child is Control:
			child.reparent(flow, false)
			# Cards and fields narrower than their desktop size, so two fit side by side.
			if (child as Control).custom_minimum_size.x > MAX_FIXED_WIDTH:
				(child as Control).custom_minimum_size.x = MAX_FIXED_WIDTH
		# Spacers only push things apart on one line; wrapped, they leave holes.
		if child is Control and child.get_class() == "Control" and child.get_child_count() == 0:
			(child as Control).size_flags_horizontal = Control.SIZE_FILL
			(child as Control).custom_minimum_size.x = 0.0


## Side-by-side panes too wide for the screen go one above the other (the divider can't
## turn, so the panes move into a column inside it).
static func _stack_split(split: HSplitContainer, limit: float) -> void:
	var stack := split.get_node_or_null(STACK_NAME) as VBoxContainer
	if stack == null:
		if split.get_combined_minimum_size().x <= limit:
			return
		stack = VBoxContainer.new()
		stack.name = STACK_NAME
		stack.add_theme_constant_override("separation", 12)
		split.add_child(stack)
	for child in split.get_children():
		if child != stack and child is Control:
			child.reparent(stack, false)
			(child as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
