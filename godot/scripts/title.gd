extends CanvasLayer
## Title screen: the game's name over a slowly orbiting model, and the main menu.

signal chosen(id: String)  # "update", "training", "challenges", "challenge:N", "new", "free", "assembly", "controls", "quit"

const UiTheme := preload("res://scripts/ui_theme.gd")

var tutorial_done := false
var _root := Control.new()
var _menu := VBoxContainer.new()
var _footer := Label.new()
var _buttons := {}
var _logo: Label
var _gap := Control.new()
var _margin := MarginContainer.new()
var _levels_scroll := ScrollContainer.new()
var _levels := VBoxContainer.new()
var _spacer := Control.new()


func _ready() -> void:
	layer = 20
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# A dark band on the left keeps the menu readable over the moving model.
	var shade := ColorRect.new()
	shade.color = Color(UiTheme.BG, 0.88)
	shade.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	shade.offset_right = 520
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)

	var margin := _margin
	margin.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	margin.offset_right = 520
	var safe := DisplayServer.get_display_safe_area()
	margin.add_theme_constant_override("margin_left", maxi(48, safe.position.x + 24) if OS.has_feature("mobile") else 56)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_top", 48)
	margin.add_theme_constant_override("margin_bottom", 32)
	_root.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)
	_logo = UiTheme.title("FPS-CAD", 76)
	col.add_child(_logo)
	col.add_child(UiTheme.text("Parametric CAD you play in first person", 18, UiTheme.MUTED))
	_gap.custom_minimum_size = Vector2(0, 28)
	col.add_child(_gap)

	_menu.add_theme_constant_override("separation", 10)
	col.add_child(_menu)
	for spec in [
		["update", "Update available", "Downloads the newer build and installs it over this one. Your files stay"],
		["training", "Training", "Learn to move, resize yourself, sketch and extrude"],
		["challenges", "Challenges", "Copy target parts, from a plain block to a mounting bracket"],
		["new", "New part", "A blank part: pick a plane, sketch, then extrude, revolve, sweep or loft"],
		["free", "Free build", "Walk up to the table and edit a sample desk organiser"],
		["assembly", "Assembly sandbox", "A plate with four pins, built from two parts"],
		["controls", "Controls", "Controller, keyboard and touch maps"],
		["quit", "Quit", ""],
	]:
		var b := Button.new()
		b.text = spec[1]
		b.tooltip_text = spec[2]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(340, 56)
		if UiTheme.display_font != null:
			b.add_theme_font_override("font", UiTheme.display_font)
		b.add_theme_font_size_override("font_size", 22)
		var id: String = spec[0]
		var desc: String = spec[2]
		b.pressed.connect(func(): chosen.emit(id))
		b.focus_entered.connect(func(): _describe(desc))
		_menu.add_child(b)
		_buttons[id] = b
	(_buttons.update as Button).visible = false
	(_buttons.update as Button).add_theme_color_override("font_color", UiTheme.ACCENT)

	_levels_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_levels_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_levels_scroll.visible = false
	_levels.add_theme_constant_override("separation", 6)
	_levels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_levels_scroll.add_child(_levels)
	col.add_child(_levels_scroll)
	_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_spacer)
	_footer = UiTheme.text("", 15, UiTheme.MUTED)
	_footer.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(_footer)
	var version := UiTheme.text("v%s · %s · files stay on this device" % [
		preload("res://scripts/build_info.gd").VERSION, preload("res://scripts/updater.gd").version_text()], 13, UiTheme.MUTED.darkened(0.25))
	col.add_child(version)
	# CC BY 4.0 attribution for the table model.
	col.add_child(UiTheme.text("Table: “Old Wooden Table” by carlcapu9 (sketchfab.com), CC BY 4.0", 12, UiTheme.MUTED.darkened(0.3)))
	visible = false
	get_viewport().size_changed.connect(_fit)


