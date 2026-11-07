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
			"ui_theme", "controller_map", "splash", "title", "tutorial", "sketcher", "feature_dialog", "number_pad", "units", "updater", "build_info", "challenge", "room", "fat_lines"]:
		var s: Script = load("res://scripts/%s.gd" % script)
		_check(s != null and s.can_instantiate(), "script %s compiles" % script)

	# Sketch → extrude through the bindings alone.
	var blank = ClassDB.instantiate(&"CadPart")
	blank.new_blank("Bindings", "mm")
	var plane: Dictionary = blank.standard_plane("front")
	var basis: Dictionary = blank.plane_basis(plane.plane)
	_check(plane.name == "Front" and basis.normal.is_equal_approx(Vector3(0, 0, 1)), "Front plane faces +Z in Godot space")
	var rect := {plane = plane.plane, planeName = "Front", points = [
		{id = "b", x = 0.9, y = 0.0}, {id = "c", x = 1.1, y = 0.6}, {id = "d", x = 0.0, y = 0.5}],
		entities = [{id = "l1", kind = "line", pts = ["o", "b"]}, {id = "l2", kind = "line", pts = ["b", "c"]},
			{id = "l3", kind = "line", pts = ["c", "d"]}, {id = "l4", kind = "line", pts = ["d", "o"]}],
		constraints = [{id = "h1", kind = "horizontal", refs = ["l1"]}, {id = "v2", kind = "vertical", refs = ["l2"]},
			{id = "h3", kind = "horizontal", refs = ["l3"]}, {id = "v4", kind = "vertical", refs = ["l4"]},
			{id = "w", kind = "distance", refs = ["l1"], value = 1.0}, {id = "h", kind = "distance", refs = ["l2"], value = "500 mm"}]}
	var solved: Dictionary = blank.solve_sketch(rect)
	_check(solved.ok and solved.dof == 0, "solve_sketch squares up a dimensioned rectangle (%s)" % solved.message)
	var sk_id: String = blank.add_sketch(solved.sketch)
	blank.checkpoint()
	var ins: Dictionary = blank.insert_feature("extrude", "add", {sketch = sk_id, depth = 0.2})
	_check(ins.ok and absf(blank.mass_properties().volume - 0.1) < 1e-6, "insert_feature extrudes the sketch")
	blank.update_feature(ins.id, "", {depth = 0.4})
	_check(absf(blank.mass_properties().volume - 0.2) < 1e-6, "update_feature changes the preview")
	blank.abandon()
	_check(blank.body_count() == 0 and blank.latest_unused_sketch() == sk_id, "abandon removes the preview")
	var aimed: Dictionary = blank.pick_sketch(Vector3(0.5, 0.25, 5), Vector3(0, 0, -1), 20.0, 0.02, false)
	_check(aimed.get("feature_id", "") == sk_id and aimed.region == 0, "pick_sketch finds the profile")

	# Mass properties readout: significant figures in the document's units, small masses in grams.
	var U = load("res://scripts/units.gd")
	_check(U.significant(1234567.0) == "1,235,000" and U.significant(12.5) == "12.5" and U.significant(0.000123456) == "0.0001235"
		and U.significant(-2500.0) == "-2,500", "numbers are shown to four significant figures (%s, %s, %s)" % [U.significant(1234567.0), U.significant(12.5), U.significant(0.000123456)])
	var box_m := {volume = 0.05 * 0.04 * 0.01, area = 2.0 * (0.05 * 0.04 + 0.05 * 0.01 + 0.04 * 0.01), mass = 0.05 * 0.04 * 0.01 * 7850.0}
	var summary: String = load("res://scripts/tools.gd").mass_summary(box_m, "mm", "25 mm", "20 mm", "5.0 mm")
	_check(summary.begins_with("Volume 20,000 mm³ · area 5,800 mm² · mass 157 g"), "a 50 × 40 × 10 mm steel block reads 20,000 mm³, 5,800 mm², 157 g (%s)" % summary)
	_check(U.volume_text(0.25, "m") == "0.25 m³" and U.area_text(0.0001, "cm") == "1 cm²" and U.mass_text(12.3456) == "12.35 kg",
		"volume, area and mass read in metres, centimetres and kilograms too")

	# Update checks: the decision logic, without touching the network.
	var up = load("res://scripts/updater.gd")
	var newer: Dictionary = up.evaluate({build = 12, apk = "https://example.invalid/a.apk", signing = "release"}, 11)
	_check(newer.newer, "a higher build number is offered as an update")
	_check(not up.evaluate({build = 11, apk = "x", signing = "release"}, 11).newer, "the same build is not an update")
	_check(not up.evaluate({build = 13, apk = "x", signing = "debug"}, 11).newer, "a debug-signed build is not offered (it could not install over this one)")
	_check(not up.evaluate("nonsense", 11).newer and not up.evaluate({build = 13}, 11).newer, "unreadable update information is ignored")
	_check(not up.supported(), "local and editor builds never check for updates")
	# Each platform reads only its own channel and refuses another platform's information.
	_check(up.latest_url("windows").ends_with("/windows-dev/latest.json") and up.latest_url("android").ends_with("/android-dev/latest.json"), "each platform has its own update channel")
	var win_info := {build = 12, url = "https://example.invalid/w.zip", platform = "windows"}
	_check(up.evaluate(win_info, 11, "windows").newer, "a Windows build is offered to Windows")
	_check(not up.evaluate(win_info, 11, "android").newer, "a Windows build is never offered to Android")
	_check(not up.evaluate({build = 12, url = "x", platform = "android", signing = "release"}, 11, "windows").newer, "an Android build is never offered to Windows")
	_check(not up.evaluate({build = 12, apk = "x", signing = "release"}, 11, "windows").newer, "older Android update files (no platform) are never offered to Windows")
	# Windows install: unpack over the game folder, setting the running files aside.
	var game_dir := OS.get_user_data_dir().path_join("smoke-update-game")
	DirAccess.make_dir_recursive_absolute(game_dir)
	for f in ["FPS-CAD.exe", "TKernel.dll"]:
		var old := FileAccess.open(game_dir.path_join(f), FileAccess.WRITE)
		old.store_string("old " + f)
		old.close()
	var zip_file := OS.get_user_data_dir().path_join("smoke-update.zip")
	var zp := ZIPPacker.new()
	zp.open(zip_file)
	for f in ["FPS-CAD.exe", "TKernel.dll", "libfpcad.dll"]:
		zp.start_file("FPS-CAD-windows-abc1234/" + f)
		zp.write_file(("new " + f).to_utf8_buffer())
		zp.close_file()
	zp.close()
	_check(up.unpack_over(zip_file, game_dir, "old-11") == "", "a Windows update unpacks over the game folder")
	_check(FileAccess.get_file_as_string(game_dir.path_join("FPS-CAD.exe")) == "new FPS-CAD.exe"
		and FileAccess.get_file_as_string(game_dir.path_join("libfpcad.dll")) == "new libfpcad.dll", "the new build's files replace the old ones, top folder dropped")
	_check(FileAccess.get_file_as_string(game_dir.path_join("TKernel.dll.old-11")) == "old TKernel.dll", "the replaced files are set aside, not overwritten")
	up.remove_replaced(game_dir)
	_check(not FileAccess.file_exists(game_dir.path_join("FPS-CAD.exe.old-11")) and FileAccess.file_exists(game_dir.path_join("FPS-CAD.exe")), "set-aside files are cleaned up on the next launch")
	for f in DirAccess.get_files_at(game_dir):
		DirAccess.remove_absolute(game_dir.path_join(f))
	DirAccess.remove_absolute(game_dir)
	DirAccess.remove_absolute(zip_file)
	var apk_path := "user://smoke-update.apk"
	var fa := FileAccess.open(apk_path, FileAccess.WRITE)
	var blob := PackedByteArray()
	blob.resize(4096)
	blob.fill(7)
	fa.store_buffer(blob)
	fa.close()
	var sha: String = FileAccess.get_sha256(apk_path)
	_check(up.verify(apk_path, {size = 4096, sha256 = sha}) == "", "a downloaded update that matches its checksum is accepted")
	_check(up.verify(apk_path, {size = 4096, sha256 = "00" + sha.substr(2)}) != "", "a damaged download is refused")
	_check(up.verify(apk_path, {size = 9999, sha256 = sha}) != "", "a short download is refused")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(apk_path))

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
	# The challenge list scrolls: focus follows down the list and drags on its buttons scroll it.
	var win_size: Vector2i = main.get_window().size
	main.get_window().size = Vector2i(900, 400)  # a phone in landscape: the list overflows
	main._show_levels()
	await _frames(3)
	var lscroll: ScrollContainer = main.title._levels_scroll
	var lbuttons: Array = main.title._levels.get_children().filter(func(c): return c is Button)
	_check(lscroll.follow_focus and lbuttons.size() == 11 and lbuttons.all(func(b): return b.mouse_filter == Control.MOUSE_FILTER_PASS),
		"the challenge list follows focus and passes drags to its scroll")
	var bar := lscroll.get_v_scroll_bar()
	_check(bar.max_value > bar.page + 1.0, "on a short screen the list is longer than its view (%.0f > %.0f)" % [bar.max_value, bar.page])
	(lbuttons[-1] as Button).grab_focus()
	await _frames(3)
	_check(lscroll.scroll_vertical > 0, "focusing the last entry scrolls it into view (%d)" % lscroll.scroll_vertical)
	main.get_window().size = win_size
	main.title.show_menu()
	main.title.focus_default()

	await _frames(3)
	await _pad(JOY_BUTTON_A)
	await _frames(5)
	_check(main.state == "play" and main.mode == "training" and main.tutorial != null,
		"A on the focused title entry starts Training")
	_check(main.tutorial.step == 0, "training opens on its first objective")
	await _frames(2)
	var lines: Array = main.board.text_lines()
	_check(main.board.active and main.board.visible and String(lines[1]) == main.tutorial.steps[0].title and not main.tutorial._card.visible,
		"the objective is written on the whiteboard, not over the view (%s)" % lines[1])
	var to_board: Vector3 = main.board.global_position - main.player.feet
	_check(to_board.length() < 5.0 and Vector3(-sin(main.player.yaw), 0, -cos(main.player.yaw)).dot(to_board.normalized()) > 0.5,
		"the board stands ahead of the player")
	main.hud.toast("A notice for the board")
	await _frames(2)
	_check("A notice for the board" in main.board.text_lines() and not main.hud._readout_box.visible,
		"notices and the readout go on the board")
	var wall: Dictionary = main._cast(main.player.eye_position(), (main.board.global_position + Vector3(0, 1.0, 0) - main.player.eye_position()).normalized(), 20.0)
	_check(not wall.is_empty() and wall.get("env", false), "the board is solid: walking and aiming stop at it")
	main.player.yaw += PI  # look away: the board cannot be read, so notices show on screen again
	await _frames(3)
	main.hud.toast("Seen on screen")
	_check(not main.board.readable() and main.hud._toast.text == "Seen on screen" and main.hud._toast_t > 0.0,
		"with the board out of view, a notice shows on screen")
	main.player.yaw -= PI
	await _frames(2)

	for i in 3:  # look around, a bit at a time like a real stick
		main.player.yaw += 1.5
		await _frames(2)
	await _seconds(1.6)
	_check(main.tutorial.step == 1, "looking around completes objective 1")
	main.player.feet = Vector3(0, 0.05, 9)  # stand on the walk marker
	await _seconds(1.6)
	_check(main.tutorial.step == 2, "reaching the marker completes objective 2")

	# Growing while walking stops where the body would enter a part: inside the 30 cm crawl
	# tunnel the player cannot grow taller than the tunnel. Flying lifts the limit.
	main.player.size = 0.1
	main.player.target_size = 0.1
	main.player.feet = Vector3(0, 0, 0)
	await _frames(2)
	main.player.set_size(1.0)
	await _seconds(0.8)
	var grown: float = main.player.size * main.player.TALL
	_check(grown < 0.3 and grown > 0.2, "growing inside the tunnel stops under its 30 cm ceiling (%.0f mm tall)" % (grown * 1000.0))
	main.player.feet = Vector3(0, 0.05, 9)
	await _frames(2)
	main.player.set_size(1.0)
	await _seconds(0.8)
	_check(main.player.size > 0.95, "in the open the player grows back to full size")

	# Nobody falls through the floor: not from a long fall, nor after flying down into it.
	main.player.feet = Vector3(30, 60, 30)
	await _seconds(3.0)
	_check(absf(main.player.feet.y) < 0.01, "a 60 m fall lands on the floor (%.2f)" % main.player.feet.y)
	main.player.fly = true
	main.player.feet = Vector3(30, -5, 30)
	await _frames(3)
	_check(main.player.feet.y >= -1e-6, "flying cannot go below the floor")
	main.player.fly = false
	await _seconds(0.5)
	_check(absf(main.player.feet.y) < 0.01, "turning fly off stands the player on the floor")
	main.player.feet = Vector3(0, 0.05, 9)
	await _frames(2)

	# The room: training has no table; the course stands on the room floor.
	var env = main.view.room
	_check(not env.has_table, "training has no table")
	var down: Dictionary = env.cast(Vector3(40, 3, 0), Vector3.DOWN, 100.0)
	_check(not down.is_empty() and absf(down.point.y) < 1e-6, "the room floor is the CAD ground in training")
	main.player.feet = Vector3(0, 0.05, 9)
	await _frames(2)

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

	main._open_wheel(true)
	await _frames(2)
	var screen: Vector2 = root.get_viewport().get_visible_rect().size
	var wheel_ok: bool = main.wheel.size.is_equal_approx(screen)
	var mean := Vector2.ZERO
	for b in main.wheel._slots:
		mean += b.position + b.size / 2.0
	mean /= maxi(1, main.wheel._slots.size())
	_check(wheel_ok and mean.distance_to(screen / 2.0) < 2.0,
		"the tool wheel fills the screen and is centred (%s, slots around %s)" % [main.wheel.size, mean])
	_check(main.touch.size.is_equal_approx(screen), "touch controls cover the screen")
	# Groups: aiming at Solids shows its branch, committing opens it, then a tool is picked.
	var solids := -1
	for i in main.wheel.tree.size():
		if main.wheel.tree[i].name == "Solids":
			solids = i
	main.wheel._set_hover(solids)
	_check(solids >= 0 and main.wheel._kids.size() == 4, "aiming at Solids shows its four tools branching out")
	_check(main.wheel.commit() == load("res://scripts/tool_wheel.gd").ENTERED and main.wheel.visible and main.wheel.group == solids,
		"choosing a group opens its branch and keeps the wheel open")
	main.wheel.aim(Vector2.from_angle(main.wheel._kid_angle(solids, 1)))
	var picked_value: int = main.wheel.commit()
	main._wheel_pick(picked_value)
	_check(not main.wheel.visible and main.tools.tool().id == "revolve", "aiming along the branch and choosing picks Revolve")
	# Controller: right stick on the group, left stick on its tool, let go to pick.
	main._open_wheel(false)
	main.wheel.aim(Vector2.from_angle(main.wheel._slot_angle(solids)))
	main.wheel.aim_branch(Vector2.from_angle(main.wheel._kid_angle(solids, 2)))
	main._wheel_pick(main.wheel.commit())
	_check(not main.wheel.visible and main.tools.tool().id == "sweep", "right stick picks Solids, left stick picks Sweep, letting go takes it")
	main._open_wheel(false)
	main.wheel.aim(Vector2.from_angle(main.wheel._slot_angle(solids)))
	main._wheel_pick(main.wheel.commit(true))
	_check(not main.wheel.visible and main.tools.tool().id == "sweep",
		"letting go with only a group picked closes the wheel and keeps the tool")
	# Mouse, holding Q: move toward Solids, then further out toward Loft, let go: Loft.
	main._open_wheel(false)
	main.wheel.point(Vector2.from_angle(main.wheel._slot_angle(solids)) * 100.0)
	_check(main.wheel.hover == solids and main.wheel.branch == -1, "the mouse points at a group")
	var out_to: Vector2 = Vector2.from_angle(main.wheel._kid_angle(solids, 3)) * 200.0
	main.wheel.point(out_to - main.wheel._vec)
	main._wheel_pick(main.wheel.commit(true))
	_check(not main.wheel.visible and main.tools.tool().id == "loft", "moving the mouse further out picks a tool on the group's branch")
	# A captured-mouse motion reaches the wheel before the wheel's own layer can swallow it.
	main._open_wheel(false)
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2.from_angle(main.wheel._slot_angle(solids)) * 100.0
	var was_mode := Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:  # headless may not capture
		main._input(mm)
		_check(main.wheel.hover == solids, "mouse motion while holding Q steers the wheel")
	Input.mouse_mode = was_mode
	main.wheel.close()
	main._open_wheel(true)
	main.wheel.enter(solids)
	main.wheel.back()
	_check(main.wheel.visible and main.wheel.group == -1, "back steps from a branch to the groups")
	main.wheel.back()
	_check(not main.wheel.visible, "back at the groups closes the wheel")
	main.tools.set_tool(0)

	# Touch joysticks: the move stick walks and sprints when pushed past its ring; the look stick
	# turns like a controller stick; both spring back when let go.
	var tc = main.touch
	var acts: Node = root.get_node("Actions")
	acts.last_device = "touch"
	acts.device_changed.emit("touch")
	tc._layout()
	# A phone sends a pretend mouse click with every touch; it must not hide the touch controls.
	var fake := InputEventMouseButton.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	fake.button_index = MOUSE_BUTTON_LEFT
	fake.pressed = true
	Input.parse_input_event(fake)
	await _frames(2)
	_check(acts.last_device == "touch" and tc.visible, "touches stay touches (emulated mouse clicks are ignored)")
	var mh: Vector2 = tc._stick_home
	_touch(tc, 7, mh, true)
	_drag(tc, 7, mh + Vector2(70, 0))
	_check(main.player.move_from_touch.x > 0.95 and not main.player.touch_sprint, "the move stick walks")
	_drag(tc, 7, mh + Vector2(110, 0))
	_check(main.player.touch_sprint, "pushing the move stick past its ring sprints")
	_touch(tc, 7, mh + Vector2(110, 0), false)
	_check(main.player.move_from_touch == Vector2.ZERO and not main.player.touch_sprint, "letting go of the move stick stops")
	var lh: Vector2 = tc._look_home
	_touch(tc, 8, lh, true)
	_drag(tc, 8, lh + Vector2(0, -80))
	_check(main.player.look_stick_touch.y < -0.95, "the look stick looks up")
	_touch(tc, 8, lh + Vector2(0, -80), false)
	_check(main.player.look_stick_touch == Vector2.ZERO and tc._look_knob.position == lh - tc._look_knob.size / 2.0,
		"letting go of the look stick recentres it")
	acts.last_device = "controller"
	acts.device_changed.emit("controller")

	# A phone-sized interface: larger text, and the pause menu switches to two columns to fit.
	var ui = load("res://scripts/ui_theme.gd")
	ui.apply_scale(self, 1.75)
	await _frames(2)
	main.hud.set_menu_items(main._menu_items())
	main.hud.set_menu(true)
	await _frames(2)
	var tall: float = main.hud.menu_control().size.y
	var room: float = root.get_viewport().get_visible_rect().size.y
	_check(root.content_scale_factor == 1.75 and tall <= room,
		"at 175%% the pause menu fits the screen (%.0f of %.0f)" % [tall, room])
	main.hud.set_menu(false)
	ui.apply_scale(self, 1.0)
	await _frames(2)

	# ---- the CAD workflow in the game: plane → sketch → dimension → finish → extrude ----
	main._start_mode("new")
	await _frames(3)
	_check(main.mode == "new" and main.doc.get_features().is_empty() and main.tools.tool().id == "sketch",
		"New part opens blank with the Sketch tool")
	var top: Dictionary = main.doc.standard_plane("top")
	main._on_sketch_requested(top.plane, top.name, "")
	await _frames(2)
	_check(main.sketcher.active and main.hud.menu_open == false, "sketch mode opens on the Top plane")
	await _seconds(0.6)  # let the camera swing into the sketch view
	var cam: Basis = main.player.camera.global_transform.basis
	_check(main.player.view_lock and cam.x.is_equal_approx(Vector3(1, 0, 0)) and cam.y.is_equal_approx(Vector3(0, 0, -1))
		and (-cam.z).is_equal_approx(Vector3(0, -1, 0)),
		"the Top-plane sketch view looks straight down with sketch X right and Y up (%s)" % cam)
	var view_y: float = main.player.camera.global_position.y
	main.player.set_size(main.player.target_size * 0.5)
	await _seconds(0.6)
	_check(main.player.camera.global_position.y < view_y * 0.75 and main.player.view_lock, "shrinking zooms the sketch view in")
	main.player.set_size(1.0)
	await _seconds(0.6)
	main.sketcher.set_tool_id("rect")
	main.sketcher.click_at(Vector2(0, 0))
	main.sketcher.click_at(Vector2(1, 0.5))
	_check(main.sketcher.count("line") == 4 and main.sketcher.status.ok and main.sketcher.status.dof == 2,
		"a rectangle from the origin leaves width and height free (%s)" % main.sketcher.status.get("message", ""))
	main.sketcher.set_dimension("2000", "distance", ["l1"])
	main.sketcher.ask_dimension("distance", ["l2"], 0.5)
	await _frames(2)
	_check(main.numpad.visible, "the number pad opens for a dimension")
	for k in ["2", "5", "0", "OK"]:
		main.numpad._key(k)
	await _frames(2)
	_check(not main.numpad.visible and main.sketcher.defined(), "two dimensions fully define the rectangle")
	_check(main.sketcher._fill.mesh != null, "the closed rectangle is shaded")
	# Construction geometry: dashed, flips back and forth, never closes a profile.
	main.sketcher.set_tool_id("line")
	main.sketcher.cycle_option()
	_check(main.sketcher.construction_mode, "LB with a drawing tool turns construction on")
	main.sketcher.click_at(Vector2(-0.5, 0.75))
	main.sketcher.click_at(Vector2(-0.5, 1.25))
	main.sketcher.press(false)
	var last_line: Dictionary = main.sketcher.sketch.entities[-1]
	_check(last_line.get("construction", false), "a line drawn in construction mode is construction")
	main.sketcher.cycle_option()
	main.sketcher.set_tool_id("construct")
	main.sketcher.click_at(Vector2(-0.5, 1.0))
	_check(not main.sketcher.sketch.entities[-1].get("construction", false), "the Construction tool turns it back into normal geometry")
	main.sketcher.click_at(Vector2(-0.5, 1.0))
	_check(main.sketcher.sketch.entities[-1].get("construction", false), "and back to construction")
	var shaded: PackedVector2Array = main.doc.sketch_fill(main.sketcher.sketch)
	_check(shaded.size() >= 6, "the rectangle is still the only shaded profile")
	_check(not main.sketcher.set_dimension("1000", "distance", ["l3"]), "a conflicting dimension is refused")
	await _pad(JOY_BUTTON_X)
	await _frames(3)
	var feats: Array = main.doc.get_features()
	_check(not main.sketcher.active and feats.size() == 1 and feats[0].type == "sketch", "X finishes the sketch into the history")
	_check(not main.player.view_lock and main.player.feet.distance_to(Vector3(0, 0, 4)) < 0.5,
		"finishing the sketch returns the player to where they stood")
	_check(main.tools.tool().id == "extrude", "finishing a sketch readies Extrude")
	var sid: String = feats[0].id
	main._on_feature_requested("extrude", sid, "add")
	await _frames(2)
	_check(main.dialog.visible and main.doc.body_count() == 1, "the extrude panel opens with a live preview")
	main.dialog.set_value("depth", 0.25)
	main.dialog.focus = 0
	await _pad(JOY_BUTTON_DPAD_RIGHT)
	await _frames(2)
	_check(absf(float(main.dialog.values.depth) - 0.5) < 1e-9, "D-pad right adds a snap step to the depth")
	await _pad(JOY_BUTTON_A)
	await _frames(3)
	_check(not main.dialog.visible and absf(main.doc.mass_properties().volume - 0.25) < 1e-6,
		"A accepts: 2 m × 250 mm × 500 mm extrude (%.4f m³)" % main.doc.mass_properties().volume)

	main._on_sketch_requested({}, "", sid)
	await _frames(2)
	_check(main.sketcher.active and main.sketcher.edit_id == sid, "a finished sketch opens again for editing")
	main.sketcher.set_dimension("3000", "distance", ["l1"])
	main.sketcher.finish()
	await _frames(2)
	_check(absf(main.doc.mass_properties().volume - 0.375) < 1e-6, "editing the sketch drives the extrude")

	main._start_mode("new")
	await _frames(2)
	var front: Dictionary = main.doc.standard_plane("front")
	main._on_sketch_requested(front.plane, front.name, "")
	await _seconds(0.6)
	cam = main.player.camera.global_transform.basis
	_check(cam.x.is_equal_approx(Vector3(1, 0, 0)) and cam.y.is_equal_approx(Vector3(0, 1, 0)) and (-cam.z).is_equal_approx(Vector3(0, 0, -1)),
		"the Front-plane sketch view faces the plane square-on (%s)" % cam)
	main.sketcher.toggle_view()
	await _frames(2)
	_check(not main.player.view_lock and main.player.fly, "Y switches the sketch view to free look")
	main.sketcher.toggle_view()
	await _frames(2)
	_check(main.player.view_lock, "Y returns to the sketch view")
	main.player.set_size_now(1.0)  # the view zooms to the distance the player stood at: fix the snap step
	main.sketcher.set_tool_id("rect")
	main.sketcher.click_at(Vector2(0.5, 0))
	main.sketcher.click_at(Vector2(1, 1))
	main.sketcher.finish()
	var rid: String = main.doc.latest_unused_sketch()
	main._on_feature_requested("revolve", rid, "add")
	await _frames(2)
	main.dialog.accept()
	await _frames(2)
	_check(absf(main.doc.mass_properties().volume - PI * 0.75) < 1e-4,
		"a revolve about the sketch's Y axis makes a tube (%.4f m³)" % main.doc.mass_properties().volume)
	# Push/pull on a face nothing drives (the tube's round outside) adds stock as its own feature.
	var tube_side: Dictionary = main.doc.pick(Vector3(5, 0.5, 0), Vector3(-1, 0, 0), 20.0)
	_check(not tube_side.is_empty() and not tube_side.has("drive_label"), "the tube's outside has no driving dimension")
	var pp: Dictionary = main.doc.push_pull(tube_side, 0.05)
	var feats_now: Array = main.doc.get_features()
	_check(pp.ok and feats_now[-1].type == "face_offset" and absf(main.doc.mass_properties().volume - PI * (1.05 * 1.05 - 0.25)) < 1e-3,
		"push/pull adds stock round it (%s, %.4f m³)" % [pp.get("message", ""), main.doc.mass_properties().volume])
	var pp2: Dictionary = main.doc.push_pull(tube_side, -0.1)
	_check(pp2.ok and main.doc.get_features().size() == feats_now.size() and absf(main.doc.mass_properties().volume - PI * (0.95 * 0.95 - 0.25)) < 1e-3,
		"and pulling the same spot back past the surface removes stock (%.4f m³)" % main.doc.mass_properties().volume)

	await _sketch_tools(main)
	await _player_body(main)
	await _references(main)

	# ---- challenge mode: copy the target, any orientation, any method ----
	var list: Array = ClassDB.instantiate(&"CadPart").challenge_list()
	_check(list.size() == 10 and list[0].name == "Block", "ten challenges, starting with the block")
	main._start_mode("challenge", 0)
	await _frames(3)
	_check(main.challenge != null and main.challenge.target != null and main.challenge.offset.x < 0.0,
		"challenge 1 shows its target beside the build area")
	var table: Rect2 = main.view.room.top
	_check(table.size.is_equal_approx(Vector2(1.22, 0.61)), "the table is 4 ft by 2 ft (%s)" % table.size)
	var bp: Vector3 = main.board.global_position
	_check(main.board.active and bp.x < table.position.x - 0.3 and absf(bp.y - main.view.room.floor_y()) < 1e-6
		and String(main.board.text_lines()[1]) == main.challenge.info.name,
		"the whiteboard stands on the floor beside the table with the challenge on it")
	_check(main.view.room.has_table, "challenges use the wooden table")
	_check(main.player.feet.y < -0.7 and main.player.feet.z > table.end.y and main.player.size == 1.0,
		"the player starts on the floor, walking up to the table")
	var c: Color = main.challenge.colour
	_check(c.a == 1.0 and c.s > 0.2 and c.s < 0.45 and c.v > 0.85, "the target is an opaque pastel (%s)" % c)
	var wrong: String = main.doc.add_primitive("box", Vector3(0.3, 0, 0.2), {w = 0.1, d = 0.075, h = 0.045}, "add")
	main._on_model_changed()
	await _frames(2)
	_check(wrong != "" and not main.challenge.solved and String(main.challenge.last.get("message", "")).contains("90%"),
		"a block 5 mm short does not pass, and the hint says 90%% (%s)" % main.challenge.last.get("message", ""))
	main.doc.delete_feature(wrong)
	var right: String = main.doc.add_primitive("box", Vector3(0.3, 0, 0.2), {w = 0.075, d = 0.05, h = 0.1}, "add")
	main._on_model_changed()
	await _frames(3)
	_check(right != "" and main.challenge.solved and main.challenge.is_open_card(),
		"the same block stood on end and moved elsewhere passes")
	_check(load("res://scripts/challenge.gd").unlocked() >= 2, "passing unlocks the next challenge")
	await _pad(JOY_BUTTON_A)
	await _frames(4)
	_check(main.mode == "challenge" and main.level == 1 and main.challenge != null and main.challenge.info.id == "puck",
		"A on Next challenge opens challenge 2")

	# Free build: the desk organiser on the table, walking up to it from the floor.
	main._start_mode("free")
	await _frames(3)
	_check(main.view.room.has_table and main.doc.get_part_name() == "Desk organiser" and main.doc.body_count() == 1,
		"free build puts the desk organiser on the table")
	_check(main.player.feet.y < -0.7 and main.player.feet.z > main.view.room.top.end.y, "free build starts on the floor in front of the table")
	main._start_mode("new")
	await _frames(2)
	_check(not main.view.room.has_table and absf(main.view.room.floor_y()) < 1e-9, "a new part has no table")

	main.queue_free()
	await process_frame

	print("%d failures" % _failures)
	quit(1 if _failures > 0 else 0)


