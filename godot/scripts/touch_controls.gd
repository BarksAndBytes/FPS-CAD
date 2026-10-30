extends Control
## On-screen controls for touch screens: two joysticks (move on the left, look on the right),
## drag-to-look on the rest of the right side, and buttons for the tool actions, jumping and size.
## Handles raw multi-touch so one thumb can walk while the other looks or fires.
##
## The move stick rests bottom-left and jumps to wherever the left thumb lands, returning home on
## release; pushing well past its ring sprints. The look stick turns at a rate set by how far it
## is pushed, like a controller's right stick.

signal action_pressed(name: String)   # "primary", "secondary", "wheel"
signal action_released(name: String)

const UiTheme := preload("res://scripts/ui_theme.gd")
const STICK_RADIUS := 62.0
const LOOK_SENS := 0.0055
const SPRINT_PAST := 1.35  # drag this far past the ring (in radii) to sprint

var player: Node3D
var _stick_index := -1
var _stick_origin := Vector2.ZERO
var _stick_home := Vector2.ZERO
var _look_index := -1
var _look_home := Vector2.ZERO
var _look_base := Panel.new()
var _look_knob := Panel.new()
var _labels := {}
var _look := {}        # touch index -> last position
var _held := {}        # touch index -> button name
var _buttons := {}     # name -> Control
var _stick_base := Panel.new()
var _stick_knob := Panel.new()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # in the tree already: offsets must follow too
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for pair in [[_stick_base, _stick_knob, "MOVE"], [_look_base, _look_knob, "LOOK"]]:
		var base: Panel = pair[0]
		var knob: Panel = pair[1]
		base.size = Vector2(STICK_RADIUS * 2.0, STICK_RADIUS * 2.0)
		knob.size = Vector2(56, 56)
		base.add_theme_stylebox_override("panel", _round(Color(0.07, 0.08, 0.1, 0.38), int(STICK_RADIUS)))
		knob.add_theme_stylebox_override("panel", _round(Color(0.91, 0.93, 0.95, 0.6), 28))
		base.mouse_filter = Control.MOUSE_FILTER_IGNORE
		knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(base)
		add_child(knob)
		var l := Label.new()
		l.text = pair[2]
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.75))
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
		l.add_theme_constant_override("outline_size", 4)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.size = Vector2(STICK_RADIUS * 2.0, 16)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(l)
		_labels[pair[2]] = l
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
		right_pad = maxf(pad, UiTheme.from_window_px(self, DisplayServer.window_get_size().x - safe.end.x))
	_buttons.primary.position = Vector2(s.x - right_pad - 84, s.y - pad - 84)
	_buttons.secondary.position = Vector2(s.x - right_pad - 84 + 11, s.y - pad - 84 - 74)
	_buttons.jump.position = Vector2(s.x - right_pad - 84 - 78, s.y - pad - 62)
	_buttons.down.position = Vector2(s.x - right_pad - 84 - 78 + 4, s.y - pad - 62 - 64)
	_buttons.grow.position = Vector2(s.x - right_pad - 52, s.y * 0.38)
	_buttons.shrink.position = Vector2(s.x - right_pad - 52, s.y * 0.38 + 62)
	_buttons.wheel.position = Vector2(s.x - right_pad - 84 - 78 - 66, s.y - pad - 54)
	var left_pad := pad
	if safe.size.x > 0:
		left_pad = maxf(pad, UiTheme.from_window_px(self, safe.position.x))
	# The sticks rest where thumbs fall: move bottom-left, look just inside the button cluster.
	_stick_home = Vector2(left_pad + STICK_RADIUS + 18, s.y - pad - STICK_RADIUS - 18)
	_look_home = Vector2(_buttons.wheel.position.x - 30 - STICK_RADIUS, s.y - pad - STICK_RADIUS - 18)
	if _stick_index < 0:
		_place(_stick_base, _stick_knob, _stick_home, Vector2.ZERO)
	if _look_index < 0:
		_place(_look_base, _look_knob, _look_home, Vector2.ZERO)


func _place(base: Panel, knob: Panel, centre: Vector2, offset: Vector2) -> void:
	base.position = centre - base.size / 2.0
	knob.position = centre + offset - knob.size / 2.0
	var l: Label = _labels["MOVE" if base == _stick_base else "LOOK"]
	l.position = centre + Vector2(-STICK_RADIUS, STICK_RADIUS + 2)


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
			elif _look_index < 0 and event.position.distance_to(_look_home) < STICK_RADIUS * 1.5:
				_look_index = event.index
				_drag_look(event.position)
			elif event.position.x < size.x * 0.45 and event.position.y > size.y * 0.3 and _stick_index < 0:
				# The move stick jumps under the thumb, wherever it lands on the left side.
				_stick_index = event.index
				_stick_origin = event.position
				_place(_stick_base, _stick_knob, _stick_origin, Vector2.ZERO)
			else:
				_look[event.index] = event.position
		else:
			if _held.has(event.index):
				_press(_held[event.index], false)
				_held.erase(event.index)
			if event.index == _stick_index:
				_stick_index = -1
				player.move_from_touch = Vector2.ZERO
				player.touch_sprint = false
				_place(_stick_base, _stick_knob, _stick_home, Vector2.ZERO)
			if event.index == _look_index:
				_look_index = -1
				player.look_stick_touch = Vector2.ZERO
				_place(_look_base, _look_knob, _look_home, Vector2.ZERO)
			_look.erase(event.index)
	elif event is InputEventScreenDrag:
		if event.index == _stick_index:
			var raw: Vector2 = event.position - _stick_origin
			var d := raw.limit_length(STICK_RADIUS)
			_place(_stick_base, _stick_knob, _stick_origin, d)
			player.move_from_touch = Vector2(d.x, -d.y) / STICK_RADIUS
			player.touch_sprint = raw.length() > STICK_RADIUS * SPRINT_PAST
		elif event.index == _look_index:
			_drag_look(event.position)
		elif _look.has(event.index):
			player.look_from_touch += (event.position - _look[event.index]) * LOOK_SENS
			_look[event.index] = event.position


func _drag_look(pos: Vector2) -> void:
	var d := (pos - _look_home).limit_length(STICK_RADIUS)
	_place(_look_base, _look_knob, _look_home, d)
	player.look_stick_touch = d / STICK_RADIUS  # screen axes: right and down are positive


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
