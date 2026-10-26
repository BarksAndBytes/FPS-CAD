extends Node3D
## Wires the game together: the CAD document (from the C++ extension), the player, the model
## view, the tools, the HUD, the tool wheel and the touch controls. Owns gameplay input, files
## and autosave. Everything runs locally; files live in the app's user:// folder.

const PROJECTS := "user://projects"
const EXPORTS := "user://exports"
const RECOVERY := "user://recovery/autosave"
const AUTOSAVE_SECONDS := 120.0
const ToolsScript := preload("res://scripts/tools.gd")

var doc: RefCounted
var is_assembly := false
var started := false
var last_saved := ""

var player: Node3D
var view: Node3D
var tools: Node
var hud: CanvasLayer
var wheel: Control
var touch: Control

var _aim := {}
var _autosave_t := 0.0
var _wheel_from_button := false


func _ready() -> void:
	for dir in [PROJECTS, EXPORTS, RECOVERY.get_base_dir()]:
		DirAccess.make_dir_recursive_absolute(dir)

	hud = preload("res://scripts/hud.gd").new()
	add_child(hud)
	if not ClassDB.class_exists(&"CadPart"):
		hud.toast("The CAD extension did not load. Build it first: see docs/BUILDING.md")
		push_error("FPS-CAD: CadPart class missing; the GDExtension in godot/bin did not load.")
		return

	view = preload("res://scripts/model_view.gd").new()
	add_child(view)
	player = preload("res://scripts/player.gd").new()
	add_child(player)
	player.cast = _cast
	player.input_enabled = false
	tools = ToolsScript.new()
	add_child(tools)
	tools.view = view
	tools.player = player
	tools.hud = hud
	tools.changed.connect(_on_model_changed)
	tools.tool_switched.connect(func(_i): _show_tool())

	wheel = preload("res://scripts/tool_wheel.gd").new()
	var wheel_layer := CanvasLayer.new()
	wheel_layer.layer = 5
	add_child(wheel_layer)
	wheel_layer.add_child(wheel)
	wheel.setup(ToolsScript.TOOLS)
	wheel.picked.connect(func(i): tools.set_tool(i))

	touch = preload("res://scripts/touch_controls.gd").new()
	hud.add_child(touch)
	touch.player = player
	touch.action_pressed.connect(_on_touch_pressed)
	touch.action_released.connect(_on_touch_released)

	hud.request.connect(_on_hud_request)
	Actions.device_changed.connect(_on_device_changed)
	_on_device_changed(Actions.last_device if not OS.has_feature("mobile") else "touch")

	var part = ClassDB.instantiate(&"CadPart")
	part.make_sample()
	_open(part, false)


# ---------- documents ----------

func _open(new_doc: RefCounted, assembly: bool) -> void:
	doc = new_doc
	is_assembly = assembly
	var report: Dictionary = doc.rebuild()
	if not report.ok:
		var names := []
		for f in report.failures:
			names.append("%s (%s)" % [f.name, f.message])
		hud.toast("Rebuilt with errors: " + ", ".join(names))
	view.doc = doc
	view.is_assembly = assembly
	view.refresh(player.size)
	tools.doc = doc
	tools.is_assembly = assembly
	tools.selected = ""
	hud.doc = doc
	hud.units = doc.get_units() if doc.has_method("get_units") else "mm"
	hud.refresh_panel()
	_show_tool()


func _on_model_changed() -> void:
	view.refresh()
	if hud.panel_open:
		hud.refresh_panel()


func _doc_name() -> String:
	var n: String = doc.get_assembly_name() if is_assembly else doc.get_part_name()
	return n.to_lower().replace(" ", "-").validate_filename()


func _save(path: String = "") -> void:
	if path == "":
		path = "%s/%s.%s" % [PROJECTS, _doc_name(), "fpasm" if is_assembly else "fpprt"]
	var err: String = doc.save_file(ProjectSettings.globalize_path(path))
	if err == "":
		last_saved = path
		hud.toast("Saved to " + ProjectSettings.globalize_path(path))
	else:
		hud.toast("Not saved: " + err)


func _export(ext: String) -> void:
	var path := ProjectSettings.globalize_path("%s/%s.%s" % [EXPORTS, _doc_name(), ext])
	hud.toast("Exporting %s…" % ext.to_upper())
	await get_tree().process_frame
	var r: Dictionary = doc.export_file(path, hud.units if hud.units in ["mm", "cm", "m", "in"] else "mm")
	hud.toast(("Exported %s · %s" % [path, r.message]) if r.ok else ("Export failed: " + r.message))


