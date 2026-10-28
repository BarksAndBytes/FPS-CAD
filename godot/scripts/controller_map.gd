extends CanvasLayer
## Full-screen controls reference. Opens with View (Select) on a controller or F1 on a keyboard,
## from the title screen's Controls entry, and from the pause menu. Pages: Controller, Keyboard
## and mouse, Touch, Sketch and features; LB / RB or the D-pad switch pages, B / View / Esc
## close it.
##
## The controller page is res://ui/controller_map.svg. Its shapes are rasterized here; its <text>
## elements are drawn with the game's fonts so the art stays sharp and readable at any size.

signal closed

const UiTheme := preload("res://scripts/ui_theme.gd")
const SVG_PATH := "res://ui/controller_map.svg"
const ART_SIZE := Vector2(1200, 720)
const PAGES := ["Controller", "Keyboard and mouse", "Touch", "Sketch and features"]
const KEYBOARD := [
	["WASD", "Move"], ["Mouse", "Look"], ["Shift", "Sprint"], ["Space / C", "Jump / crouch (fly up / down)"],
	["Left click", "Primary action"], ["Right click", "Secondary action"], ["Hold Q", "Tool wheel"],
	["1 – 9", "Pick a tool on the wheel's page"], ["E", "Tool option"], ["Scroll, = / −", "Grow / shrink"], ["R", "Back to 1:1 size"],
	["F", "Fly through walls"], ["Alt", "Precision aim"], ["I", "Inspect parameters"], ["Tab", "Model panel"],
	["Ctrl+Z / Ctrl+Shift+Z", "Undo / redo"], ["Delete", "Delete selected feature"], ["F1", "This map"],
	["Enter", "Finish a sketch"], ["Esc", "Pause menu"], ["F12", "Screenshot"],
]
## Sketch mode and the feature panel: [controller, keyboard, what it does].
const SKETCH := [
	["", "", "THE CAD WORKFLOW"],
	["RT", "Left click", "Sketch tool: start a sketch on the aimed flat face (or the ground)"],
	["LB", "E", "Sketch tool: choose Top, Front or Right plane instead"],
	["LT", "Right click", "Sketch tool: edit the sketch you aim at"],
	["LB in the wheel", "E in the wheel", "Switch wheel page: Model / Direct"],
	["", "", "WHILE SKETCHING"],
	["RB", "Hold Q", "Sketch tools: Line, Rectangle, Circle, Arc, Dimension, Relation, Delete"],
	["RT", "Left click", "Place a point (snaps to points, the origin and the grid)"],
	["LT / B", "Right click", "End the line chain or drop the shape being drawn"],
	["LB", "E", "Tool option: construction, arc direction, dimension or relation type"],
	["L stick / R stick", "WASD / mouse", "Pan across the sketch (the view stays square to it)"],
	["D-pad ↑ / ↓", "Scroll, = / −", "Zoom in / out (the snap step follows)"],
	["Y", "I", "Switch between the sketch view and free look"],
	["D-pad ← / →", "Ctrl+Z / Ctrl+Shift+Z", "Undo / redo inside the sketch"],
	["X", "Enter", "Finish the sketch (Menu also has Discard)"],
	["", "", "FEATURE PANEL (EXTRUDE, REVOLVE, SWEEP, LOFT)"],
	["D-pad ↑ / ↓", "↑ / ↓", "Pick a field"],
	["D-pad ← / →, RT / LT", "← / →", "Change it (depth snaps to your snap step)"],
	["Y", "N", "Type a value or an expression"],
	["A / B", "Enter / Esc", "OK / cancel. Walk around the preview meanwhile"],
]
const TOUCH := [
	["Left thumb", "Drag anywhere on the left half to walk"], ["Right thumb", "Drag on the right half to look"],
	["FIRE", "Primary action"], ["ALT", "Secondary action"], ["JUMP", "Jump (UP while flying)"],
	["+ / −", "Grow / shrink"], ["TOOL or the tool chip", "Tool wheel"], ["Model", "Feature tree and parameters"],
	["Fly", "Fly through walls"], ["Menu", "Pause menu"],
]

var page := 0
var _root := Control.new()
var _art := TextureRect.new()
var _labels := Control.new()
var _list := GridContainer.new()
var _title := Label.new()
var _tabs := HBoxContainer.new()
var _footer := Label.new()
var _texts: Array = []  # parsed <text> elements: {kind, pos, anchor, key, desc, glyph}
var _svg := ""
var _art_scale := 1.0


func _ready() -> void:
	layer = 30
	visible = false
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color(UiTheme.BG, 0.97)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)
	bg.gui_input.connect(_on_bg_input)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 24
	col.offset_right = -24
	col.offset_top = 20
	col.offset_bottom = -16
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 18)
	_title = UiTheme.title("CONTROLS", 30)
	head.add_child(_title)
	_tabs.add_theme_constant_override("separation", 8)
	head.add_child(_tabs)
	var push := Control.new()
	push.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(push)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	head.add_child(close_btn)
	col.add_child(head)
	for i in PAGES.size():
		var b := Button.new()
		b.text = PAGES[i]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE  # pages switch with LB / RB; A and B stay free
		var idx := i
		b.pressed.connect(func(): show_page(idx))
		_tabs.add_child(b)

	var stage := Control.new()
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(stage)
	_art.set_anchors_preset(Control.PRESET_FULL_RECT)
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(_art)
	_labels.set_anchors_preset(Control.PRESET_FULL_RECT)
	_labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_labels.draw.connect(_draw_labels.bind(stage))
	stage.add_child(_labels)
	stage.resized.connect(_rasterize.bind(stage))
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list.columns = 2
	_list.add_theme_constant_override("h_separation", 28)
	_list.add_theme_constant_override("v_separation", 10)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	stage.add_child(scroll)

	_footer = UiTheme.text("", 15, UiTheme.MUTED)
	_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_footer)

	_load_svg()


