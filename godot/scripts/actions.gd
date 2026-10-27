extends Node
## Every input action, registered in code so the bindings read as one table and can be remapped
## at runtime. Each action has keyboard/mouse events and Xbox controller events.
##
## Autoloaded as "Actions". Also tracks which kind of device was used last so prompts can show
## the right glyphs.

signal device_changed(kind: String)

const BINDINGS_PATH := "user://bindings.cfg"
const STICK_DEADZONE := 0.2
const TRIGGER_DEADZONE := 0.35

## "controller", "keyboard" or "touch"
var last_device := "keyboard"


func _ready() -> void:
	# Movement and looking
	_keys(&"move_forward", [KEY_W]); _axis(&"move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_keys(&"move_back", [KEY_S]); _axis(&"move_back", JOY_AXIS_LEFT_Y, 1.0)
	_keys(&"move_left", [KEY_A]); _axis(&"move_left", JOY_AXIS_LEFT_X, -1.0)
	_keys(&"move_right", [KEY_D]); _axis(&"move_right", JOY_AXIS_LEFT_X, 1.0)
	_axis(&"look_left", JOY_AXIS_RIGHT_X, -1.0)
	_axis(&"look_right", JOY_AXIS_RIGHT_X, 1.0)
	_axis(&"look_up", JOY_AXIS_RIGHT_Y, -1.0)
	_axis(&"look_down", JOY_AXIS_RIGHT_Y, 1.0)
	_keys(&"sprint_hold", [KEY_SHIFT])
	_button(&"sprint_toggle", JOY_BUTTON_LEFT_STICK)
	_button(&"precision_aim", JOY_BUTTON_RIGHT_STICK); _keys(&"precision_aim", [KEY_ALT])
	_keys(&"jump", [KEY_SPACE]); _button(&"jump", JOY_BUTTON_A)
	_keys(&"crouch", [KEY_C]); _button(&"crouch", JOY_BUTTON_B)
	_keys(&"toggle_fly", [KEY_F])

	# Tools
	_mouse(&"primary", MOUSE_BUTTON_LEFT); _trigger(&"primary", JOY_AXIS_TRIGGER_RIGHT)
	_mouse(&"secondary", MOUSE_BUTTON_RIGHT); _trigger(&"secondary", JOY_AXIS_TRIGGER_LEFT)
	_keys(&"tool_wheel", [KEY_Q]); _button(&"tool_wheel", JOY_BUTTON_RIGHT_SHOULDER)
	_keys(&"context_wheel", [KEY_E]); _button(&"context_wheel", JOY_BUTTON_LEFT_SHOULDER)
	_keys(&"finish", [KEY_ENTER]); _button(&"finish", JOY_BUTTON_X)
	_keys(&"inspect", [KEY_I]); _button(&"inspect", JOY_BUTTON_Y)
	for i in 9:
		_keys(StringName("tool_%d" % (i + 1)), [KEY_1 + i])

	# Size and history
	_keys(&"grow", [KEY_EQUAL, KEY_KP_ADD]); _button(&"grow", JOY_BUTTON_DPAD_UP)
	_keys(&"shrink", [KEY_MINUS, KEY_KP_SUBTRACT]); _button(&"shrink", JOY_BUTTON_DPAD_DOWN)
	_keys(&"reset_size", [KEY_R])
	_button(&"undo", JOY_BUTTON_DPAD_LEFT); _chord(&"undo", KEY_Z, false)
	_button(&"redo", JOY_BUTTON_DPAD_RIGHT); _chord(&"redo", KEY_Z, true); _chord(&"redo", KEY_Y, false)
	_keys(&"delete_selected", [KEY_DELETE])

	# Menus. Godot's built-in ui_accept and ui_cancel have no controller buttons (keyboard only),
	# so without these A and B do nothing in menus.
	_button(&"ui_accept", JOY_BUTTON_A)
	_button(&"ui_cancel", JOY_BUTTON_B)
	# Arrow keys belong to menus and the feature panel (WASD walks); the D-pad navigates too.
	for pair in [[&"ui_up", JOY_BUTTON_DPAD_UP], [&"ui_down", JOY_BUTTON_DPAD_DOWN],
			[&"ui_left", JOY_BUTTON_DPAD_LEFT], [&"ui_right", JOY_BUTTON_DPAD_RIGHT]]:
		var has_pad := false
		for e in InputMap.action_get_events(pair[0]):
			if e is InputEventJoypadButton and e.button_index == pair[1]:
				has_pad = true
		if not has_pad:
			_button(pair[0], pair[1])
	_keys(&"model_panel", [KEY_TAB])
	_keys(&"controller_map", [KEY_F1]); _button(&"controller_map", JOY_BUTTON_BACK)
	_keys(&"menu", [KEY_ESCAPE]); _button(&"menu", JOY_BUTTON_START)
	_keys(&"screenshot", [KEY_F12]); _button(&"screenshot", JOY_BUTTON_MISC1)

	_load_rebinds()


func _input(event: InputEvent) -> void:
	var kind := last_device
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5):
		kind = "controller"
	elif event is InputEventKey or event is InputEventMouseButton:
		kind = "keyboard"
	elif event is InputEventMouseMotion and event.relative.length() > 4.0:
		kind = "keyboard"
	elif event is InputEventScreenTouch:
		kind = "touch"
	if kind != last_device:
		last_device = kind
		device_changed.emit(kind)