## Clears the open sketch, for the next tool check.
func _blank(sk: Node) -> void:
	sk.cancel_pending()
	sk.sketch.points = []
	sk.sketch.entities = []
	sk.sketch.constraints = []
	sk.sketch.erase("patterns")
	sk.sketch.erase("links")
	sk.construction_mode = false
	sk.status = {ok = true, dof = 0, message = ""}
	sk._index()


## Id of the sketch point at uv, or "".
func _pid(sk: Node, uv: Vector2) -> String:
	for id in sk._pts:
		if (sk._pts[id] as Vector2).distance_to(uv) < 1e-6:
			return id
	return ""


func _clicks(sk: Node, tool_id: String, spots: Array) -> void:
	sk.set_tool_id(tool_id)
	for uv in spots:
		sk.click_at(uv)


func _ids(sk: Node, kind: String) -> Array:
	var out := []
	for e in sk.sketch.entities:
		if e.kind == kind:
			out.append(e.id)
	return out


func _has_constraint(sk: Node, kind: String) -> bool:
	for c in sk.sketch.constraints:
		if c.kind == kind:
			return true
	return false


## Every drawing, editing and constraining tool in the sketcher, on a blank part's Top plane.
func _sketch_tools(main: Node) -> void:
	main._start_mode("new")
	await _frames(2)
	var top: Dictionary = main.doc.standard_plane("top")
	main._on_sketch_requested(top.plane, top.name, "")
	await _frames(2)
	main.player.set_size_now(1.0)
	var sk: Node = main.sketcher
	var tree: Array = sk.wheel_tree()
	_check(tree.size() == 8 and tree[0].name == "Lines" and tree[0].children.size() == 7 and tree[1].children.size() == 7 and tree[2].children.size() == 7,
		"the sketch wheel groups Lines, Curves, Modify, Copy, Constrain, Text, Construction and Delete")

	# Points, and centre / 3-point rectangles.
	_clicks(sk, "point", [Vector2(2, 2)])
	_check(sk.sketch.points.size() == 1 and sk.sketch.entities.is_empty() and sk.status.ok and sk.status.dof == 2,
		"Point places a stand-alone point with two degrees of freedom")
	_clicks(sk, "erase", [Vector2(2, 2)])
	_check(sk.sketch.points.is_empty(), "Delete removes a stand-alone point")
	_clicks(sk, "rect_centre", [Vector2(0, 0), Vector2(0.5, 0.3)])
	_check(_ids(sk, "line").size() == 6 and sk.count("line") == 6 and sk.status.ok and sk.status.dof == 2 and _has_constraint(sk, "midpoint"),
		"a centre rectangle on the origin has construction diagonals and only width and height free (%s)" % sk.status.message)
	_blank(sk)
	_clicks(sk, "rect_3pt", [Vector2(0, 0), Vector2(1, 1), Vector2(0, 2)])
	var p3: String = _pid(sk, Vector2(0, 2))
	_check(sk.count("line") == 4 and sk.status.ok and sk.status.dof == 3 and p3 != "",
		"a 3-point rectangle at an angle keeps square corners (angle, length and width free: %s)" % sk.status.message)
	_blank(sk)

	# Polygon and slot.
	_clicks(sk, "polygon", [Vector2(0, 0), Vector2(1, 0)])
	_check(sk.count("line") == 6 and sk.count("circle") == 1 and sk.status.ok and sk.status.dof == 2 and sk._fill.mesh != null,
		"a hexagon on the origin is closed and leaves size and turn free (%s)" % sk.status.message)
	sk.set_tool_id("polygon")
	sk.press(false)
	_check(sk.polygon_sides == 8, "the alternate button changes the number of sides")
	_blank(sk)
	_clicks(sk, "slot", [Vector2(0, 0), Vector2(1, 0), Vector2(0.5, 0.25)])
	var area := 0.0
	var tris: PackedVector2Array = main.doc.sketch_fill(sk.sketch)
	for i in range(0, tris.size() - 2, 3):
		area += absf((tris[i + 1] - tris[i]).cross(tris[i + 2] - tris[i])) / 2.0
	_check(sk.count("arc") == 2 and sk.count("line") == 3 and sk.status.ok and sk.status.dof == 2 and absf(area - (0.5 + PI * 0.0625)) < 2e-3,
		"a slot is two tangent arcs and two lines, closed (area %.4f, %s)" % [area, sk.status.message])
	_blank(sk)

	# Circles and arcs through points, tangent arcs, ellipses, splines.
	_clicks(sk, "circle_3pt", [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)])
	_check(sk.count("circle") == 1 and absf(float(sk.sketch.entities[0].r) - 1.0) < 1e-6, "a 3-point circle passes through all three")
	_blank(sk)
	_clicks(sk, "arc_3pt", [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1)])
	var arc3: Dictionary = sk.sketch.entities[0] if sk.count("arc") == 1 else {}
	_check(not arc3.is_empty() and sk._p(arc3.pts[1]).is_equal_approx(Vector2(1, 0)),
		"a 3-point arc runs from its start over the third point to its end")
	_blank(sk)
	_clicks(sk, "line", [Vector2(0, 0), Vector2(1, 0)])
	sk.press(false)
	_clicks(sk, "arc_tangent", [Vector2(1, 0), Vector2(1, 1)])
	var tarc := _ids(sk, "arc")
	_check(tarc.size() == 1 and _has_constraint(sk, "tangent") and sk.status.ok,
		"a tangent arc leaves the line's end smoothly (%s)" % sk.status.message)
	if tarc.size() == 1:
		var ta: Dictionary = sk._ents[tarc[0]]
		_check(sk._p(ta.pts[0]).distance_to(Vector2(1, 0.5)) < 1e-6, "and turns about the right centre")
	sk.press(false)
	_blank(sk)
	_clicks(sk, "ellipse", [Vector2(0, 0), Vector2(0.5, 0), Vector2(0, 0.25)])
	_check(sk.count("ellipse") == 1 and absf(float(sk.sketch.entities[0].r) - 0.25) < 1e-6 and sk._fill.mesh != null,
		"an ellipse from its centre and two axes is a closed profile")
	_blank(sk)
	_clicks(sk, "spline", [Vector2(0, 0), Vector2(1, 1), Vector2(2, 0)])
	sk.press(false)
	_check(sk.count("spline") == 1 and sk._curves.size() == 1 and (sk._curves.values()[0] as PackedVector2Array).size() > 10,
		"the alternate button finishes an open spline, drawn from the core's curve")
	_clicks(sk, "spline", [Vector2(5, 0), Vector2(6, 1), Vector2(7, 0), Vector2(6, -1), Vector2(5, 0)])
	_check(sk.count("spline") == 2 and sk._fill.mesh != null, "clicking the first point again closes a spline into a profile")
	_blank(sk)

	# Trim and extend.
	_clicks(sk, "line", [Vector2(2, -1), Vector2(2, 1)])
	sk.press(false)
	_clicks(sk, "line", [Vector2(1, 0), Vector2(3, 0)])
	sk.press(false)
	_clicks(sk, "trim", [Vector2(2, 0.5)])
	var v_top := _pid(sk, Vector2(2, 1))
	var cut := _pid(sk, Vector2(2, 0))
	_check(sk.count("line") == 2 and v_top == "" and cut != "" and _has_constraint(sk, "point_on_line") and sk.status.ok,
		"Trim cuts a line back to where it crosses another (%s)" % sk.status.message)
	_clicks(sk, "trim", [Vector2(2.5, 0)])
	_check(sk.count("line") == 2 and _pid(sk, Vector2(3, 0)) == "" and sk.status.ok, "and the other back to that corner")
	_blank(sk)
	_clicks(sk, "circle", [Vector2(5, 0), Vector2(6, 0)])
	_clicks(sk, "line", [Vector2(5, -2), Vector2(5, 2)])
	sk.press(false)
	_clicks(sk, "trim", [Vector2(6, 0)])
	var half: Array = _ids(sk, "arc")
	_check(sk.count("circle") == 0 and half.size() == 1 and sk.status.ok, "Trim turns a circle into the arc that is left")
	if half.size() == 1:
		_check(absf(sk._p(sk._ents[half[0]].pts[1]).y - 1.0) < 1e-6, "keeping the half away from the crosshair")
	_blank(sk)
	_clicks(sk, "line", [Vector2(0, 3), Vector2(1, 3)])
	sk.press(false)
	_clicks(sk, "line", [Vector2(2, 2.5), Vector2(2, 3.5)])
	sk.press(false)
	_clicks(sk, "extend", [Vector2(0.9, 3)])
	_check(_pid(sk, Vector2(2, 3)) != "" and _pid(sk, Vector2(1, 3)) == "" and sk.status.ok, "Extend runs a line on to the next geometry")
	_blank(sk)

	# Fillet and chamfer corners.
	_clicks(sk, "rect", [Vector2(10, 10), Vector2(11, 11)])
	var dof_before: int = int(sk.status.dof)
	_check(sk.fillet_corner(_pid(sk, Vector2(11, 10)), 0.2), "Fillet rounds a rectangle's corner")
	_check(sk.count("arc") == 1 and sk.count("line") == 4 and int(sk.status.dof) == dof_before and _pid(sk, Vector2(11, 10)) == "",
		"with tangent ends and a radius dimension, adding no freedom (%s)" % sk.status.message)
	_check(sk.chamfer_corner(_pid(sk, Vector2(10, 11)), 0.1) and sk.count("line") == 5 and _pid(sk, Vector2(10, 11)) != "",
		"Chamfer bevels a corner, keeping the sharp corner as a reference point")
	_blank(sk)

	# Offset, mirror, move and copy, patterns.
	_clicks(sk, "rect", [Vector2(20, 0), Vector2(21, 1)])
	var edge: String = _ids(sk, "line")[0]
	_check(sk.offset_chain(edge, Vector2(20.5, 0.5), 0.1) and sk.count("line") == 8 and _pid(sk, Vector2(20.1, 0.1)) != "" and _pid(sk, Vector2(20.9, 0.9)) != "",
		"Offset copies the whole rectangle 0.1 m inside (%s)" % sk.status.message)
	_blank(sk)
	sk.construction_mode = true
	_clicks(sk, "line", [Vector2(30, -1), Vector2(30, 1)])
	sk.press(false)
	sk.construction_mode = false
	var axis: String = _ids(sk, "line")[0]
	_clicks(sk, "line", [Vector2(31, 0), Vector2(32, 0.5)])
	sk.press(false)
	var src: String = _ids(sk, "line")[1]
	_check(sk.mirror_chain(src, axis) and _pid(sk, Vector2(29, 0)) != "" and _pid(sk, Vector2(28, 0.5)) != "" and _has_constraint(sk, "symmetric"),
		"Mirror copies geometry across a centreline, held symmetric")
	_blank(sk)
	_clicks(sk, "line", [Vector2(40, 0), Vector2(41, 0)])
	sk.press(false)
	var mv: String = _ids(sk, "line")[0]
	_check(sk.move_geometry("entity", mv, Vector2(0, 1), false) and _pid(sk, Vector2(40, 1)) != "" and _pid(sk, Vector2(40, 0)) == "",
		"Move slides a line")
	_check(sk.move_geometry("entity", mv, Vector2(0, 1), true) and sk.count("line") == 2 and _pid(sk, Vector2(41, 2)) != "",
		"and Copy leaves the original where it was")
	_blank(sk)
	_clicks(sk, "line", [Vector2(40, 0), Vector2(41, 0.5)])
	sk.press(false)
	var rl: String = _ids(sk, "line")[0]
	_check(sk.rotate_geometry(rl, Vector2(40, 0), PI / 2.0) and _pid(sk, Vector2(39.5, 1)) != "", "Rotate turns geometry about a centre")
	_check(sk.scale_geometry(rl, Vector2(40, 0), 2.0) and _pid(sk, Vector2(39, 2)) != "", "and Scale grows it about one")
	_blank(sk)
	# Snap inference: a line started at another's midpoint, ended on a third line.
	_clicks(sk, "line", [Vector2(0, 0), Vector2(2, 0)])
	sk.press(false)
	_clicks(sk, "line", [Vector2(3, -1), Vector2(3, 1)])
	sk.press(false)
	_clicks(sk, "line", [Vector2(1, 0), Vector2(3, 0.5)])
	sk.press(false)
	_check(_has_constraint(sk, "midpoint") and _has_constraint(sk, "point_on_line") and sk.status.ok,
		"points placed on a line's middle, or on a line, stay there")
	_blank(sk)
	_clicks(sk, "circle", [Vector2(50, 0), Vector2(50.1, 0)])
	var ring: String = _ids(sk, "circle")[0]
	_check(sk.pattern_chain(ring, true, Vector2(51, 0), 4) and sk.count("circle") == 4 and _pid(sk, Vector2(52, 0)) != "",
		"a circular pattern of four spreads copies round the centre")
	_check(sk.pattern_chain(ring, false, Vector2(0, 0.5), 3) and sk.count("circle") == 6 and _pid(sk, Vector2(50, 1)) != "",
		"a linear pattern of three steps copies along")
	var lin: String = sk.sketch.patterns[1].id
	_check(sk.set_pattern(lin, 5, 0.25) and sk.count("circle") == 8 and _pid(sk, Vector2(50, 1)) != "" and _pid(sk, Vector2(50, 0.75)) != "",
		"a pattern's count and spacing can be changed later")
	_check(sk.move_geometry("entity", ring, Vector2(0, -1), false) and _pid(sk, Vector2(50, -0.75)) != "",
		"pattern copies follow their original when it moves")
	var copy_id := ""
	for e in sk.sketch.entities:
		if String(e.get("pattern", "")) == lin:
			copy_id = e.id
	sk.set_tool_id("erase")
	sk._hover = {kind = "entity", id = copy_id}
	sk._valid = true
	sk._erase(true)
	_check(sk.count("circle") == 4 and sk.sketch.patterns.size() == 1, "deleting a copy deletes its pattern")
	_blank(sk)

	# Split, live dragging, text, spline tangency.
	_clicks(sk, "line", [Vector2(0, 0), Vector2(2, 0)])
	sk.press(false)
	var long_line: String = _ids(sk, "line")[0]
	_check(sk.split_at(long_line, Vector2(0.5, 0)) and sk.count("line") == 2 and _has_constraint(sk, "collinear") and sk.status.ok,
		"Split cuts a line in two, kept in line")
	_blank(sk)
	_clicks(sk, "circle", [Vector2(0, 0), Vector2(1, 0)])
	_clicks(sk, "split", [Vector2(1, 0), Vector2(-1, 0)])
	_check(sk.count("arc") == 2 and sk.count("circle") == 0 and sk.status.ok, "a circle split in two places becomes two arcs")
	_blank(sk)
	_clicks(sk, "line", [Vector2(3, 0), Vector2(4, 0)])
	sk.press(false)
	sk.set_tool_id("move")
	sk.click_at(Vector2(3.5, 0))
	sk._cursor = Vector2(3.5, 1)
	sk._valid = true
	sk._update_drag()
	_check(not sk._drag.is_empty() and _pid(sk, Vector2(3, 0)) != "", "Move solves the geometry live at the cursor before placing it")
	sk.click_at(Vector2(3.5, 1))
	_check(_pid(sk, Vector2(3, 1)) != "" and sk._drag.is_empty(), "and the click places it there")
	_blank(sk)
	var typed := [""]
	main.numpad.ask_text("Text", "", "", func(t: String) -> void: typed[0] = t)
	for k in ["H", "aA", "I", "Space", "2", "OK"]:
		main.numpad._key(k)
	_check(typed[0] == "Hi 2" and not main.numpad.visible, "the on-screen letters type words (%s)" % typed[0])
	var contours: Array = sk.glyph_contours("Ab")
	_check(contours.size() >= 3, "text outlines come from the font (%d contours for Ab)" % contours.size())
	_check(sk.add_text({id = "", uv = Vector2(0, 0)}, "FPS") and sk.count("text") == 1 and sk._fill.mesh != null and sk.status.ok,
		"Text adds letters as closed profiles, with a height dimension (%s)" % sk.status.message)
	var tid: String = _ids(sk, "text")[0]
	_check(sk.set_dimension("1000", "distance", [tid]) and absf(float(sk._ents[tid].r) - 1.0) < 1e-9, "dimensioning text sets its height")
	_check(sk.set_text(tid, "CAD") and sk._ents[tid].text == "CAD", "and the words can be changed")
	_blank(sk)
	_clicks(sk, "line", [Vector2(0, 0), Vector2(1, 0)])
	sk.press(false)
	_clicks(sk, "spline", [Vector2(1, 0), Vector2(1.5, 0.75), Vector2(2, 0)])
	sk.press(false)
	sk.set_tool_id("relation")
	sk.set_option("relation", "tangent")
	sk.click_at(Vector2(1.5, 0.75))
	sk.click_at(Vector2(0.5, 0))
	var sc: PackedVector2Array = sk._curves.values()[0] if sk._curves.size() == 1 else PackedVector2Array()
	_check(_has_constraint(sk, "tangent") and sc.size() > 2 and absf(sc[1].y - sc[0].y) < 0.15 * absf(sc[1].x - sc[0].x),
		"a spline tangent to the line it starts on leaves along the line")
	_blank(sk)

	# New relations and dimensions, picked with the crosshair.
	_clicks(sk, "circle", [Vector2(0, 0), Vector2(1, 0)])
	_clicks(sk, "circle", [Vector2(0.25, 0.25), Vector2(0.5, 0.25)])
	sk.set_tool_id("relation")
	sk.set_option("relation", "concentric")
	sk.click_at(Vector2(1, 0))
	sk.click_at(Vector2(0.5, 0.25))
	var kc: Array = _ids(sk, "circle")
	_check(_has_constraint(sk, "concentric") and sk._p(sk._ents[kc[1]].pts[0]).length() < 1e-6, "Concentric pulls the second circle's centre onto the first")
	_blank(sk)
	_clicks(sk, "line", [Vector2(0, 0), Vector2(1, 0)])
	sk.press(false)
	_clicks(sk, "line", [Vector2(0, 0), Vector2(1, 1)])
	sk.press(false)
	sk.set_tool_id("dimension")
	sk.click_at(Vector2(0.5, 0))
	sk.click_at(Vector2(0.5, 0.5))
	await _frames(1)
	_check(main.numpad.visible, "two lines picked with Dimension ask for the angle")
	for k in ["3", "0", "OK"]:
		main.numpad._key(k)
	await _frames(1)
	var ang := 0.0
	for c in sk.sketch.constraints:
		if c.kind == "angle":
			ang = float(c.value)
	_check(absf(ang - deg_to_rad(30.0)) < 1e-9 and sk.status.ok, "an angle dimension of 30° turns the second line")
	sk.click_at(Vector2(0.5, 0))
	sk.click_at(Vector2(0.5, -0.5))
	await _frames(1)
	_check(main.numpad.visible, "a line, then empty space, asks for its length")
	main.numpad.close()
	_blank(sk)
	_clicks(sk, "point", [Vector2(0.5, 0.75)])
	_clicks(sk, "line", [Vector2(0, 0), Vector2(1, 0)])
	sk.press(false)
	sk.set_tool_id("dimension")
	sk.click_at(Vector2(0.5, 0.75))
	sk.click_at(Vector2(0.25, 0))
	await _frames(1)
	main.numpad.close()
	_check(sk.set_dimension("500", "distance", [_pid(sk, Vector2(0.5, 0.75)), _ids(sk, "line")[0]]) and sk.status.ok and _pid(sk, Vector2(0.5, 0.5)) != "",
		"a point-to-line distance holds the point square off the line")
	sk.discard()
	await _frames(2)

	# Convert edges: a box's top face copied onto a Top-plane sketch.
	main.doc.add_primitive("box", Vector3(0, 0, 0), {w = 0.4, d = 0.2, h = 0.1}, "add")
	main._on_model_changed()
	var hit: Dictionary = main.doc.pick(Vector3(0.05, 5, -0.02), Vector3(0, -1, 0), 20.0)
	main._on_sketch_requested(top.plane, top.name, "")
	await _frames(2)
	_check(not hit.is_empty() and sk.convert_face(int(hit.body), int(hit.face), hit.point) and sk.count("line") == 4 and sk.defined(),
		"Convert edges copies a face's outline in as fixed, fully defined lines")
	sk.finish()
	await _frames(2)
	var box_id := ""
	var conv_id := ""
	for f in main.doc.get_features():
		if f.type == "box":
			box_id = f.id
		elif f.type == "sketch":
			conv_id = f.id
	main.doc.set_param(box_id, "w", 0.6)
	var after: Dictionary = main.doc.get_sketch(conv_id)
	var wide := 0.0
	for p in after.points:
		wide = maxf(wide, float(p.x))
	_check(absf(wide - 0.3) < 1e-6, "converted edges follow the model when the box widens (%.3f)" % wide)


