extends SceneTree
## Headless smoke test, run in CI:
##   godot --headless --path godot --script res://tests/smoke_test.gd
## Checks that the extension loads, the core works through it, every script compiles and the
## main scene runs a few frames. Exits non-zero on the first failure.

var _failures := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS ", what)
	else:
		_failures += 1
		printerr("FAIL ", what)


func _initialize() -> void:
	# A script error inside _run would leave the tree running forever; give up after 2 minutes.
	var watchdog := Timer.new()
	watchdog.wait_time = 120.0
	watchdog.one_shot = true
	watchdog.autostart = true  # the root is not in the tree yet during _initialize
	watchdog.timeout.connect(func():
		printerr("FAIL smoke test timed out (last check above)")
		quit(1))
	root.add_child(watchdog)
	_run.call_deferred()


func _run() -> void:
	_check(ClassDB.class_exists(&"CadPart") and ClassDB.class_exists(&"CadAssembly"), "extension classes registered")
	if _failures > 0:
		quit(1)
		return

	var part = ClassDB.instantiate(&"CadPart")
	part.make_sample()
	var report: Dictionary = part.rebuild()
	_check(report.ok, "sample part rebuilds")
	_check(part.body_count() == 1, "sample part has one body")
	var mesh: ArrayMesh = part.build_mesh(0, 0.01)
	_check(mesh.get_surface_count() == 1 and part.triangle_faces(0).size() > 100, "display mesh with face map")
	_check(part.build_edges(0, 0.01).size() > 10, "feature edges")

	# Godot is Y-up: the roof top of the pavilion sits at y = 3.7 m.
	var hit: Dictionary = part.pick(Vector3(0.3, 10, 0), Vector3.DOWN, 100.0)
	_check(not hit.is_empty() and hit.feature_name == "Roof" and absf(hit.point.y - 3.7) < 1e-4, "pick finds the roof")
	_check(hit.get("drive_param", "") == "+h", "roof top drives its height")
	part.checkpoint()
	var pushed: Dictionary = part.push_pull(hit, 0.1)
	_check(pushed.ok and absf(pushed.drive_value - 0.4) < 1e-6, "push/pull raises the roof")
	_check(part.undo() and part.can_redo(), "undo restores the roof")

	var id: String = part.add_primitive("box", Vector3(8, 0, 8), {w = 1.0, d = 1.0, h = 1.0}, "new-body")
	part.rebuild()
	_check(id != "" and part.body_count() == 2, "place a box as a new body")
	_check(part.move_feature(id, Vector3(1, 0, 0)).ok, "move the box")
	_check(part.delete_feature(id).ok and part.body_count() == 1, "delete the box")

	var dir := OS.get_user_data_dir() + "/smoke"
	DirAccess.make_dir_recursive_absolute(dir)
	_check(part.save_file(dir + "/pavilion.fpprt") == "", "save .fpprt")
	var again = ClassDB.instantiate(&"CadPart")
	_check(again.load_file(dir + "/pavilion.fpprt") == "" and again.rebuild().ok, "load .fpprt")
	for ext in ["step", "igs", "stl", "3mf"]:
		var r: Dictionary = part.export_file(dir + "/pavilion." + ext, "mm")
		_check(r.ok and r.validated, "export %s (%s)" % [ext, r.message])

	var asm = ClassDB.instantiate(&"CadAssembly")
	asm.make_sample()
	_check(asm.rebuild().ok and asm.component_count() == 5 and asm.part_count() == 2, "sample assembly")
	_check(asm.export_file(dir + "/pins.step", "mm").ok, "export assembly STEP")
	var t: Transform3D = asm.component(1).transform
	_check(absf(t.origin.y - (-0.020)) < 1e-6, "component placement converts to Y-up")

	for script in ["actions", "player", "model_view", "tools", "tool_wheel", "hud", "touch_controls", "main",
			"ui_theme", "controller_map", "splash", "title", "tutorial"]:
		var s: Script = load("res://scripts/%s.gd" % script)
		_check(s != null and s.can_instantiate(), "script %s compiles" % script)

	var course = ClassDB.instantiate(&"CadPart")
	course.make_training()
	_check(course.rebuild().ok and course.body_count() == 5, "training course rebuilds")

	if not root.has_node("Actions"):  # autoloads may be skipped in --script mode
		var actions: Node = load("res://scripts/actions.gd").new()
		actions.name = "Actions"
		root.add_child(actions)
	# Start from a clean save so the title offers Training first.
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://settings.cfg"))

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(5)
	_check(main.doc != null and main.view != null, "main scene runs")
	_check(main.state == "splash", "launch shows the splash cards")

	await _pad(JOY_BUTTON_START)
	await _frames(5)
	_check(main.state == "title" and main.title.visible, "Start skips the splash to the title screen")

	await _frames(3)
	await _pad(JOY_BUTTON_A)
	await _frames(5)
	_check(main.state == "play" and main.mode == "training" and main.tutorial != null,
		"A on the focused title entry starts Training")
	_check(main.tutorial.step == 0, "training opens on its first objective")

	for i in 3:  # look around, a bit at a time like a real stick
		main.player.yaw += 1.5
		await _frames(2)
	await _seconds(1.6)
	_check(main.tutorial.step == 1, "looking around completes objective 1")
	main.player.feet = Vector3(0, 0.05, 9)  # stand on the walk marker
	await _seconds(1.6)
	_check(main.tutorial.step == 2, "reaching the marker completes objective 2")

	await _pad(JOY_BUTTON_START)
	await _frames(4)
	_check(main.hud.menu_open, "Start opens the pause menu")
	var focused: Control = root.get_viewport().gui_get_focus_owner()
	_check(focused is Button and (focused as Button).text == "Resume", "the pause menu focuses Resume")
	await _pad(JOY_BUTTON_A)
	await _frames(4)
	_check(not main.hud.menu_open, "A presses the focused menu button (Resume)")

	await _pad(JOY_BUTTON_START)
	await _frames(4)
	await _pad(JOY_BUTTON_B)
	await _frames(4)
	_check(not main.hud.menu_open, "B closes the pause menu")

	await _pad(JOY_BUTTON_BACK)
	await _frames(6)
	_check(main.cmap.visible, "View opens the controls map")
	_check(main.cmap.art_ready(), "the controller art rasterizes and its labels parse")
	await _pad(JOY_BUTTON_B)
	await _frames(4)
	_check(not main.cmap.visible, "B closes the controls map")

	main.tutorial._complete()
	await _frames(4)
	focused = root.get_viewport().gui_get_focus_owner()
	_check(focused is Button and main.tutorial.is_open_card(), "the training complete card takes focus")
	await _pad(JOY_BUTTON_A)
	await _frames(4)
	_check(main.tutorial == null and main.mode == "free", "A on the complete card keeps building")
	_check(load("res://scripts/tutorial.gd").is_done(), "finishing training is remembered")

	main.queue_free()
	await process_frame

	print("%d failures" % _failures)
	quit(1 if _failures > 0 else 0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _seconds(t: float) -> void:
	await create_timer(t).timeout


## Presses and releases a controller button the way a real pad would.
func _pad(button: JoyButton) -> void:
	for pressed in [true, false]:
		var e := InputEventJoypadButton.new()
		e.device = 0
		e.button_index = button
		e.pressed = pressed
		e.pressure = 1.0 if pressed else 0.0
		Input.parse_input_event(e)
		await process_frame
		await process_frame
