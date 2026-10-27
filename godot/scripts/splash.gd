extends CanvasLayer
## Opening splash cards, shown once at launch before the title screen. Each card fades in, holds
## and fades out. Any button, key or tap skips to the next card; Start / Esc skips them all.

signal finished

const UiTheme := preload("res://scripts/ui_theme.gd")
const FADE := 0.45
const HOLD := 1.6

var _cards: Array[Control] = []
var _index := -1
var _tween: Tween
var _root := Control.new()


func _ready() -> void:
	layer = 40
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)

	# 1 · studio
	_cards.append(_card([
		UiTheme.title("BARKSANDBYTES", 54),
		UiTheme.text("presents", 18, UiTheme.MUTED),
	]))
	# 2 · technology
	_cards.append(_card([
		UiTheme.text("Built with Godot Engine", 22),
		UiTheme.text("Geometry by Open CASCADE Technology", 22),
		UiTheme.text("Runs entirely on this device · no account, no cloud", 16, UiTheme.MUTED),
	]))
	# 3 · controller recommended
	var pad := TextureRect.new()
	pad.texture = _controller_icon()
	pad.custom_minimum_size = Vector2(360, 216)
	pad.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pad.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var hint := "Pair an Xbox controller over Bluetooth, or use the on-screen controls." if OS.has_feature("mobile") \
		else "Keyboard and mouse work too."
	_cards.append(_card([
		pad,
		UiTheme.title("BEST PLAYED WITH A CONTROLLER", 30),
		UiTheme.text(hint, 17, UiTheme.MUTED),
		UiTheme.text("Press View (or F1) any time to see the controls.", 17, UiTheme.MUTED),
	]))
	_next.call_deferred()


func _card(children: Array) -> Control:
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	for child in children:
		if child is Label:
			(child as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(child)
	c.add_child(col)
	c.modulate.a = 0.0
	c.visible = false
	_root.add_child(c)
	return c


## The controller art without its callouts, as a small picture for the third card.
func _controller_icon() -> Texture2D:
	var svg := FileAccess.get_file_as_string("res://ui/controller_map.svg")
	if svg == "":
		return null
	svg = RegEx.create_from_string("<text[\\s\\S]*?</text>").sub(svg, "", true)
	svg = RegEx.create_from_string("<g fill=\"none\" stroke=\"#ff8a3d\"[\\s\\S]*?</g>").sub(svg, "", true)
	svg = RegEx.create_from_string("<g fill=\"#ff8a3d\">[\\s\\S]*?</g>").sub(svg, "", true)
	svg = svg.replace('<rect width="1200" height="720" fill="#1b2129"/>', "")
	var img := Image.new()
	if img.load_svg_from_string(svg, 0.5) != OK:
		return null
	return ImageTexture.create_from_image(img)


func _next() -> void:
	if _tween != null:
		_tween.kill()
	if _index >= 0 and _index < _cards.size():
		_cards[_index].visible = false
	_index += 1
	if _index >= _cards.size():
		_finish()
		return
	var card := _cards[_index]
	card.visible = true
	card.modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_property(card, "modulate:a", 1.0, FADE)
	_tween.tween_interval(HOLD)
	_tween.tween_property(card, "modulate:a", 0.0, FADE)
	_tween.tween_callback(_next)


func skip_all() -> void:
	_index = _cards.size() - 1
	_next()


func _finish() -> void:
	if _tween != null:
		_tween.kill()
	visible = false
	finished.emit()
	queue_free()


func _input(e: InputEvent) -> void:
	if not visible or _index < 0:
		return
	var pressed: bool = (e is InputEventKey or e is InputEventJoypadButton or e is InputEventMouseButton \
		or e is InputEventScreenTouch) and e.is_pressed() and not e.is_echo()
	if not pressed:
		return
	get_viewport().set_input_as_handled()
	if e.is_action(&"menu"):
		skip_all()
	else:
		_next()