## The 6 ft player: full-height body, head stops at ceilings, sizes glide, and the sketch view
## opens at about the distance the player was from what they aimed at.
func _player_body(main: Node) -> void:
	main._start_mode("new")
	await _frames(2)
	var pl: Node3D = main.player
	_check(absf(pl.TALL - 1.83) < 0.01 and absf(pl.EYE - 1.70) < 0.01, "the player is about 6 ft tall at 1:1")
	# An overhang from 1.6 m to 2 m, in a blank part: too low to walk under at full height.
	main.doc.add_primitive("box", Vector3(0, 1.6, -3), {w = 2.0, d = 2.0, h = 0.4}, "add")
	main._on_model_changed()
	pl.set_size_now(1.0)
	pl.fly = false
	pl.feet = Vector3(0, 0, 0)
	await _frames(2)
	_check(pl._blocked(Vector3(0, 0, -1), 2.2), "an overhang at head height stops a 6 ft player walking under it")
	pl.set_size_now(0.8)
	_check(not pl._blocked(Vector3(0, 0, -1), 2.2), "a player shorter than the gap walks under it")
	pl.set_size_now(1.0)
	# Jumping under a ceiling 2.1 m up: the head stops at it.
	main.doc.add_primitive("box", Vector3(6, 2.1, 0), {w = 2.0, d = 2.0, h = 0.3}, "add")
	main._on_model_changed()
	pl.feet = Vector3(6, 0, 0)
	await _seconds(0.3)
	pl._on_ground = true
	pl._jump_queued = true
	var top_y := 0.0
	for i in 30:
		await _frames(1)
		top_y = maxf(top_y, pl.feet.y + pl.TALL * pl.size)
	_check(top_y <= 2.1 + 1e-3 and top_y > 2.0, "jumping under a 2.1 m ceiling stops the head at it (%.3f m)" % top_y)
	# Size glides: it starts gently and arrives without overshooting.
	pl.feet = Vector3(20, 0, 20)
	await _seconds(0.3)
	pl.set_size_now(1.0)
	pl.set_size(2.0)
	await _frames(1)
	var first: float = pl.size
	var peak := 0.0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1200:
		await _frames(1)
		peak = maxf(peak, pl.size)
	_check(first < 1.1 and peak <= 2.0 + 1e-6 and pl.size > 1.95, "growing glides there: %.3f after a frame, %.3f at the end" % [first, pl.size])
	pl.set_size_now(1.0)
	# Entering a sketch keeps the distance to the aimed spot: no zoom jump.
	pl.feet = Vector3(0, 0, 3)
	pl.yaw = 0.0
	pl.pitch = -atan2(pl.EYE, 3.0)  # aiming at the origin on the floor
	await _frames(2)
	var d: float = pl.eye_position().distance_to(Vector3.ZERO)
	var eye_before: Vector3 = pl.camera.global_position
	var top: Dictionary = main.doc.standard_plane("top")
	main._on_sketch_requested(top.plane, top.name, "")
	await _seconds(0.8)
	var cam_d: float = pl.camera.global_position.distance_to(Vector3.ZERO)
	_check(pl.view_lock and absf(cam_d - d) < 0.05 * d, "the sketch view opens about as far away as the player was (%.2f m, was %.2f m)" % [cam_d, d])
	main.sketcher.discard()
	await _seconds(0.8)
	_check(pl.camera.global_position.distance_to(eye_before) < 0.05 and absf(pl.size - 1.0) < 1e-6,
		"leaving the sketch glides back to where the player stood")


