extends RefCounted
## The game's look, applied to Godot's default theme at startup so every control picks it up,
## including controls under CanvasLayers (which do not inherit a Window's theme).
##
## The focused control gets a thick accent outline: with a controller, focus is the cursor.

const BG := Color("1b2129")
const PANEL := Color(0.09, 0.11, 0.14, 0.96)
const SURFACE := Color(0.16, 0.19, 0.23, 0.95)
const LINE := Color(0.886, 0.914, 0.949, 0.16)
const FG := Color("e8edf3")
const MUTED := Color("9ba7b6")
const ACCENT := Color("ff8a3d")
const ACCENT_INK := Color("1d1206")

const SETTINGS := "user://settings.cfg"
## Interface size choices for the pause menu. 0 means automatic (sized for the screen's density).
const SCALE_CHOICES := [0.0, 1.0, 1.25, 1.5, 1.75, 2.0]

static var display_font: Font
static var body_font: Font
static var ui_scale := 1.0


## The interface scale that makes text a comfortable physical size on this screen. The layout is
## designed at 1600 × 900; a phone shows that across a few inches, held about half as far away as
## a monitor, so its text is scaled up to roughly match a desktop's apparent size.
static func auto_scale() -> float:
	if not OS.has_feature("mobile"):
		return 1.0
	var screen := Vector2(DisplayServer.screen_get_size())
	var dpi := float(DisplayServer.screen_get_dpi())
	if dpi <= 0.0 or screen.x <= 0.0:
		return 1.5
	var long_side := maxf(screen.x, screen.y)
	var short_side := minf(screen.x, screen.y)
	var base := minf(long_side / 1600.0, short_side / 900.0)  # what the stretch mode already applies
	return clampf(0.0052 * dpi / base, 1.0, 1.6)


static func saved_scale_choice() -> float:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	return float(cfg.get_value("display", "ui_scale", 0.0))


## Applies (and remembers) an interface size choice; 0 = automatic. Returns the scale in use.
static func apply_scale(tree: SceneTree, choice: float, save := false) -> float:
	ui_scale = auto_scale() if choice <= 0.0 else choice
	tree.root.content_scale_factor = ui_scale
	if save:
		var cfg := ConfigFile.new()
		cfg.load(SETTINGS)
		cfg.set_value("display", "ui_scale", choice)
		cfg.save(SETTINGS)
	return ui_scale


static func scale_label(choice: float) -> String:
	if choice <= 0.0:
		return "Auto (%d%%)" % roundi(auto_scale() * 100.0)
	return "%d%%" % roundi(choice * 100.0)


## True when the visible area is short (a phone in landscape, or a large interface size), so
## menus should use their compact layouts.
static func short_screen(node: Node) -> bool:
	var vp := node.get_viewport()
	return vp != null and vp.get_visible_rect().size.y < 760.0


## Converts a length in window pixels (safe-area insets) to interface units.
static func from_window_px(node: Node, px: float) -> float:
	var vp := node.get_viewport()
	var win := float(DisplayServer.window_get_size().x)
	if vp == null or win <= 0.0:
		return px
	return px * vp.get_visible_rect().size.x / win


static func apply() -> void:
	display_font = load("res://fonts/ChakraPetch-SemiBold.ttf")
	body_font = load("res://fonts/IBMPlexSans-Variable.ttf")
	var t: Theme = ThemeDB.get_default_theme()
	if body_font != null:
		t.default_font = body_font
		ThemeDB.fallback_font = body_font
	t.default_font_size = 17

	t.set_stylebox("normal", "Button", _box(SURFACE, LINE, 1))
	t.set_stylebox("hover", "Button", _box(SURFACE.lightened(0.08), LINE.lightened(0.3), 1))
	t.set_stylebox("pressed", "Button", _box(ACCENT.darkened(0.35), ACCENT, 1))
	t.set_stylebox("hover_pressed", "Button", _box(ACCENT.darkened(0.3), ACCENT, 1))
	t.set_stylebox("disabled", "Button", _box(SURFACE.darkened(0.3), LINE, 1))
	var focus := _box(Color(0, 0, 0, 0), ACCENT, 3)
	focus.draw_center = false
	focus.expand_margin_left = 3
	focus.expand_margin_right = 3
	focus.expand_margin_top = 3
	focus.expand_margin_bottom = 3
	t.set_stylebox("focus", "Button", focus)
	for c in ["font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(c, "Button", FG)
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", MUTED.darkened(0.3))

	t.set_stylebox("normal", "LineEdit", _box(Color(0, 0, 0, 0.3), LINE, 1))
	t.set_stylebox("focus", "LineEdit", focus)
	t.set_color("font_color", "LineEdit", FG)
	t.set_color("font_color", "Label", FG)
	t.set_stylebox("panel", "PanelContainer", _box(PANEL, LINE, 1, 12, 18))


static func _box(bg: Color, border: Color, width: int, radius := 8, margin := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = maxf(margin, 14)
	sb.content_margin_right = maxf(margin, 14)
	sb.content_margin_top = maxf(margin, 8)
	sb.content_margin_bottom = maxf(margin, 8)
	return sb


## A label in the display face, for titles and the tool name.
static func title(content: String, size: int, color := FG) -> Label:
	var l := Label.new()
	l.text = content
	if display_font != null:
		l.add_theme_font_override("font", display_font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func text(content: String, size := 17, color := FG) -> Label:
	var l := Label.new()
	l.text = content
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## First visible, enabled, focusable button or line edit under node, depth first.
static func first_focusable(node: Node) -> Control:
	for c in node.get_children():
		if c is Control and not (c as Control).is_visible_in_tree():
			continue
		if c is BaseButton and not (c as BaseButton).disabled and (c as Control).focus_mode != Control.FOCUS_NONE:
			return c
		if c is LineEdit:
			return c
		var deeper := first_focusable(c)
		if deeper != null:
			return deeper
	return null


## Makes sure something inside root has focus, so the D-pad and A always have a target.
static func keep_focus(root: Control, preferred: Control = null) -> void:
	var vp := root.get_viewport()
	if vp == null:
		return
	var current := vp.gui_get_focus_owner()
	if current != null and current.is_visible_in_tree() and root.is_ancestor_of(current):
		return
	var target := preferred if preferred != null and preferred.is_visible_in_tree() else first_focusable(root)
	if target != null:
		target.grab_focus()
