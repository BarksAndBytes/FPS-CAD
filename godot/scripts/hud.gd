extends CanvasLayer
## Heads-up display: tool chip, prompts, readouts, crosshair, toasts, the model panel (feature
## tree and parameters) and the file menu. Built in code so the layout lives in one place.

signal request(action: String, arg: Variant)  # menu and button actions for main.gd

const BG := Color(0.067, 0.082, 0.106, 0.82)
const LINE := Color(0.886, 0.914, 0.949, 0.14)
const FG := Color("e8edf3")
const MUTED := Color("9ba7b6")
const ACCENT := Color("ff8a3d")
const MEASURE := Color("ffd166")

var doc: RefCounted
var units := "mm"
var panel_open := false
var menu_open := false
var started := false

var _tool_name := Label.new()
var _tool_key := Label.new()
var _hint := Label.new()
var _readout := Label.new()
var _aim := Label.new()
var _cross := Label.new()
var _toast := Label.new()
var _measure := Label.new()
var _panel := PanelContainer.new()
var _params := VBoxContainer.new()
var _tree := VBoxContainer.new()
var _menu := PanelContainer.new()
var _start := PanelContainer.new()
var _fly_btn := Button.new()
var _toast_t := 0.0
var _feature_id := ""


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var safe := DisplayServer.get_display_safe_area()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	if safe.size.x > 0 and OS.has_feature("mobile"):
		margin.add_theme_constant_override("margin_left", maxi(16, safe.position.x))
		margin.add_theme_constant_override("margin_top", maxi(16, safe.position.y))
	root.add_child(margin)

	# Top left: tool chip, hint, readout
	var left := VBoxContainer.new()
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	left.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	margin.add_child(left)
	var chip := _box(ACCENT.darkened(0.55))
	var chip_col := VBoxContainer.new()
	chip_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tool_name.add_theme_font_size_override("font_size", 20)
	_tool_name.add_theme_color_override("font_color", FG)
	_tool_key.add_theme_font_size_override("font_size", 12)
	_tool_key.add_theme_color_override("font_color", MUTED)
	chip_col.add_child(_tool_name)
	chip_col.add_child(_tool_key)
	chip.add_child(chip_col)
	chip.mouse_filter = Control.MOUSE_FILTER_STOP
	chip.gui_input.connect(_on_chip_input)
	left.add_child(chip)
	for l in [_hint, _readout]:
		var b := _box(BG)
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color", MUTED)
		b.add_child(l)
		left.add_child(b)

	# Top right: buttons for mouse and touch
	var right := HBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_SHRINK_END
	right.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	right.add_theme_constant_override("separation", 6)
	margin.add_child(right)
	for spec in [["Undo", "undo"], ["Redo", "redo"], ["Fly", "fly"], ["Model", "panel"], ["Menu", "menu"]]:
		var b := Button.new()
		b.text = spec[0]
		b.focus_mode = Control.FOCUS_NONE
		var action: String = spec[1]
		b.pressed.connect(func(): request.emit(action, null))
		right.add_child(b)
		if action == "fly":
			_fly_btn = b
			b.toggle_mode = true

	# Centre: crosshair and target label
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centre)
	var cbox := VBoxContainer.new()
	cbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_cross.text = "+"
	_cross.add_theme_font_size_override("font_size", 30)
	_cross.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cross.add_theme_color_override("font_outline_color", Color.BLACK)
	_cross.add_theme_constant_override("outline_size", 4)
	_aim.add_theme_font_size_override("font_size", 14)
	_aim.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_aim.add_theme_color_override("font_outline_color", Color.BLACK)
	_aim.add_theme_constant_override("outline_size", 5)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 44)  # keeps the "+" at the exact centre
	cbox.add_child(spacer)
	cbox.add_child(_cross)
	cbox.add_child(_aim)
	centre.add_child(cbox)

	# Bottom centre: measure readout and toasts
	var bottom := VBoxContainer.new()
	bottom.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bottom.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bottom.position.y -= 150
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bottom)
	for l in [_measure, _toast]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 15)
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 5)
		bottom.add_child(l)
	_measure.add_theme_color_override("font_color", MEASURE)

	_build_panel(root)
	_build_menu(root)
	_build_start(root)


func _on_chip_input(e: InputEvent) -> void:
	var tapped: bool = (e is InputEventMouseButton or e is InputEventScreenTouch) and e.pressed
	if tapped:
		request.emit("open_wheel", null)