## Aims the player straight down at a spot (Godot space) from height above it.
func _look_down_at(main: Node, spot: Vector3, height: float) -> void:
	var pl: Node3D = main.player
	pl.fly = true
	pl.feet = spot + Vector3(0, height - pl.EYE * pl.size, 0)
	pl.yaw = 0.0
	pl.pitch = -PI / 2.0 + 0.001
	await _frames(3)


## Reference geometry from the tools: an offset plane with a sketch on it that follows the plane,
## an axis on an edge, a typed point, the bounding box and mass properties.
func _references(main: Node) -> void:
	main._start_mode("new")
	await _frames(2)
	main.player.set_size_now(1.0)
	main.doc.add_primitive("box", Vector3(0, 0, 0), {w = 1.0, d = 1.0, h = 0.5}, "add")
	main._on_model_changed()
	var tools: Node = main.tools
	var tree: Array = tools.wheel_tree()
	var groups: Array = tree.map(func(n): return n.name)
	_check("Reference" in groups and "Measure" in groups, "the tool wheel has Reference and Measure groups (%s)" % ", ".join(groups))
	# An offset plane 250 mm above the box's top face, through the feature panel.
	tools.set_tool_id("ref_plane")
	tools.aim = main.doc.pick(Vector3(0.2, 5, 0.2), Vector3(0, -1, 0), 20.0)
	tools._act(true, false)
	await _frames(2)
	_check(main.dialog.visible and main.dialog.type == "plane", "Plane (offset) on a face opens the panel with a live preview")
	main.dialog.set_value("distance", 0.25)
	main.dialog.accept()
	await _frames(2)
	var planes: Array = main.view.references.filter(func(v): return v.kind == "plane")
	_check(planes.size() == 1 and absf((planes[0].origin as Vector3).y - 0.75) < 1e-6, "the plane floats 250 mm above the box")
	var plane_id: String = planes[0].id if planes.size() == 1 else ""
	# Sketch on it, aiming down through it.
	await _look_down_at(main, Vector3(0.1, 0.75, 0.1), 3.0)
	tools.set_tool_id("sketch")
	tools.aim = main._aim_hit()
	tools._act(true, false)
	await _frames(2)
	_check(main.sketcher.active and String(main.sketcher.sketch.get("planeRef", "")) == plane_id, "the Sketch tool sketches on the reference plane")
	main.player.set_size_now(1.0)
	main.sketcher.set_tool_id("rect")
	main.sketcher.click_at(Vector2(0, 0))
	main.sketcher.click_at(Vector2(0.25, 0.25))
	main.sketcher.finish()
	await _frames(2)
	var sk_id: String = main.doc.latest_unused_sketch()
	var on_plane: Dictionary = main.doc.get_sketch(sk_id)
	_check(sk_id != "" and on_plane.get("planeRef", "") == plane_id and absf(float(on_plane.plane.origin[2]) - 0.75) < 1e-6,
		"the finished sketch remembers its plane")
	var plane_f: Dictionary = {}
	for f in main.doc.get_features():
		if f.id == plane_id:
			plane_f = f
	_check(main.dialog.open_edit(plane_f), "the plane can be edited from the model panel")
	main.dialog.set_value("distance", 0.5)
	main.dialog.accept()
	await _frames(2)
	_check(absf(float(main.doc.get_sketch(sk_id).plane.origin[2]) - 1.0) < 1e-6, "moving the plane moves the sketch on it")
	# An axis on the box's edge, then offered to Revolve.
	main.player.fly = false
	tools.set_tool_id("ref_axis")
	tools.aim = main.doc.pick(Vector3(0.49, 0.25, 5), Vector3(0, 0, -1), 20.0)
	tools._act(true, false)
	await _frames(2)
	var axes: Array = main.view.references.filter(func(v): return v.kind == "axis")
	_check(axes.size() == 1 and absf(absf((axes[0].xdir as Vector3).y) - 1.0) < 1e-6 and absf((axes[0].origin as Vector3).x - 0.5) < 1e-6,
		"Axis on the box's upright edge")
	# A point typed in X, Y, Z.
	tools.set_tool_id("ref_point")
	tools.options["ref_point"] = 2  # at the crosshair
	tools.aim = main.doc.pick(Vector3(0.2, 5, 0.2), Vector3(0, -1, 0), 20.0)
	tools._act(true, false)
	await _frames(2)
	_check(main.dialog.visible and main.dialog.type == "point", "Point at the crosshair opens X, Y and Z")
	main.dialog.set_value("z", 1.5)
	main.dialog.accept()
	await _frames(2)
	var pts: Array = main.view.references.filter(func(v): return v.kind == "point")
	_check(pts.size() == 1 and absf((pts[0].origin as Vector3).y - 1.5) < 1e-6, "the point sits where it was typed")
	# Bounding box and mass properties.
	tools.set_tool_id("bbox")
	tools._act(true, false)
	tools.update(tools.aim, 0.016)
	_check(main.view._bbox.visible and main.board.text_lines().any(func(t): return "1.00 m × 1.00 m × 500 mm" in String(t)),
		"Bounding box draws the box and writes its size (%s)" % str(main.board.text_lines().slice(4, 6)))
	tools.set_tool_id("mass")
	tools._act(true, false)
	tools.update(tools.aim, 0.016)
	_check(main.view._com.visible, "Mass properties marks the centre of mass")
	await _boards(main)
	await _part_settings(main)
	await _video_board(main)
	await _files(main)
	await _finish(main)
	await _repeat(main)
	await _history(main)


