extends Control
## On-screen controls for touch screens: a floating stick on the left, drag-to-look on the right,
## and buttons for the tool actions, jumping and size. Handles raw multi-touch so a thumb can walk
## while the other thumb fires.

signal action_pressed(name: String)   # "primary", "secondary", "wheel"
signal action_released(name: String)

const STICK_RADIUS := 60.0
const LOOK_SENS := 0.0055

var player: Node3D
var _stick_index := -1
var _stick_origin := Vector2.ZERO
var _look := {}        # touch index -> last position
var _held := {}        # touch index -> button name
var _buttons := {}     # name -> Control
var _stick_base := Panel.new()
var _stick_knob := Panel.new()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # in the tree already: offsets must follow too
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_base.size = Vector2(120, 120)
	_stick_knob.size = Vector2(50, 50)
	_stick_base.add_theme_stylebox_override("panel", _round(Color(0.07, 0.08, 0.1, 0.35), 60))
	_stick_knob.add_theme_stylebox_override("panel", _round(Color(0.91, 0.93, 0.95, 0.55), 25))
	_stick_base.visible = false
	_stick_knob.visible = false
	_stick_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stick_base)
	add_child(_stick_knob)
	_add_button("primary", "FIRE", 84, Color("ff8a3d"))
	_add_button("secondary", "ALT", 62, Color("e8edf3"))
	_add_button("jump", "JUMP", 62, Color("e8edf3"))
	_add_button("down", "DOWN", 54, Color("e8edf3"))
	_add_button("grow", "+", 52, Color("e8edf3"))
	_add_button("shrink", "−", 52, Color("e8edf3"))
	_add_button("wheel", "TOOL", 54, Color("e8edf3"))
	resized.connect(_layout)
	_layout()


func _round(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.border_color = Color(0.89, 0.91, 0.95, 0.3)
	sb.set_border_width_all(2)
	return sb


func _add_button(name: String, text: String, d: float, tint: Color) -> void:
	var p := Panel.new()
	p.size = Vector2(d, d)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", _round(Color(0.07, 0.08, 0.1, 0.55), int(d / 2)))
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", tint)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	p.add_child(l)
	add_child(p)
	_buttons[name] = p


func _layout() -> void:
	var s := size
	var pad := 24.0
	var safe := DisplayServer.get_display_safe_area()
	var right_pad := pad
	if safe.size.x > 0:
		right_pad = maxf(pad, DisplayServer.screen_get_size().x - safe.end.x)
	_buttons.primary.position = Vector2(s.x - right_pad - 84, s.y - pad - 84)
	_buttons.secondary.position = Vector2(s.x - right_pad - 84 + 11, s.y - pad - 84 - 74)
	_buttons.jump.position = Vector2(s.x - right_pad - 84 - 78, s.y - pad - 62)
	_buttons.down.position = Vector2(s.x - right_pad - 84 - 78 + 4, s.y - pad - 62 - 64)
	_buttons.grow.position = Vector2(s.x - right_pad - 52, s.y * 0.38)
	_buttons.shrink.position = Vector2(s.x - right_pad - 52, s.y * 0.38 + 62)
	_buttons.wheel.position = Vector2(s.x - right_pad - 84 - 78 - 66, s.y - pad - 54)


func set_fly(on: bool) -> void:
	(_buttons.down as Control).visible = on
	(_buttons.jump.get_child(0) as Label).text = "UP" if on else "JUMP"


func _button_at(pos: Vector2) -> String:
	for name in _buttons:
		var c: Control = _buttons[name]
		if c.visible and c.get_global_rect().grow(8).has_point(pos):
			return name
	return ""


func _input(event: InputEvent) -> void:
	if not visible or player == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			var b := _button_at(event.position)
			if b != "":
				_held[event.index] = b
				_press(b, true)
			elif event.position.x < size.x * 0.45 and event.position.y > size.y * 0.3 and _stick_index < 0:
				_stick_index = event.index
				_stick_origin = event.position
				_stick_base.position = event.position - _stick_base.size / 2.0
				_stick_knob.position = event.position - _stick_knob.size / 2.0
				_stick_base.visible = true
				_stick_knob.visible = true
			else:
				_look[event.index] = event.position
		else:
			if _held.has(event.index):
				_press(_held[event.index], false)
				_held.erase(event.index)
			if event.index == _stick_index:
				_stick_index = -1
				player.move_from_touch = Vector2.ZERO
				_stick_base.visible = false
				_stick_knob.visible = false
			_look.erase(event.index)
	elif event is InputEventScreenDrag:
		if event.index == _stick_index:
			var d: Vector2 = (event.position - _stick_origin).limit_length(STICK_RADIUS)
			_stick_knob.position = _stick_origin + d - _stick_knob.size / 2.0
			player.move_from_touch = Vector2(d.x, -d.y) / STICK_RADIUS
		elif _look.has(event.index):
			player.look_from_touch += (event.position - _look[event.index]) * LOOK_SENS
			_look[event.index] = event.position


func _press(name: String, down: bool) -> void:
	(_buttons[name] as Control).modulate = Color(1.0, 0.75, 0.55) if down else Color.WHITE
	match name:
		"jump":
			player.touch_up = down
		"down":
			player.touch_down = down
		"grow":
			if down:
				player.scale_by(1.12)
			player.hold_scale(1.0 if down else 0.0)
		"shrink":
			if down:
				player.scale_by(1.0 / 1.12)
			player.hold_scale(-1.0 if down else 0.0)
		_:
			if down:
				action_pressed.emit(name)
			else:
				action_released.emit(name)