func _box(color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.border_color = LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return p


func _process(dt: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= dt
		_toast.modulate.a = clampf(_toast_t / 0.3, 0.0, 1.0)


# ---------- readouts ----------

## Formats a length in metres the way an engineer reads it: mm below a metre, m above.
func length(v: float) -> String:
	var a := absf(v)
	if a >= 1000.0:
		return "%.2f km" % (v / 1000.0)
	if a >= 1.0:
		return "%.2f m" % v
	if a >= 0.1:
		return "%.0f mm" % (v * 1000.0)
	if a >= 0.01:
		return "%.1f mm" % (v * 1000.0)
	return "%.2f mm" % (v * 1000.0)


func toast(msg: String) -> void:
	_toast.text = msg
	_toast_t = 1.8
	_toast.modulate.a = 1.0


func set_tool(t: Dictionary, option: String) -> void:
	_tool_name.text = t.name.to_upper()
	_tool_key.text = "hold %s for the tool wheel" % Actions.prompt(&"tool_wheel") if Actions.last_device != "touch" else "tap for the tool wheel"
	var opt := "" if option == "" else "   ·   %s %s" % [Actions.prompt(&"context_wheel"), option]
	_hint.text = "%s %s   ·   %s %s%s" % [Actions.prompt(&"primary"), t.pri, Actions.prompt(&"secondary"), t.alt, opt]


func set_readout(size: float, grid: float, snap: float, fly: bool, feet: Vector3) -> void:
	_readout.text = "%s tall · grid %s · snap %s · %s\nX %s   Y %s   Z %s" % [
		length(1.75 * size), length(grid), length(snap), "FLY" if fly else "WALK",
		length(feet.x), length(-feet.z), length(feet.y)]
	_fly_btn.set_pressed_no_signal(fly)


func set_aim(label: String, on_target: bool) -> void:
	_aim.text = label
	_cross.add_theme_color_override("font_color", ACCENT if on_target else FG)


func set_measure(text: String) -> void:
	_measure.text = text


# ---------- model panel ----------

func _build_panel(root: Control) -> void:
	_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_panel.offset_left = -340
	_panel.offset_top = 64
	_panel.offset_bottom = -16
	_panel.offset_right = -16
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.border_color = LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", sb)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 10)
	col.add_child(_params)
	var tree_title := Label.new()
	tree_title.text = "FEATURE TREE"
	tree_title.add_theme_color_override("font_color", MUTED)
	tree_title.add_theme_font_size_override("font_size", 12)
	col.add_child(HSeparator.new())
	col.add_child(tree_title)
	col.add_child(_tree)
	scroll.add_child(col)
	_panel.add_child(scroll)
	_panel.visible = false
	root.add_child(_panel)


func toggle_panel() -> void:
	set_panel(not panel_open)


func set_panel(on: bool) -> void:
	panel_open = on
	_panel.visible = on
	if on:
		refresh_panel()


func show_feature(id: String) -> void:
	_feature_id = id
	if panel_open:
		refresh_panel()


## Rebuilds the parameter fields and the feature tree from the document.
func refresh_panel() -> void:
	for c in _params.get_children() + _tree.get_children():
		c.queue_free()
	if doc == null or not doc.has_method("get_features"):
		var l := Label.new()
		l.text = "Assemblies list their components here in a later build."
		l.autowrap_mode = TextServer.AUTOWRAP_WORD
		_params.add_child(l)
		return
	var features: Array = doc.get_features()
	var current: Dictionary = {}
	for f in features:
		if f.id == _feature_id:
			current = f
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 16)
	_params.add_child(title)
	if current.is_empty():
		title.text = "PARAMETERS"
		var hint := Label.new()
		hint.text = "Aim at a feature and press %s, or pick one from the tree." % Actions.prompt(&"inspect")
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD
		hint.add_theme_color_override("font_color", MUTED)
		_params.add_child(hint)
	else:
		title.text = "%s  ·  %s" % [current.name, current.type]
		if not current.ok:
			var err := Label.new()
			err.text = current.message
			err.autowrap_mode = TextServer.AUTOWRAP_WORD
			err.add_theme_color_override("font_color", Color("e0775f"))
			_params.add_child(err)
		var params: Dictionary = current.params
		_add_fields(current.id, params, "")
		var del := Button.new()
		del.text = "Delete %s" % current.name
		del.pressed.connect(func(): request.emit("delete_feature", current.id))
		_params.add_child(del)
	var first: Control = null
	for f in features:
		var b := Button.new()
		b.text = ("●  " if f.id == _feature_id else "    ") + f.name + ("" if f.ok else "  ⚠")
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var fid: String = f.id
		b.pressed.connect(func():
			_feature_id = fid
			request.emit("select_feature", fid)
			refresh_panel())
		_tree.add_child(b)
		if first == null:
			first = b
	var vars: Array = doc.get_variables()
	if not vars.is_empty():
		var vt := Label.new()
		vt.text = "VARIABLES"
		vt.add_theme_color_override("font_color", MUTED)
		vt.add_theme_font_size_override("font_size", 12)
		_tree.add_child(HSeparator.new())
		_tree.add_child(vt)
		for v in vars:
			var row := _field(v.name, v.expr)
			var vname: String = v.name
			row.get_child(1).text_submitted.connect(func(text): request.emit("set_variable", [vname, text]))
			_tree.add_child(row)
	# Controller users navigate the panel with the D-pad; give it a starting point.
	var focus: Control = _params.get_child(_params.get_child_count() - 1) if _params.get_child_count() > 1 else first
	if focus != null and Actions.last_device == "controller":
		focus.call_deferred("grab_focus")


func _add_fields(id: String, params: Dictionary, prefix: String) -> void:
	for key in params:
		var v: Variant = params[key]
		if v is Dictionary:
			_add_fields(id, v, prefix + key + ".")
			continue
		if v is Array or key == "target" or key == "edges" or key == "kind":
			continue
		var shown: String = v if v is String else ("%.4f" % (float(v) * (1000.0 if units == "mm" else 1.0))).rstrip("0").rstrip(".")
		var row := _field(prefix + key, shown)
		var full: String = prefix + key
		row.get_child(1).text_submitted.connect(func(text: String):
			# Plain numbers are in document units; anything else is an expression.
			var value: Variant = text
			if text.is_valid_float():
				value = float(text) / (1000.0 if units == "mm" else 1.0)
			request.emit("set_param", [id, full, value]))
		_params.add_child(row)


func _field(label: String, value: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(110, 0)
	l.add_theme_color_override("font_color", MUTED)
	var e := LineEdit.new()
	e.text = value
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	row.add_child(l)
	row.add_child(e)
	return row


# ---------- file menu ----------

func _build_menu(root: Control) -> void:
	_menu.set_anchors_preset(Control.PRESET_CENTER)
	_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.14, 0.96)
	sb.border_color = LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(18)
	_menu.add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.custom_minimum_size = Vector2(320, 0)
	var t := Label.new()
	t.text = "FILE"
	t.add_theme_font_size_override("font_size", 18)
	col.add_child(t)
	for spec in [
		["Resume", "resume"], ["Save", "save"], ["Open last saved part", "open_saved"],
		["New sample part", "sample_part"], ["Open sample assembly", "sample_assembly"],
		["Export STEP", "export_step"], ["Export IGES", "export_iges"], ["Export STL", "export_stl"],
		["Export 3MF", "export_3mf"], ["Quit", "quit"]]:
		var b := Button.new()
		b.text = spec[0]
		var action: String = spec[1]
		b.pressed.connect(func(): request.emit(action, null))
		col.add_child(b)
	var note := Label.new()
	note.text = "Files are saved on this device only."
	note.add_theme_color_override("font_color", MUTED)
	note.add_theme_font_size_override("font_size", 12)
	col.add_child(note)
	_menu.add_child(col)
	_menu.visible = false
	root.add_child(_menu)


func set_menu(on: bool) -> void:
	menu_open = on
	_menu.visible = on
	if on:
		var first: Button = _menu.get_child(0).get_child(1)
		first.call_deferred("grab_focus")


# ---------- start screen ----------

func _build_start(root: Control) -> void:
	_start.set_anchors_preset(Control.PRESET_CENTER)
	_start.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_start.grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.14, 0.97)
	sb.border_color = LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(24)
	_start.add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(min(560, get_viewport().get_visible_rect().size.x - 40), 0)
	var title := Label.new()
	title.text = "FPS-CAD"
	title.add_theme_font_size_override("font_size", 34)
	col.add_child(title)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	body.add_theme_color_override("font_color", MUTED)
	body.text = "Walk around a parametric model. Change your size to zoom. Pick tools from the wheel and edit every part by its dimensions."
	col.add_child(body)
	var keys := Label.new()
	keys.autowrap_mode = TextServer.AUTOWRAP_WORD
	keys.text = ("Controller: left stick move · right stick look · RT / LT tool actions · hold RB tool wheel · "
		+ "LB tool option · D-pad ↑↓ size, ←→ undo/redo · A jump · Y inspect · View model panel\n"
		+ "Keyboard: WASD + mouse · LMB / RMB · hold Q wheel · E option · scroll size · F fly · Tab panel · Esc menu")
	col.add_child(keys)
	var go := Button.new()
	go.text = "Enter the model"
	go.pressed.connect(func(): request.emit("start", null))
	col.add_child(go)
	_start.add_child(col)
	root.add_child(_start)
	go.call_deferred("grab_focus")


func hide_start() -> void:
	started = true
	_start.visible = false