## 0.4: fillet and chamfer on picked edges, holes of each kind, shell, extrude end conditions.
func _finish(main: Node) -> void:
	main._start_mode("new")
	await _frames(2)
	main.player.set_size_now(1.0)
	main.doc.add_primitive("box", Vector3(0, 0, 0), {w = 1.0, d = 1.0, h = 0.5}, "add")
	main._on_model_changed()
	var tools: Node = main.tools
	var groups: Array = tools.wheel_tree().map(func(n): return n.name)
	_check("Finish" in groups, "the tool wheel has a Finish group")
	var vol := func() -> float: return float(main.doc.mass_properties().volume)
	# Fillet: pick the top edge at +X, then round it.
	tools.set_tool_id("fillet")
	tools.aim = main.doc.pick(Vector3(0.49, 5, 0.0), Vector3(0, -1, 0), 20.0)
	tools._act(true, false)
	_check(tools._picks.size() == 1, "Fillet picks the edge aimed at")
	tools._act(true, false)
	_check(tools._picks.is_empty(), "picking it again unpicks it")
	tools._act(true, false)
	tools._act(false, false)
	await _frames(2)
	_check(main.dialog.visible and main.dialog.type == "fillet", "the secondary action opens the fillet panel")
	main.dialog.set_value("r", 0.05)
	_check(main.dialog.ok, "the fillet previews live (%s)" % main.dialog.message)
	main.dialog.accept()
	var v1: float = vol.call()
	_check(absf(v1 - (0.5 - (1.0 - PI / 4.0) * 0.0025)) < 1e-6, "the fillet rounds that one edge (%f)" % v1)
	# Chamfer the opposite top edge.
	tools.set_tool_id("chamfer")
	tools.aim = main.doc.pick(Vector3(-0.49, 5, 0.0), Vector3(0, -1, 0), 20.0)
	tools._act(false, false)  # straight from the aimed edge
	await _frames(2)
	main.dialog.set_value("d", 0.04)
	main.dialog.accept()
	var v2: float = vol.call()
	_check(absf(v2 - (v1 - 0.5 * 0.0016)) < 1e-6, "the chamfer bevels the edge aimed at (%f)" % v2)
	# Holes in the top face.
	tools.set_tool_id("hole")
	tools.aim = main.doc.pick(Vector3(0.11, 5, 0.19), Vector3(0, -1, 0), 20.0)
	tools._act(true, false)
	await _frames(2)
	_check(main.dialog.visible and main.dialog.type == "hole", "Hole opens its panel")
	main.dialog.set_value("d", 0.1)
	main.dialog.set_value("end", "blind")
	main.dialog.set_value("depth", 0.2)
	_check(main.dialog.fields.any(func(f): return f.key == "depth"), "a blind hole shows its depth")
	main.dialog.accept()
	var v3: float = vol.call()
	_check(absf(v3 - (v2 - PI * 0.0025 * 0.2)) < 1e-5, "a blind hole cuts its cylinder (%f)" % v3)
	var hole: Dictionary = main.doc.get_features()[-1]
	var pt: Array = hole.params.point
	var snap: float = main.player.snap_step()
	_check(absf(float(pt[0]) - snappedf(0.11, snap)) < 1e-9 and absf(float(pt[1]) + snappedf(0.19, snap)) < 1e-9,
		"the snapped hole sits on the grid (%s)" % str(pt))
	tools.aim = main.doc.pick(Vector3(-0.2, 5, -0.2), Vector3(0, -1, 0), 20.0)
	tools._act(true, false)
	await _frames(2)
	main.dialog.set_value("kind", "tapped")
	var FD = load("res://scripts/feature_dialog.gd")
	var drill := {}
	for t in FD.THREADS_METRIC + FD.THREADS_INCH:
		drill[t[0]] = t[1]
	var thread: String = main.dialog.values.get("thread", "")
	_check(main.dialog.fields.any(func(f): return f.key == "thread") and absf(float(main.dialog.values.d) - float(drill.get(thread, -1.0))) < 1e-9,
		"a tapped hole picks a thread and drills its tap size (%s in %s)" % [thread, main.hud.units])
	main.dialog.set_value("kind", "counterbore")
	_check(main.dialog.fields.any(func(f): return f.key == "cbore_d") and main.dialog.ok, "a counterbore shows its bore sizes")
	main.dialog.set_value("kind", "countersink")
	_check(main.dialog.fields.any(func(f): return f.key == "csink_angle") and main.dialog.ok, "a countersink shows its sink sizes")
	main.dialog.accept()
	_check(vol.call() < v3, "the countersunk hole goes through")
	# Shell a fresh box open at the top.
	main._start_mode("new")
	await _frames(2)
	main.player.set_size_now(1.0)
	main.doc.add_primitive("box", Vector3(0, 0, 0), {w = 1.0, d = 1.0, h = 0.5}, "add")
	main._on_model_changed()
	tools.set_tool_id("shell")
	tools.aim = main.doc.pick(Vector3(0.1, 5, 0.1), Vector3(0, -1, 0), 20.0)
	tools._act(true, false)
	_check(tools._picks.size() == 1, "Shell picks the face to leave open")
	tools._act(false, false)
	await _frames(2)
	main.dialog.set_value("t", 0.05)
	main.dialog.accept()
	var inner := 0.9 * 0.9 * 0.45
	_check(absf(vol.call() - (0.5 - inner)) < 1e-6, "Shell hollows the box open at the top (%f)" % vol.call())
	# Extrude both ways and up to a face, through the panel.
	main._start_mode("new")
	await _frames(2)
	main.doc.add_primitive("box", Vector3(0, 0, 0), {w = 1.0, d = 1.0, h = 0.5}, "add")
	main._on_model_changed()
	main.player.set_size_now(1.0)
	tools.set_tool_id("sketch")
	tools.options["sketch"] = 1  # Top plane
	tools._act(true, false)
	await _frames(2)
	main.player.set_size_now(1.0)
	main.sketcher.set_tool_id("rect")
	main.sketcher.click_at(Vector2(0.75, 0.75))
	main.sketcher.click_at(Vector2(1.0, 1.0))
	main.sketcher.finish()
	await _frames(2)
	var base: float = vol.call()
	tools.set_tool_id("extrude")
	tools._act(true, false)
	await _frames(2)
	_check(main.dialog.visible and main.dialog.type == "extrude", "Extrude opens its panel (%s)" % str(main.doc.get_features().map(func(f): return f.type)))
	main.dialog.set_value("depth", 0.1)
	main.dialog.set_value("direction", "two")
	_check(main.dialog.fields.any(func(f): return f.key == "depth2"), "two directions shows a second depth")
	main.dialog.set_value("depth2", 0.2)
	_check(absf(vol.call() - (base + 0.0625 * 0.3)) < 1e-6, "the extrude goes 100 mm one way and 200 mm the other (%f)" % vol.call())
	main.dialog.set_value("direction", "normal")
	tools.aim = main.doc.pick(Vector3(0.2, 5, 0.2), Vector3(0, -1, 0), 20.0)  # the box's top face
	main.dialog.set_value("end", "up_to_face")
	_check(main.dialog.ok and not main.dialog.fields.any(func(f): return f.key == "depth"),
		"Up to face takes the aimed face and drops the depth (%s)" % main.dialog.message)
	_check(absf(vol.call() - (base + 0.0625 * 0.5)) < 1e-6, "the extrude stops at the box's top (%f)" % vol.call())
	main.dialog.set_value("end", "through_all")
	_check(main.dialog.ok, "Through all builds")
	main.dialog.accept()


