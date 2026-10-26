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

	for script in ["actions", "player", "model_view", "tools", "tool_wheel", "hud", "touch_controls", "main"]:
		var s: Script = load("res://scripts/%s.gd" % script)
		_check(s != null and s.can_instantiate(), "script %s compiles" % script)

	if not root.has_node("Actions"):  # autoloads may be skipped in --script mode
		var actions: Node = load("res://scripts/actions.gd").new()
		actions.name = "Actions"
		root.add_child(actions)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 10:
		await process_frame
	_check(main.doc != null and main.view != null, "main scene runs")
	main.queue_free()
	await process_frame

	print("%d failures" % _failures)
	quit(1 if _failures > 0 else 0)