## Short label for an action's binding on the device in use, for on-screen prompts.
func prompt(action: StringName) -> String:
	const PAD := {
		&"primary": "RT", &"secondary": "LT", &"tool_wheel": "RB", &"context_wheel": "LB",
		&"jump": "A", &"crouch": "B", &"finish": "X", &"inspect": "Y", &"grow": "D-pad ↑",
		&"shrink": "D-pad ↓", &"undo": "D-pad ←", &"redo": "D-pad →", &"model_panel": "View",
		&"menu": "Menu", &"precision_aim": "R3", &"sprint_toggle": "L3", &"controller_map": "View",
		&"ui_accept": "A", &"ui_cancel": "B", &"move": "Left stick", &"look": "Right stick",
		&"inspect_panel": "Y", &"sketch_tools": "RB", &"normal_to": "Y",
	}
	const KEYS := {
		&"primary": "LMB", &"secondary": "RMB", &"tool_wheel": "Q", &"context_wheel": "E",
		&"jump": "Space", &"crouch": "C", &"finish": "Enter", &"inspect": "I", &"grow": "=",
		&"shrink": "−", &"undo": "Ctrl+Z", &"redo": "Ctrl+Shift+Z", &"model_panel": "Tab",
		&"menu": "Esc", &"precision_aim": "Alt", &"sprint_toggle": "Shift", &"toggle_fly": "F",
		&"controller_map": "F1", &"ui_accept": "Enter", &"ui_cancel": "Esc", &"move": "WASD",
		&"look": "Mouse", &"inspect_panel": "Tab", &"sketch_tools": "Q", &"normal_to": "I",
	}
	const TOUCH := {
		&"primary": "Fire", &"secondary": "Alt", &"tool_wheel": "Tool", &"jump": "Jump",
		&"grow": "+", &"shrink": "−", &"controller_map": "Controls", &"menu": "Menu",
		&"ui_accept": "Tap", &"ui_cancel": "Back", &"move": "Left thumb", &"look": "Right thumb",
		&"inspect_panel": "Model", &"undo": "Undo", &"context_wheel": "Tool chip",
	}
	match last_device:
		"controller":
			return PAD.get(action, String(action))
		"touch":
			return TOUCH.get(action, String(action))
	return KEYS.get(action, String(action))


## Replaces an action's binding for one device kind and saves it.
func rebind(action: StringName, event: InputEvent) -> void:
	var pad: bool = event is InputEventJoypadButton or event is InputEventJoypadMotion
	for e in InputMap.action_get_events(action):
		var e_pad: bool = e is InputEventJoypadButton or e is InputEventJoypadMotion
		if e_pad == pad:
			InputMap.action_erase_event(action, e)
	InputMap.action_add_event(action, event)
	var cfg := ConfigFile.new()
	cfg.load(BINDINGS_PATH)
	cfg.set_value("bindings", String(action), InputMap.action_get_events(action))
	cfg.save(BINDINGS_PATH)


func _load_rebinds() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(BINDINGS_PATH) != OK:
		return
	for action in cfg.get_section_keys("bindings"):
		if action.begins_with("ui_"):
			continue  # menu navigation stays fixed so a bad remap cannot lock players out
		var events: Array = cfg.get_value("bindings", action, [])
		if not InputMap.has_action(action) or events.is_empty():
			continue
		InputMap.action_erase_events(action)
		for e in events:
			if e is InputEvent:
				InputMap.action_add_event(action, e)


func _ensure(action: StringName, deadzone := STICK_DEADZONE) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, deadzone)


func _keys(action: StringName, keys: Array) -> void:
	_ensure(action)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)


func _chord(action: StringName, key: Key, shift: bool) -> void:
	_ensure(action)
	var e := InputEventKey.new()
	e.physical_keycode = key
	e.command_or_control_autoremap = true
	e.shift_pressed = shift
	InputMap.action_add_event(action, e)


func _mouse(action: StringName, button: MouseButton) -> void:
	_ensure(action)
	var e := InputEventMouseButton.new()
	e.button_index = button
	InputMap.action_add_event(action, e)


func _button(action: StringName, button: JoyButton) -> void:
	_ensure(action)
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.device = -1
	InputMap.action_add_event(action, e)


func _axis(action: StringName, axis: JoyAxis, value: float) -> void:
	_ensure(action)
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	e.device = -1
	InputMap.action_add_event(action, e)


func _trigger(action: StringName, axis: JoyAxis) -> void:
	_ensure(action, TRIGGER_DEADZONE)
	InputMap.action_set_deadzone(action, TRIGGER_DEADZONE)
	_axis(action, axis, 1.0)