## 0.5: patterns, mirror, draft and the body tools, from the wheel.
func _repeat(main: Node) -> void:
	var tools: Node = main.tools
	var vol := func() -> float: return float(main.doc.mass_properties().volume)
	var down := Vector3(0, -1, 0)
	var fresh := func() -> void:
		main._start_mode("new")
		main.player.set_size_now(1.0)
		main.doc.add_primitive("box", Vector3(0, 0, 0), {w = 1.0, d = 1.0, h = 0.5}, "add")
	fresh.call()
	await _frames(2)
	var groups: Array = tools.wheel_tree().map(func(n): return n.name)
	_check("Repeat" in groups and "Bodies" in groups, "the tool wheel has Repeat and Bodies groups")
	# A linear pattern of a boss: four along +X, 200 mm apart.
	main.doc.add_primitive("box", Vector3(-0.4, 0.5, 0.0), {w = 0.1, d = 0.1, h = 0.1}, "add")
	main._on_model_changed()
	tools.set_tool_id("linear_pattern")
	tools.aim = main.doc.pick(Vector3(-0.4, 5, 0.0), down, 20.0)
	tools._act(true, false)
	_check(tools._picks.size() == 1, "Linear pattern picks the boss")
	tools.aim = main.doc.pick(Vector3(0.0, 5, 0.3), down, 20.0)
	tools._act(false, false)
	await _frames(2)
	_check(main.dialog.visible and main.dialog.type == "pattern", "the secondary action opens the pattern panel")
	main.dialog.set_value("dir", "x")
	main.dialog.set_value("count", 4)
	main.dialog.set_value("spacing", 0.2)
	_check(absf(vol.call() - (0.5 + 4 * 0.001)) < 1e-6, "four bosses in a row (%f)" % vol.call())
	main.dialog.set_value("count2", 2)
	_check(main.dialog.fields.any(func(f): return f.key == "dir2"), "a second count shows a second direction")
	main.dialog.set_value("dir2", "-y")
	main.dialog.set_value("spacing2", 0.2)
	_check(absf(vol.call() - (0.5 + 8 * 0.001)) < 1e-6, "a 4 × 2 grid (%f)" % vol.call())
	main.dialog.accept()
	var pat: Dictionary = main.doc.get_features()[-1]
	_check(String(pat.name).begins_with("Linear pattern"), "the feature is named Linear pattern (%s)" % pat.name)
	_check(main.dialog.open_edit(pat) and main.dialog.values.dir2 == "-y" and int(main.dialog.values.count) == 4,
		"editing the pattern shows its choices again")
	main.dialog.cancel()
	# Circular: four pegs around the vertical axis through the origin.
	fresh.call()
	await _frames(2)
	main.doc.add_primitive("cylinder", Vector3(0.3, 0.5, 0.0), {r = 0.05, h = 0.1}, "add")
	main._on_model_changed()
	tools.set_tool_id("circular_pattern")
	tools.aim = main.doc.pick(Vector3(0.3, 5, 0.0), down, 20.0)
	tools._act(true, false)
	tools.aim = main.doc.pick(Vector3(-0.2, 5, -0.2), down, 20.0)
	tools._act(false, false)
	await _frames(2)
	main.dialog.set_value("axis", "z")
	main.dialog.set_value("count", 4)
	_check(main.dialog.ok and absf(vol.call() - (0.5 + 4 * PI * 0.0025 * 0.1)) < 1e-5, "Circular pattern: four pegs around Z (%f)" % vol.call())
	main.dialog.accept()
	# Mirror a boss in the Right plane.
	fresh.call()
	await _frames(2)
	main.doc.add_primitive("box", Vector3(0.3, 0.5, 0.0), {w = 0.1, d = 0.1, h = 0.1}, "add")
	main._on_model_changed()
	tools.set_tool_id("mirror")
	tools.aim = main.doc.pick(Vector3(0.3, 5, 0.0), down, 20.0)
	tools._act(true, false)
	tools.aim = {}
	tools._act(false, false)
	await _frames(2)
	main.dialog.set_value("plane", "right")
	_check(main.dialog.ok and absf(vol.call() - (0.5 + 2 * 0.001)) < 1e-6, "Mirror copies the boss across the Right plane (%f)" % vol.call())
	main.dialog.accept()
	# Draft the +X side 5° from the top face.
	fresh.call()
	await _frames(2)
	main._on_model_changed()
	tools.set_tool_id("draft")
	tools.aim = main.doc.pick(Vector3(5, 0.25, 0.0), Vector3(-1, 0, 0), 20.0)
	tools._act(true, false)
	_check(tools._picks.size() == 1, "Draft picks the side face")
	tools.aim = main.doc.pick(Vector3(0.0, 5, 0.0), down, 20.0)
	tools._act(false, false)
	await _frames(2)
	_check(main.dialog.visible and main.dialog.type == "draft", "the secondary action on a flat face opens the draft panel")
	main.dialog.set_value("angle", deg_to_rad(5.0))
	var wedge := 0.5 * 0.5 * tan(deg_to_rad(5.0)) * 0.5 * 1.0
	_check(main.dialog.ok and absf(vol.call() - (0.5 - wedge)) < 1e-6, "the side leans in 5° away from the top (%f)" % vol.call())
	main.dialog.adjust(1)
	_check(absf(float(main.dialog.values.angle) - deg_to_rad(6.0)) < 1e-9, "the draft angle steps by 1°")
	main.dialog.accept()
	# Two overlapping bodies: combine them, then subtract instead.
	fresh.call()
	main.doc.add_primitive("box", Vector3(0.5, 0, 0), {w = 1.0, d = 1.0, h = 0.5}, "new-body")
	main._on_model_changed()
	await _frames(2)
	_check(main.doc.body_count() == 2, "two bodies to combine")
	tools.set_tool_id("combine")
	tools.aim = main.doc.pick(Vector3(-0.4, 5, 0.0), down, 20.0)
	tools._act(true, false)
	tools.aim = main.doc.pick(Vector3(0.9, 5, 0.0), down, 20.0)
	tools._act(true, false)
	_check(tools._picks.size() == 2, "Combine picks both bodies (%d)" % tools._picks.size())
	tools._act(false, false)
	await _frames(2)
	_check(main.dialog.visible and main.dialog.type == "body" and main.doc.body_count() == 1
		and absf(vol.call() - 0.75) < 1e-6, "Combine joins them into one body (%f)" % vol.call())
	main.dialog.set_value("how", "subtract")
	_check(main.dialog.fields.any(func(f): return f.key == "keep") and absf(vol.call() - 0.25) < 1e-6,
		"Subtract cuts the second from the first (%f)" % vol.call())
	main.dialog.set_value("keep", "yes")
	_check(main.doc.body_count() == 2, "and can keep the second body")
	main.dialog.accept()
	# Split a body with the Right plane, then delete one half.
	fresh.call()
	main._on_model_changed()
	await _frames(2)
	tools.set_tool_id("split")
	tools.aim = main.doc.pick(Vector3(0.2, 5, 0.2), down, 20.0)
	tools._act(true, false)
	tools.aim = {}
	tools._act(false, false)
	await _frames(2)
	main.dialog.set_value("plane", "right")
	_check(main.dialog.ok and main.doc.body_count() == 2, "Split cuts the box in two with the Right plane")
	main.dialog.accept()
	tools.set_tool_id("delete_body")
	tools.aim = main.doc.pick(Vector3(0.3, 5, 0.0), down, 20.0)
	tools._act(true, false)
	_check(main.doc.body_count() == 1 and absf(vol.call() - 0.25) < 1e-6, "Delete body removes the half aimed at")
	tools._act(false, false)
	_check(main.doc.body_count() == 2, "and the secondary action undoes it")


## 0.6: the rollback bar, moving and suppressing features, re-picking a failed feature's edges.
func _history(main: Node) -> void:
	main._start_mode("new")
	main.player.set_size_now(1.0)
	await _frames(2)
	var doc: RefCounted = main.doc
	var vol := func() -> float: return float(doc.mass_properties().volume)
	var f1: String = doc.add_primitive("box", Vector3(0, 0, 0), {w = 1.0, d = 1.0, h = 0.5}, "add")
	var f2: String = doc.add_primitive("box", Vector3(0, 0.5, 0), {w = 0.4, d = 0.4, h = 0.4}, "add")
	var f3: String = doc.add_primitive("cylinder", Vector3(0.3, 0, 0.3), {r = 0.05, h = 2.0}, "cut")
	main._on_model_changed()
	var full: float = vol.call()
	main.hud.set_panel(true)
	main.hud.show_feature(f2)
	await _frames(2)
	var texts: Array = main.hud._params.find_children("*", "Button", true, false).map(func(b): return b.text)
	_check("Roll back to here" in texts and "Suppress" in texts and "▲ Move up" in texts, "the model panel offers the history controls (%s)" % ", ".join(texts))
	main._on_hud_request("roll_here", f1)
	_check(doc.get_rollback() == 1 and absf(vol.call() - 0.5) < 1e-9, "Roll back to here builds only the first box")
	_check(doc.get_features()[2].rolled_back, "the features below the bar show as rolled back")
	await _frames(2)
	var tree: Array = main.hud._tree.find_children("*", "Button", true, false).map(func(b): return b.text)
	_check(tree.any(func(t): return "rollback bar" in t), "the tree shows the rollback bar")
	var sphere: String = doc.add_primitive("sphere", Vector3(3, 0, 0), {r = 0.1}, "new-body")
	_check(doc.get_features()[1].id == sphere and doc.get_rollback() == 2, "a new feature goes in at the bar")
	main._on_hud_request("roll_forward", null)
	_check(doc.get_rollback() == -1 and doc.body_count() == 2, "Roll forward builds everything again")
	doc.undo()
	doc.undo()
	doc.undo()
	main._on_model_changed()
	_check(doc.get_features().size() == 3 and absf(vol.call() - full) < 1e-9, "undo takes the bar and the sphere away (%d features)" % doc.get_features().size())
	# Moving: the cut moves above the second box; a pattern cannot move above what it repeats.
	main._on_hud_request("move_feature_up", f3)
	_check(doc.get_features()[1].id == f3 and absf(vol.call() - full) < 1e-9, "Move up reorders the cut; the result is the same")
	var pat: Dictionary = doc.insert_feature("pattern", "", {features = [f2], kind = "linear", dir = "x", count = 2, spacing = -0.5})
	main._on_model_changed()
	_check(pat.ok, "a pattern of the second box (%s)" % pat.get("message", ""))
	var r: Dictionary = doc.reorder_feature(pat.id, 1)
	_check(not r.ok and doc.get_features()[3].id == pat.id, "moving the pattern above what it repeats is refused: %s" % r.message)
	# Suppress the second box: it and its pattern copy go.
	var with_pattern: float = vol.call()
	main._on_hud_request("toggle_suppress", f2)
	_check(vol.call() < with_pattern - 0.05, "Suppress takes the box out (%f)" % vol.call())
	main._on_hud_request("toggle_suppress", f2)
	_check(absf(vol.call() - with_pattern) < 1e-9, "and Unsuppress brings it back")
	# A fillet whose edge is gone: re-pick it in the room.
	var bad: Dictionary = doc.insert_feature("fillet", "", {picks = [[5.0, 5.0, 5.0]], r = 0.02})
	main._on_model_changed()
	_check(not bad.ok, "a fillet with a lost edge fails")
	main.hud.show_feature(bad.id)
	await _frames(2)
	texts = main.hud._params.find_children("*", "Button", true, false).map(func(b): return b.text)
	_check(texts.any(func(t): return String(t).begins_with("Re-pick")), "a failed feature offers Re-pick")
	main._on_hud_request("repick", bad.id)
	var tools: Node = main.tools
	_check(tools.tool().id == "fillet" and not tools.repair.is_empty(), "Re-pick switches to the fillet tool")
	tools.aim = doc.pick(Vector3(0.49, 5, 0.1), Vector3(0, -1, 0), 20.0)
	tools._act(true, false)
	tools._act(false, false)
	await _frames(2)
	var fixed := false
	for f in doc.get_features():
		if f.id == bad.id:
			fixed = f.ok
	_check(fixed and tools.repair.is_empty() and not main.dialog.visible, "picking a new edge fixes the fillet")
	main.hud.set_panel(false)