func _autosave() -> void:
	if doc == null or not started:
		return
	var path := RECOVERY + (".fpasm" if is_assembly else ".fpprt")
	doc.save_file(ProjectSettings.globalize_path(path))


func _notification(what: int) -> void:
	# Android may stop a backgrounded app without warning, so save on the way out.
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_autosave()


# ---------- frame ----------

func _cast(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	if doc == null:
		return {}
	return doc.pick(origin, dir, max_distance)


func _aim_hit() -> Dictionary:
	var o: Vector3 = player.eye_position()
	var d: Vector3 = player.aim_direction()
	var hit: Dictionary = doc.pick(o, d, player.camera.far)
	var ground := {}
	if d.y < -1e-6 and o.y > 0.0:
		var t := -o.y / d.y
		if hit.is_empty() or t < hit.distance:
			ground = {hit = true, ground = true, point = o + d * t, normal = Vector3.UP, distance = t}
	return ground if not ground.is_empty() else hit


func _process(dt: float) -> void:
	if doc == null:
		return
	var playing: bool = started and not hud.panel_open and not hud.menu_open
	player.input_enabled = playing and not wheel.visible
	view.follow(player.camera.global_position, player.size)
	_aim = _aim_hit() if started else {}
	if playing:
		_gameplay_input()
	tools.update(_aim if playing else {}, dt)
	hud.set_readout(player.size, player.grid_step(), player.snap_step(), player.fly, player.feet)
	hud.set_measure(tools.measure_text())
	touch.set_fly(player.fly)
	_autosave_t += dt
	if _autosave_t > AUTOSAVE_SECONDS:
		_autosave_t = 0.0
		_autosave()
	_update_mouse_mode()


func _gameplay_input() -> void:
	if wheel.visible:
		wheel.aim(Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down"))
		if not _wheel_from_button and Input.is_action_just_released(&"tool_wheel"):
			var i: int = wheel.close(true)
			if i >= 0:
				tools.set_tool(i)
		return
	if Input.is_action_just_pressed(&"tool_wheel"):
		_wheel_from_button = false
		wheel.open(tools.index)
		return
	# The click that captures the mouse should not also fire the tool.
	var mouse_free: bool = Actions.last_device == "keyboard" and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	if Input.is_action_just_pressed(&"primary") and not mouse_free:
		tools.press(true)
	elif Input.is_action_just_released(&"primary"):
		tools.release()
	if Input.is_action_just_pressed(&"secondary") and not mouse_free:
		tools.press(false)
	elif Input.is_action_just_released(&"secondary"):
		tools.release()
	if Input.is_action_just_pressed(&"context_wheel"):
		tools.cycle_option()
		_show_tool()
	for i in 9:
		if Input.is_action_just_pressed(StringName("tool_%d" % (i + 1))):
			tools.set_tool(i)
	if Input.is_action_just_pressed(&"redo"):
		if doc.has_method("redo") and doc.redo():
			_on_model_changed()
			hud.toast("Redo")
	elif Input.is_action_just_pressed(&"undo") and not Input.is_key_pressed(KEY_SHIFT):
		if doc.has_method("undo") and doc.undo():
			_on_model_changed()
			hud.toast("Undo")
	if Input.is_action_just_pressed(&"inspect"):
		var id: String = _aim.get("feature_id", "")
		tools.selected = id
		hud.show_feature(id)
		hud.set_panel(true)
	if Input.is_action_just_pressed(&"delete_selected") and tools.selected != "" and not is_assembly:
		var r: Dictionary = doc.delete_feature(tools.selected)
		tools.selected = ""
		hud.toast(r.message)
		_on_model_changed()
	if Input.is_action_just_pressed(&"finish"):
		hud.toast("Sketch mode arrives in Phase 1")
	if Input.is_action_just_pressed(&"screenshot"):
		_screenshot()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"menu"):
		if not started:
			return
		if hud.panel_open:
			hud.set_panel(false)
		else:
			hud.set_menu(not hud.menu_open)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"model_panel") and started:
		hud.toggle_panel()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and wheel != null and wheel.visible and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		wheel.point(event.relative)
	elif event is InputEventMouseButton and event.pressed and started and not hud.panel_open and not hud.menu_open \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and Actions.last_device == "keyboard":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED  # first click on the view grabs the mouse
		get_viewport().set_input_as_handled()


