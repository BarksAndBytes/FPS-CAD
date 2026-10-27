extends CanvasLayer
## Title screen: the game's name over a slowly orbiting model, and the main menu.

signal chosen(id: String)  # "training", "new", "free", "assembly", "controls", "quit"

const UiTheme := preload("res://scripts/ui_theme.gd")

var tutorial_done := false
var _root := Control.new()
var _menu := VBoxContainer.new()
var _footer := Label.new()
var _buttons := {}
var _logo: Label
var _gap := Control.new()
var _margin := MarginContainer.new()


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
		["training", "Training", "Learn to move, resize yourself, sketch and extrude"],
		["new", "New part", "A blank part: pick a plane, sketch, then extrude, revolve, sweep or loft"],
		["free", "Free build", "Walk and edit the sample pavilion"],
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

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)
	_footer = UiTheme.text("", 15, UiTheme.MUTED)
	_footer.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(_footer)
	var version := UiTheme.text("v0.2 · sketch-based modelling · files stay on this device", 13, UiTheme.MUTED.darkened(0.25))
	col.add_child(version)
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
		(b as Button).custom_minimum_size.y = 42 if short else 56
		(b as Button).add_theme_font_size_override("font_size", 19 if short else 22)
	_footer.visible = not short or Actions.last_device != "touch"


func show_title(done: bool) -> void:
	tutorial_done = done
	_fit()
	(_buttons.training as Button).text = "Training" if done else "Training  ·  start here"
	visible = true
	focus_default()


func focus_default() -> void:
	var b: Button = _buttons.free if tutorial_done else _buttons.training
	b.grab_focus.call_deferred()


func keep_focus() -> void:
	if visible:
		UiTheme.keep_focus(_root, _buttons.free if tutorial_done else _buttons.training)


func _describe(text: String) -> void:
	var prompts := "%s select   ·   ↑↓ move" % Actions.prompt(&"ui_accept")
	if Actions.last_device == "touch":
		prompts = "Tap to select"
	_footer.text = (text + "\n" if text != "" else "") + prompts