## 0.3: Save, Save as, the Open browser, opening a file, STEP import, New part in other units.
func _files(main: Node) -> void:
	var FB = load("res://scripts/file_browser.gd")
	DirAccess.make_dir_recursive_absolute("user://projects")
	for e in FB.saved_files():
		if String(e.name).begins_with("Smoke "):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(e.path))
	main.doc.set_part_name("Smoke part")
	main.current_path = ""
	main._save()
	var first: String = main.current_path
	_check(first.ends_with("Smoke part.fpprt") and FileAccess.file_exists(first), "Save names the file after the part (%s)" % first)
	main.current_path = ""
	main._save()
	_check(main.current_path.ends_with("Smoke part 2.fpprt"), "a new part never overwrites another's file (%s)" % main.current_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(main.current_path))
	main.current_path = first
	main._save_as()
	_check(main.numpad.visible, "Save as asks for a name")
	main.numpad._edit.text = "Smoke bracket"
	main.numpad._key("OK")
	_check(main.doc.get_part_name() == "Smoke bracket" and main.current_path.ends_with("Smoke bracket.fpprt") and FileAccess.file_exists(main.current_path),
		"Save as renames the part and saves it under the new name")
	var names: Array = FB.saved_files().map(func(e): return e.name)
	_check("Smoke bracket" in names and "Smoke part" in names, "the Open browser lists saved parts")
	main.file_browser.open()
	_check(main.file_browser.visible and main.file_browser._list.get_child_count() >= 2, "Open shows them")
	var entry: Dictionary = FB.saved_files().filter(func(e): return e.name == "Smoke part")[0]
	main.file_browser._duplicate(entry)
	_check(FileAccess.file_exists("user://projects/Smoke part copy.fpprt"), "Duplicate copies a part")
	var copy: Dictionary = FB.saved_files().filter(func(e): return e.name == "Smoke part copy")[0]
	main.file_browser._delete(copy)
	_check(FileAccess.file_exists(copy.path), "Delete asks once more first")
	main.file_browser._delete(copy)
	_check(not FileAccess.file_exists(copy.path), "the second press deletes")
	main.file_browser._open(entry)
	_check(not main.file_browser.visible and main.doc.get_part_name() == "Smoke part" and main.current_path == entry.path, "opening a saved part loads it")
	# STEP: export this part, import it back as a new body.
	var vol: float = main.doc.mass_properties().volume
	var bodies: int = main.doc.body_count()
	var step := ProjectSettings.globalize_path("user://smoke-import.step")
	_check(main.doc.export_file(step, "mm").ok, "the part exports to STEP")
	main.import_step_file(step)
	_check(main.doc.body_count() == bodies + 1 and absf(main.doc.mass_properties().volume - 2.0 * vol) < vol * 1e-3
		and main.doc.get_features()[-1].type == "import", "Import STEP brings it in as a new body (%d bodies)" % main.doc.body_count())
	var imp: Dictionary = main.doc.get_features()[-1]
	_check(main.doc.move_feature(imp.id, Vector3(0.5, 0, 0)).ok, "an imported body can be moved")
	main._save()
	var again: RefCounted = ClassDB.instantiate(&"CadPart")
	_check(again.load_file(ProjectSettings.globalize_path(main.current_path)) == "" and again.rebuild().ok
		and absf(again.mass_properties().volume - 2.0 * vol) < vol * 1e-3, "the imported shape is saved inside the part file")
	DirAccess.remove_absolute(step)
	# New part in IPS.
	main._on_hud_request("new_part", null)
	_check(main.hud._menu_buttons.has("new:IPS"), "New part offers the unit systems")
	main._on_hud_request("new:IPS", null)
	await _frames(3)
	_check(main.doc.get_units() == "in" and main.doc.get_mass_units() == "lb" and main.doc.get_features().is_empty()
		and main.current_path == "", "New part in IPS starts a blank inch part")
	for e in FB.saved_files():
		if String(e.name).begins_with("Smoke "):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(e.path))


## A video board: what can play, the error screen for what can't, pause, and saving the link.
func _video_board(main: Node) -> void:
	var WB = load("res://scripts/whiteboard.gd")
	_check(WB.url_problem("https://www.youtube.com/watch?v=abc").contains("youtube.com") and WB.url_problem("ftp://x/v.ogv").contains("web link")
		and WB.url_problem("https://example.com/clip.ogv") == "", "links to video sites and non-web links are turned away before downloading")
	var ogv := FileAccess.get_file_as_bytes("res://tests/tiny.ogv")
	var mp4 := PackedByteArray([0, 0, 0, 32]) + "ftypisom".to_ascii_buffer() + PackedByteArray([0, 0, 2, 0])
	var webm := PackedByteArray([0x1A, 0x45, 0xDF, 0xA3, 1, 0, 0, 0])
	_check(WB.video_problem(ogv.slice(0, 4096)) == "" and WB.video_problem(mp4).contains("MP4") and WB.video_problem(webm).contains("WebM")
		and WB.video_problem("<!DOCTYPE html><html>".to_ascii_buffer(), "text/html").contains("web page")
		and WB.video_problem("OggS".to_ascii_buffer() + PackedByteArray([0, 2, 0, 0]) + "vorbis".to_ascii_buffer()).contains("without Theora"),
		"downloads are told apart: Ogg Theora plays; MP4, WebM, web pages and sound-only Ogg get an error screen")
	# Web pages: the page's main video.
	var page := "https://news.example.com/stories/today/item.html?x=1"
	_check(WB.find_page_video('<meta property="og:video" content="https://cdn.example.com/a.mp4"><video src="b.mp4" width="1920" height="1080"></video>', page)
		== "https://cdn.example.com/a.mp4", "a page's declared video (og:video) comes first")
	_check(WB.find_page_video('<video src="small.mp4" width="320" height="180"></video><video width="1280" height="720"><source src="../media/big.webm" type="video/webm"></video>', page)
		== "https://news.example.com/stories/media/big.webm", "else the largest <video>, its <source> made absolute")
	_check(WB.find_page_video('<script type="application/ld+json">{"@type":"VideoObject","contentUrl":"https:\\/\\/v.example.com\\/c.mp4"}</script>', page)
		== "https://v.example.com/c.mp4", "a VideoObject's contentUrl counts as declared")
	_check(WB.find_page_video('<base href="https://static.example.org/x/"><p><a href="clips/d.mp4?dl=1&amp;t=2">download</a></p>', page)
		== "https://static.example.org/x/clips/d.mp4?dl=1&t=2", "else a link to a video file, with <base> and entities")
	_check(WB.find_page_video('<video src="blob:https://x/123"></video><video><source src="/live/master.m3u8" type="application/x-mpegURL"></video>', page)
		== "https://news.example.com/live/master.m3u8" and WB.is_stream("https://news.example.com/live/master.m3u8?t=1"),
		"script-made blob: videos are skipped; an HLS playlist is taken as a stream")
	_check(WB.find_page_video("<p>No video here</p><a href='/about.html'>about</a>", page) == "", "a page with no video finds nothing")
	var wiki := ('<video controls width="220" height="124" data-mwtitle="Clip.webm">'
		+ '<source src="//upload.wikimedia.org/wikipedia/commons/a/ab/Clip.webm" type="video/webm; codecs=&quot;vp9, opus&quot;" data-width="3840" data-height="2160">'
		+ '<source src="//upload.wikimedia.org/wikipedia/commons/transcoded/a/ab/Clip.webm/Clip.webm.1080p.vp9.webm" type="video/webm; codecs=&quot;vp9, opus&quot;" data-transcodekey="1080p.vp9.webm" data-width="1920" data-height="1080">'
		+ '<source src="//upload.wikimedia.org/wikipedia/commons/transcoded/a/ab/Clip.webm/Clip.webm.720p.vp9.webm" type="video/webm; codecs=&quot;vp9, opus&quot;" data-transcodekey="720p.vp9.webm" data-width="1280" data-height="720">'
		+ '<source src="//upload.wikimedia.org/wikipedia/commons/transcoded/a/ab/Clip.webm/Clip.webm.480p.vp9.webm" type="video/webm; codecs=&quot;vp9, opus&quot;" data-transcodekey="480p.vp9.webm" data-width="854" data-height="480">'
		+ '<source src="//upload.wikimedia.org/wikipedia/commons/transcoded/a/ab/Clip.webm/Clip.webm.144p.mjpeg.mov" type="video/quicktime" data-transcodekey="144p.mjpeg.mov" data-width="256" data-height="144">'
		+ '</video>')
	_check(WB.find_page_video(wiki, "https://en.wikipedia.org/wiki/Video") == "https://upload.wikimedia.org/wikipedia/commons/transcoded/a/ab/Clip.webm/Clip.webm.720p.vp9.webm",
		"on a Wikipedia page the 720p version is taken, not the 4K original (%s)" % WB.find_page_video(wiki, "https://en.wikipedia.org/wiki/Video").get_file())
	_check(WB.find_page_video('<video><source src="a.webm" type="video/webm" data-height="720"><source src="a.ogv" type="video/ogg"></video>', page).ends_with("/a.ogv"),
		"an Ogg source is preferred: it plays without converting")
	_check(WB.find_page_video('<meta property="og:video" content="https://www.youtube.com/embed/abc">', page).contains("youtube.com"),
		"an embedded YouTube video is found, so the board can say why it can't play it")
	_check(WB.user_agent().begins_with("FPS-CAD/") and WB.user_agent().contains("https://github.com/BarksAndBytes/FPS-CAD") and WB.user_agent().contains("Godot/"),
		"downloads name the game and where to find out about it, as Wikimedia asks (%s)" % WB.user_agent())
	_check(WB.retry_delay(PackedStringArray(["Retry-After: 3"]), 0) == 3.0 and WB.retry_delay(PackedStringArray(), 0) == 5.0
		and WB.retry_delay(PackedStringArray(), 2) == 20.0 and WB.retry_delay(PackedStringArray(), 3) < 0.0
		and WB.retry_delay(PackedStringArray(["retry-after: 600"]), 0) < 0.0, "a busy server is asked again after its Retry-After, three times at most")
	main.tools.set_tool_id("board_video")
	main.tools._act(true, false)
	await _frames(2)
	var vb: Node3D = main.boards.extra[-1]
	_check(vb.kind == "video" and main.video_menu.visible and main.video_menu.board == vb, "Video board sets up a board and opens its video menu")
	main.video_menu._choose_link()
	_check(not main.video_menu.visible and main.numpad.visible and main.numpad._lower, "Enter a link asks for it on the text pad (lower case)")
	main.numpad.close()
	_check(WB.is_local("C:/Users/me/Videos/a.mp4") and WB.is_local("/home/me/a.mp4") and WB.is_local("content://com.android.providers/document/1")
		and WB.is_local("user://videos/x.ogv") and not WB.is_local("https://example.com/a.mp4"), "files on this device are told from web links")
	_check(WB.local_name("content://com.android.externalstorage.documents/document/primary%3AMovies%2Fclip.mp4") == "clip.mp4"
		and WB.local_name("content://com.android.providers.media.documents/document/video%3A1234") == "Video from this device"
		and WB.page_title("<html><head><title>Video &amp; film - Wikipedia</title></head>") == "Video & film - Wikipedia",
		"local files and pages get readable names")
	vb.play_file("res://tests/tiny.ogv", "https://example.com/tiny.ogv")
	await _frames(10)
	_check(vb.video_state == "playing" and vb._video.is_playing() and vb._view.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"an Ogg Theora video plays on the board")
	vb.toggle_video()
	_check(vb.video_state == "paused" and vb._video.paused, "the primary button pauses it")
	vb.toggle_video()
	_check(vb.video_state == "playing" and not vb._video.paused, "and carries on")
	var bad := OS.get_user_data_dir().path_join("smoke-video.mp4")
	var f := FileAccess.open(bad, FileAccess.WRITE)
	f.store_buffer(mp4)
	f.close()
	var has_ff: bool = WB.ffmpeg_path() != ""
	vb.play_file(bad, "https://example.com/broken.mp4")
	for i in 600:
		if vb.video_state != "converting":
			break
		await _frames(1)
	var lines: Array = vb.text_lines()
	_check(vb.video_state == "error" and String(lines[1]) == "Can't play this video" and not vb._video.visible
		and (String(lines[2]).contains("FFmpeg couldn't convert") if has_ff else String(lines[2]).contains("needs FFmpeg")),
		"a broken MP4 gets the error screen (%s)" % String(lines[2]).get_slice("\n", 0))
	DirAccess.remove_absolute(bad)
	if has_ff:
		# A real MP4 is converted to Theora in the background, with progress, then plays.
		var url := "https://example.com/tiny-%d.mp4" % Time.get_ticks_usec()
		vb.play_file("res://tests/tiny.mp4", url)
		_check(vb.video_state == "converting" and String(vb.text_lines()[1]).begins_with("Converting"), "an MP4 is converted with FFmpeg")
		for i in 900:
			if vb.video_state != "converting":
				break
			await _frames(1)
		_check(vb.video_state == "playing" and FileAccess.file_exists(WB.cached_path(url)), "then plays, kept for next time (%s)" % vb.video_message)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(WB.cached_path(url)))
		# VP9 and Opus in WebM, as Wikipedia serves.
		url = "https://example.com/tiny-%d.webm" % Time.get_ticks_usec()
		vb.play_file("res://tests/tiny.webm", url)
		for i in 900:
			if vb.video_state != "converting":
				break
			await _frames(1)
		_check(vb.video_state == "playing", "a VP9 / Opus WebM converts and plays (%s)" % vb.video_message)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(WB.cached_path(url)))
		# A longer video is cut into slices encoded at once, then joined.
		var plan: Array = WB.slice_plan(10.0, 3, 10.0)
		_check(plan.size() == 3 and plan[0][1] == 34 and absf(plan[1][0] - 3.4) < 1e-9 and plan[1][1] == 34 and plan[2][1] == 0 and absf(plan[2][2] - 3.2) < 1e-9,
			"a 10 s, 10 fps video makes three slices cut on frames: 34, 34 and the last 32")
		var pi: Dictionary = WB.probe_info("  Duration: 00:01:02.50, start: 0.000000\n  Stream #0:0[0x1](und): Video: vp9 (Profile 0), yuv420p(tv), 1280x720, SAR 1:1 DAR 16:9, 29.97 fps, 29.97 tbr, 1k tbn\n  Stream #0:1: Audio: opus, 48000 Hz")
		_check(absf(pi.duration - 62.5) < 1e-6 and pi.audio and absf(pi.fps - 29.97) < 1e-6 and not WB.probe_info("Duration: N/A").audio,
			"FFmpeg's log gives the length, the frame rate and whether there is sound")
		WB.workers_override = 3
		url = "https://example.com/ten-%d.mp4" % Time.get_ticks_usec()
		vb.play_file("res://tests/ten_seconds.mp4", url)
		var most := 0
		for i in 3000:
			if vb.video_state != "converting":
				break
			most = maxi(most, vb._jobs.size())
			await _frames(1)
		WB.workers_override = 0
		_check(WB.last_split_problem == "", "the slices joined without falling back (%s)" % WB.last_split_problem)
		var length: float = vb._video.get_stream_length() if vb.video_state == "playing" else 0.0
		_check(vb.video_state == "playing" and most == 4 and absf(length - 10.0) < 0.06 and not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(WB.cached_path(url).get_basename() + ".parts")),
			"three slices and the sound convert at once, join into one 10 s video, and the pieces are cleared away (%d jobs, %.2f s, %s)" % [most, length, vb.video_message])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(WB.cached_path(url)))
		# If joining fails (as with an FFmpeg that lacks the concat reader), it converts in one go.
		WB.workers_override = 2
		WB.test_bad_join = true
		url = "https://example.com/ten-bad-join-%d.mp4" % Time.get_ticks_usec()
		vb.play_file("res://tests/ten_seconds.mp4", url)
		for i in 3000:
			if vb.video_state != "converting":
				break
			await _frames(1)
		WB.workers_override = 0
		WB.test_bad_join = false
		_check(vb.video_state == "playing" and WB.last_split_problem.begins_with("joining"),
			"a failed join falls back to converting in one process, and still plays (%s)" % WB.last_split_problem)
		WB.last_split_problem = ""
		DirAccess.remove_absolute(ProjectSettings.globalize_path(WB.cached_path(url)))
		# A video file on this device: converted, kept in the library under its file name.
		var local_clip := ProjectSettings.globalize_path("res://tests/ten_seconds.mp4")
		WB.forget_video(WB.cached_path(local_clip))
		main.boards.play_video(vb, local_clip)
		for i in 3000:
			if vb.video_state != "converting":
				break
			await _frames(1)
		var lib: Array = WB.library()
		var entry: Dictionary = {}
		for e in lib:
			if e.link == local_clip:
				entry = e
		_check(vb.video_state == "playing" and not entry.is_empty() and entry.title == "ten_seconds.mp4" and int(entry.bytes) > 0,
			"a file on this device converts, plays, and is listed in the library by name (%s)" % vb.video_message)
		# The video menu lists it; choosing it on another board plays the kept copy at once.
		var other: Node3D = main.boards.add("video", Vector3(2, main.view.room.floor_y(), -2), 0.0, 1.0)
		main.video_menu.open(other)
		var rows: int = main.video_menu._list.get_child_count()
		_check(rows >= 1 and main.video_menu._summary.text.begins_with("Downloaded videos"), "the video menu lists the downloaded videos (%d)" % rows)
		main.video_menu._play(entry)
		_check(not main.video_menu.visible and other.video_state == "playing" and other.video_url == local_clip, "choosing one plays it straight away")
		main.video_menu.open(other)
		main.video_menu._delete(entry)
		_check(not FileAccess.file_exists(entry.path) and other.video_state == "ready" and vb.video_state == "ready"
			and not WB.library().any(func(e): return e.path == entry.path), "Delete stops the boards playing it and removes the file")
		main.video_menu.close()
		main.boards.remove(other)
		# Android's picked files are copied in first, a piece each frame, then converted.
		vb.video_url = "content://test/tiny.webm"
		vb.video_title = ""
		var copied_to: String = WB.cached_path("content://test/tiny.webm")
		vb._copy_in("res://tests/tiny.webm", copied_to)
		_check(vb.video_state == "copying", "a picked file is copied in")
		for i in 3000:
			if vb.video_state != "copying" and vb.video_state != "converting":
				break
			await _frames(1)
		_check(vb.video_state == "playing" and FileAccess.file_exists(copied_to) and not FileAccess.file_exists(copied_to.get_basename() + ".src"),
			"then converted and played, the copy cleared away (%s)" % vb.video_message)
		WB.forget_video(copied_to)
	else:
		print("SKIP FFmpeg conversion: no ffmpeg on this machine")
	vb.play_url("https://youtu.be/abc")
	_check(vb.video_state == "error" and String(vb.text_lines()[2]).contains("youtu.be"), "a YouTube link gets the error screen at once")
	vb.set_video("https://example.com/tiny.ogv")
	main.boards.save()
	var saved: Array = main.doc.get_boards().filter(func(d): return d.kind == "video")
	_check(not saved.is_empty() and saved[-1].url == "https://example.com/tiny.ogv" and vb.video_state == "ready", "the link is saved with the part")
	main.boards.remove(vb)