func _load_svg() -> void:
	_svg = FileAccess.get_file_as_string(SVG_PATH)
	var re := RegEx.create_from_string(
		'<text class="(lbl|glyph)" x="([\\d.]+)" y="([\\d.]+)" text-anchor="(\\w+)"(?: data-key="([^"]*)" data-desc="([^"]*)")?>([^<]*)')
	for m in re.search_all(_svg):
		_texts.append({
			kind = m.get_string(1), pos = Vector2(float(m.get_string(2)), float(m.get_string(3))),
			anchor = m.get_string(4), key = m.get_string(5), desc = m.get_string(6), glyph = m.get_string(7),
		})


## Rasterizes the SVG's shapes (text stripped) at the size the stage shows it.
func _rasterize(stage: Control) -> void:
	if _svg == "" or stage.size.x < 10 or stage.size.y < 10:
		return
	_art_scale = minf(stage.size.x / ART_SIZE.x, stage.size.y / ART_SIZE.y)
	var shapes := RegEx.create_from_string("<text[\\s\\S]*?</text>").sub(_svg, "", true)
	var img := Image.new()
	if img.load_svg_from_string(shapes, maxf(_art_scale, 0.25)) == OK:
		_art.texture = ImageTexture.create_from_image(img)
	_labels.queue_redraw()


func art_ready() -> bool:
	return _art.texture != null and _texts.size() > 10


func _draw_labels(stage: Control) -> void:
	if page != 0:
		return
	var origin := (stage.size - ART_SIZE * _art_scale) / 2.0
	var body: Font = UiTheme.body_font if UiTheme.body_font != null else ThemeDB.fallback_font
	var bold: Font = UiTheme.display_font if UiTheme.display_font != null else body
	for t in _texts:
		var size := int(round(20.0 * _art_scale))
		var p: Vector2 = origin + t.pos * _art_scale
		if t.kind == "glyph":
			var w := bold.get_string_size(t.glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			_labels.draw_string(bold, p - Vector2(w / 2.0, 0), t.glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, size, UiTheme.FG)
			continue
		var kw := bold.get_string_size(t.key, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var gap := 8.0 * _art_scale
		var dw := body.get_string_size(t.desc, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var total := kw + gap + dw
		var x: float = p.x
		if t.anchor == "end":
			x -= total
		elif t.anchor == "middle":
			x -= total / 2.0
		_labels.draw_string(bold, Vector2(x, p.y), t.key, HORIZONTAL_ALIGNMENT_LEFT, -1, size, UiTheme.ACCENT)
		_labels.draw_string(body, Vector2(x + kw + gap, p.y), t.desc, HORIZONTAL_ALIGNMENT_LEFT, -1, size, UiTheme.FG)


func open(start_page: int = -1) -> void:
	if start_page < 0:
		start_page = {"controller": 0, "keyboard": 1, "touch": 2}.get(Actions.last_device, 0)
	visible = true
	show_page(start_page)
	_rasterize.call_deferred(_art.get_parent())


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func show_page(i: int) -> void:
	page = posmod(i, PAGES.size())
	for j in _tabs.get_child_count():
		(_tabs.get_child(j) as Button).set_pressed_no_signal(j == page)
	_art.visible = page == 0
	_labels.visible = page == 0
	var scroll: Control = _list.get_parent()
	scroll.visible = page != 0
	for c in _list.get_children():
		c.queue_free()
	_list.columns = 3 if page == 3 else 2
	if page == 3:
		for row in SKETCH:
			if row[0] == "":
				for col in 3:
					_list.add_child(UiTheme.title(row[2] if col == 2 else "", 15, UiTheme.MUTED))
				continue
			for col in 2:
				var k := UiTheme.title(row[col], 17, UiTheme.ACCENT)
				k.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				k.custom_minimum_size = Vector2(170, 0)
				_list.add_child(k)
			_list.add_child(UiTheme.text(row[2], 17))
	elif page != 0:
		for row in (KEYBOARD if page == 1 else TOUCH):
			var k := UiTheme.title(row[0], 19, UiTheme.ACCENT)
			k.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			k.custom_minimum_size = Vector2(220, 0)
			_list.add_child(k)
			_list.add_child(UiTheme.text(row[1], 18))
	_footer.text = "%s / %s switch pages   ·   %s close" % [
		Actions.prompt(&"context_wheel") if Actions.last_device == "controller" else "←",
		Actions.prompt(&"tool_wheel") if Actions.last_device == "controller" else "→",
		Actions.prompt(&"ui_cancel")]
	_labels.queue_redraw()


func _on_bg_input(e: InputEvent) -> void:
	var tapped: bool = (e is InputEventMouseButton or e is InputEventScreenTouch) and e.pressed
	if tapped and Actions.last_device == "touch":
		close()


func _unhandled_input(e: InputEvent) -> void:
	if not visible:
		return
	if e.is_action_pressed(&"ui_cancel") or e.is_action_pressed(&"controller_map") or e.is_action_pressed(&"menu"):
		close()
	elif e.is_action_pressed(&"context_wheel") or e.is_action_pressed(&"ui_left"):
		show_page(page - 1)
	elif e.is_action_pressed(&"tool_wheel") or e.is_action_pressed(&"ui_right"):
		show_page(page + 1)
	else:
		return
	get_viewport().set_input_as_handled()