func _update_mouse_mode() -> void:
	var want_free: bool = not started or hud.panel_open or hud.menu_open or Actions.last_device == "touch" \
		or (wheel.visible and _wheel_from_button)
	if want_free and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _screenshot() -> void:
	DirAccess.make_dir_recursive_absolute("user://screenshots")
	var path := "user://screenshots/%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
	get_viewport().get_texture().get_image().save_png(path)
	hud.toast("Screenshot saved to " + ProjectSettings.globalize_path(path))


# ---------- UI requests ----------

func _show_tool() -> void:
	hud.set_tool(tools.tool(), tools.option())


func _on_device_changed(kind: String) -> void:
	touch.visible = kind == "touch"
	# On touch screens the OS also sends emulated mouse clicks; tool actions come from the
	# on-screen buttons instead, so stop mouse buttons from firing tools.
	for action in [&"primary", &"secondary"]:
		for e in InputMap.action_get_events(action):
			if e is InputEventMouseButton and kind == "touch":
				InputMap.action_erase_event(action, e)
		if kind != "touch" and InputMap.action_get_events(action).filter(func(e): return e is InputEventMouseButton).is_empty():
			var mb := InputEventMouseButton.new()
			mb.button_index = MOUSE_BUTTON_LEFT if action == &"primary" else MOUSE_BUTTON_RIGHT
			InputMap.action_add_event(action, mb)
	if tools != null:
		_show_tool()


func _on_touch_pressed(name: String) -> void:
	if not started:
		return
	match name:
		"primary":
			tools.press(true)
		"secondary":
			tools.press(false)
		"wheel":
			_wheel_from_button = true
			wheel.open(tools.index)


func _on_touch_released(name: String) -> void:
	if name != "wheel":
		tools.release()


func _on_hud_request(action: String, arg: Variant) -> void:
	match action:
		"start":
			started = true
			hud.hide_start()
			player.input_enabled = true
			if Actions.last_device == "keyboard":
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		"open_wheel":
			if started:
				_wheel_from_button = true
				wheel.open(tools.index)
		"undo":
			if doc.has_method("undo") and doc.undo():
				_on_model_changed()
		"redo":
			if doc.has_method("redo") and doc.redo():
				_on_model_changed()
		"fly":
			player.fly = not player.fly
			hud.toast("Fly on · through walls" if player.fly else "Walking")
		"panel":
			hud.toggle_panel()
		"menu":
			hud.set_menu(not hud.menu_open)
		"resume":
			hud.set_menu(false)
		"save":
			_save()
		"open_saved":
			if last_saved == "":
				hud.toast("Nothing saved yet in this session")
				return
			var d = ClassDB.instantiate(&"CadAssembly" if last_saved.ends_with(".fpasm") else &"CadPart")
			var err: String = d.load_file(ProjectSettings.globalize_path(last_saved))
			if err != "":
				hud.toast(err)
				return
			_open(d, last_saved.ends_with(".fpasm"))
			hud.set_menu(false)
		"sample_part":
			var p = ClassDB.instantiate(&"CadPart")
			p.make_sample()
			_open(p, false)
			hud.set_menu(false)
		"sample_assembly":
			var a = ClassDB.instantiate(&"CadAssembly")
			a.make_sample()
			player.set_size(0.05)  # the pin plate is 200 mm across
			_open(a, true)
			hud.set_menu(false)
		"export_step":
			_export("step")
		"export_iges":
			_export("igs")
		"export_stl":
			_export("stl")
		"export_3mf":
			_export("3mf")
		"quit":
			_autosave()
			get_tree().quit()
		"select_feature":
			tools.selected = arg
		"delete_feature":
			var r: Dictionary = doc.delete_feature(arg)
			hud.toast(r.message)
			tools.selected = ""
			hud.show_feature("")
			_on_model_changed()
		"set_param":
			var r: Dictionary = doc.set_param(arg[0], arg[1], arg[2])
			hud.toast(r.message)
			_on_model_changed()
		"set_variable":
			var r: Dictionary = doc.set_variable(arg[0], arg[1])
			hud.toast(r.message)
			_on_model_changed()