## Units and material from the pause menu: sizes stay put, mass and looks follow the material.
func _part_settings(main: Node) -> void:
	var doc: RefCounted = main.doc
	var vol: float = doc.mass_properties().volume
	main.hud.set_menu_items(main._menu_items())
	_check(main.hud._menu_buttons.has("units_menu") and main.hud._menu_buttons.has("material_menu")
		and main.hud._menu_buttons.units_menu.text == "Units: MMGS (mm, g)", "the pause menu has Units and Material")
	main._on_hud_request("material_menu", null)
	_check(main._menu_page == "material" and main.hud._menu_buttons.has("material:Steel AISI 1020")
		and main.hud._menu_buttons.has("material_custom"), "Material lists the library and a custom density")
	main._on_hud_request("material:Steel AISI 1020", null)
	var steel: Dictionary = doc.material_info()
	_check(doc.get_material() == "Steel AISI 1020" and absf(doc.mass_properties().mass - vol * 7870.0) < 1e-6
		and main._menu_page == "" and main.view.appearance.get("color", "") == "#7f8389",
		"choosing steel sets its density, its look, and returns to the pause menu")
	_check(absf(float(steel.youngs_modulus) - 200e9) < 1.0 and float(steel.yield_strength) == 350e6, "the material carries its properties")
	_check(doc.undo() and doc.get_material() == "Aluminium 6061-T6", "undo takes the material back")
	doc.redo()
	# Units: IPS keeps every size, shows inches and pounds.
	main._on_hud_request("units_menu", null)
	_check(main.hud._menu_buttons.has("units:IPS") and main.hud._menu_buttons.has("units:FPS"), "Units lists MMGS, CGS, MKS, IPS and FPS")
	main._on_hud_request("units:IPS", null)
	_check(main.hud.units == "in" and doc.get_units() == "in" and doc.get_mass_units() == "lb"
		and absf(doc.mass_properties().volume - vol) < 1e-9, "IPS changes the units, not the part")
	_check(main.hud.length(0.0254) == "1.00 in" and main.hud.length(0.3048 * 100.0) == "100.00 ft", "lengths read in inches (feet when long)")
	var t: Array = main.boards.properties_text(doc, main.hud.units)
	_check("in³" in String(t[1]) and " lb" in String(t[1]) and "lb/in³" in String(t[1]) and "Msi" in String(t[1]) and "ksi" in String(t[1]),
		"the properties read in inches, pounds and ksi (%s)" % String(t[1]).replace("\n", " | "))
	_check(main.Units.show(0.0254, "in") == "1", "typed and shown values use the part's unit")
	main._on_hud_request("units:MMGS", null)
	_check(main.hud.units == "mm" and absf(doc.mass_properties().volume - vol) < 1e-9, "back to MMGS")
	# A typed density, in the unit system's own unit (g/cm³ in MMGS).
	main._on_hud_request("material_custom", null)
	_check(main.numpad.visible, "Custom density asks for a number")
	main.numpad._edit.text = "1.5"
	main.numpad._key("OK")
	_check(doc.get_material() == "Custom" and absf(doc.get_density() - 1500.0) < 1e-9 and doc.material_info().youngs_modulus == null,
		"a custom density of 1.5 g/cm³ is 1,500 kg/m³, with no other properties claimed")
	main._on_hud_request("material:Aluminium 6061-T6", null)
	main.hud.set_menu(false)


## Whiteboards the player adds: a properties board, a notes board, carrying, saving.
func _boards(main: Node) -> void:
	var boards: Node3D = main.boards
	var fy: float = main.view.room.floor_y()
	main.player.feet = Vector3(3, fy, 3)
	main.player.yaw = 0.0
	main.player.pitch = -0.3
	var before: int = boards.extra.size()
	main.tools.set_tool_id("board_props")
	main.tools._act(true, false)
	await _frames(2)
	_check(boards.extra.size() == before + 1 and boards.extra[-1].kind == "properties", "Properties board sets up a board")
	var pb: Node3D = boards.extra[-1]
	var pl: Array = pb.text_lines()
	_check(String(pl[0]) == "PART PROPERTIES" and "Volume" in String(pl[2]) and "Bounding box   1,000 × 1,000 × 500 mm" in String(pl[2])
		and "Mass" in String(pl[2]) and "Material   Aluminium 6061-T6   ·   2.7 g/cm³" in String(pl[2]) and "E 68.9 GPa" in String(pl[2]), "it shows the part's volume, mass and bounding box (%s)" % String(pl[2]).replace("\n", " | "))
	_check(absf(pb.global_position.y - fy) < 1e-6 and pb.global_position.z < 3.0, "it stands on the floor ahead of the player")
	# A notes board: the first note comes from the text pad.
	main.tools.set_tool_id("board_notes")
	main.player.pitch = 0.2  # looking up: a new board stands a little way ahead
	main.tools._act(true, false)
	await _frames(2)
	var nb: Node3D = boards.extra[-1]
	_check(nb.kind == "notes" and main.numpad.visible, "Notes board sets up a board and asks for the first note")
	main.numpad._edit.text = "Check the wall thickness"
	main.numpad._key("OK")
	boards.set_note(nb, -1, "Fillet the top later")
	await _frames(3)
	_check(nb.notes == ["Check the wall thickness", "Fillet the top later"] and "•  Fillet the top later" in nb._note_labels[1].text,
		"notes are written on the board, one per line")
	# Aiming at the second note finds it (for editing).
	var r: Rect2 = nb._note_labels[1].get_global_rect()
	var px := r.get_center()
	var local: Vector3 = nb.PANEL_CENTRE + nb.PANEL_RIGHT * (px.x / nb.TEX.x - 0.5) * nb.PANEL_SIZE.x \
		+ nb.PANEL_UP.normalized() * (0.5 - px.y / nb.TEX.y) * nb.PANEL_SIZE.y
	_check(nb.note_at(nb.global_transform * local) == 1, "the note under the crosshair is found")
	boards._ask_note(nb, 0)
	main.numpad._edit.text = ""
	main.numpad._key("OK")  # cleared: the note goes
	_check(nb.notes == ["Fillet the top later"] and not main.numpad.visible, "clearing a note deletes it")
	# Carrying: it follows the player on the floor, turns and resizes, and is saved where it lands.
	var s0: float = nb.board_scale
	var f0: Vector3 = nb.feet()
	boards.pick_up(nb)
	_check(main.player.size_locked, "while a board is carried the size keys belong to it")
	boards.turn(1.0)
	boards.rescale(1.0)
	main.player.feet += Vector3(2, 0, 0)
	boards.update_carry()
	_check(absf(nb.board_scale - s0 * 1.25) < 1e-6 and absf(nb.feet().x - f0.x - 2.0) < 1e-3 and absf(nb.feet().y - fy) < 1e-6
		and absf(nb.global_position.y - fy) < 1e-6, "a carried board follows the player, resized, still standing on the floor")
	boards.drop()
	var saved_notes: Array = main.doc.get_boards().filter(func(d): return d.kind == "notes")
	_check(not main.player.size_locked and not saved_notes.is_empty() and saved_notes[-1].notes == ["Fillet the top later"]
		and absf(float(saved_notes[-1].scale) - s0 * 1.25) < 1e-6, "setting it down saves it in the part")
	var m0: Vector3 = main.board.feet()
	boards.pick_up(main.board)
	main.player.feet += Vector3(-3, 0, 1)
	boards.update_carry()
	boards.cancel()
	_check(main.board.feet().distance_to(m0) < 1e-6, "putting a board back returns it to where it stood")
	# The layout survives a save and a reopen, and undo leaves boards where they are.
	var path := OS.get_user_data_dir().path_join("smoke-boards.fpprt")
	_check(main.doc.save_file(path) == "", "the part saves with its boards")
	var back = ClassDB.instantiate(&"CadPart")
	_check(back.load_file(path) == "" and back.get_boards().size() == main.doc.get_boards().size()
		and back.get_boards().any(func(d): return d.kind == "properties"), "the boards come back with the part (%d)" % back.get_boards().size())
	main.doc.checkpoint()
	var kept: Array = main.doc.get_boards()
	main.doc.set_boards(kept.slice(0, 1))
	main.doc.undo()
	_check(main.doc.get_boards().size() == 1, "undo leaves the boards as they are")
	main.doc.set_boards(kept)
	boards.remove(main.board)
	_check(main.board.active, "the message board cannot be removed")
	boards.remove(pb)
	_check(not boards.extra.has(pb) and not main.doc.get_boards().any(func(d): return d.get("id", "") == pb.board_id), "a board can be removed")
	DirAccess.remove_absolute(path)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _seconds(t: float) -> void:
	await create_timer(t).timeout


func _touch(tc: Node, index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	tc._input(e)


func _drag(tc: Node, index: int, pos: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	tc._input(e)


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