## Phones in landscape (or a large interface size) leave little height: tighten the layout.
func _fit() -> void:
	var short := UiTheme.short_screen(self)
	_logo.add_theme_font_size_override("font_size", 52 if short else 76)
	_gap.custom_minimum_size.y = 6 if short else 28
	_margin.add_theme_constant_override("margin_top", 16 if short else 48)
	_margin.add_theme_constant_override("margin_bottom", 12 if short else 32)
	_menu.add_theme_constant_override("separation", 6 if short else 10)
	for b in _buttons.values():
		(b as Button).custom_minimum_size.y = 38 if short else 52
		(b as Button).add_theme_font_size_override("font_size", 18 if short else 22)
	_footer.visible = not short or Actions.last_device != "touch"


func show_title(done: bool) -> void:
	tutorial_done = done
	show_menu()
	_fit()
	(_buttons.training as Button).text = "Training" if done else "Training  ·  start here"
	visible = true
	focus_default()


## Shows the update entry at the top of the menu.
func show_update(info: Dictionary) -> void:
	var b: Button = _buttons.update
	b.text = "Update to build %d" % int(info.get("build", 0))
	b.visible = true


func focus_default() -> void:
	if _levels_scroll.visible:
		var first := UiTheme.first_focusable(_levels)
		if first != null:
			first.grab_focus.call_deferred()
		return
	var b: Button = _buttons.free if tutorial_done else _buttons.training
	b.grab_focus.call_deferred()


func keep_focus() -> void:
	if not visible:
		return
	if _levels_scroll.visible:
		UiTheme.keep_focus(_levels)
	else:
		UiTheme.keep_focus(_root, _buttons.free if tutorial_done else _buttons.training)


func show_menu() -> void:
	_menu.visible = true
	_levels_scroll.visible = false
	_spacer.visible = true


## The challenge list. rows: [{name, brief, locked, best (seconds, or < 0)}].
func show_levels(rows: Array) -> void:
	visible = true
	for c in _levels.get_children():
		_levels.remove_child(c)
		c.queue_free()
	_levels.add_child(UiTheme.title("CHALLENGES", 26, UiTheme.ACCENT))
	_levels.add_child(UiTheme.text("Copy each target part. Any orientation, any method.", 15, UiTheme.MUTED))
	var first_open: Button = null  # the first unlocked challenge not yet done takes focus
	var first_any: Button = null
	for i in rows.size():
		var r: Dictionary = rows[i]
		var b := Button.new()
		var best: float = r.best
		var done := best >= 0.0
		var mark := "✓ %d:%02d" % [int(best) / 60, int(best) % 60] if done else ("locked" if r.locked else "")
		b.text = "%d   %s%s" % [i + 1, r.name, ("     " + mark) if mark != "" else ""]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(340, 44)
		b.disabled = r.locked
		var desc: String = r.brief
		var id := "challenge:%d" % i
		b.pressed.connect(func(): chosen.emit(id))
		b.focus_entered.connect(func(): _describe(desc))
		_levels.add_child(b)
		if not r.locked and not done and first_open == null:
			first_open = b
		if not r.locked and first_any == null:
			first_any = b
	var back := Button.new()
	back.text = "Back"
	back.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back.custom_minimum_size = Vector2(340, 44)
	back.pressed.connect(show_menu)
	back.pressed.connect(focus_default)
	_levels.add_child(back)
	_menu.visible = false
	_spacer.visible = false
	_levels_scroll.visible = true
	var focus: Button = first_open if first_open != null else first_any
	if focus != null:
		focus.grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if visible and _levels_scroll.visible and event.is_action_pressed(&"ui_cancel"):
		show_menu()
		focus_default()
		get_viewport().set_input_as_handled()


func _describe(text: String) -> void:
	var prompts := "%s select   ·   ↑↓ move" % Actions.prompt(&"ui_accept")
	if Actions.last_device == "touch":
		prompts = "Tap to select"
	_footer.text = (text + "\n" if text != "" else "") + prompts
