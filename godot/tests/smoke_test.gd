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

	# Update checks: the decision logic, without touching the network.
	var up = load("res://scripts/updater.gd")
	var newer: Dictionary = up.evaluate({build = 12, apk = "https://example.invalid/a.apk", signing = "release"}, 11)
	_check(newer.newer, "a higher build number is offered as an update")
	_check(not up.evaluate({build = 11, apk = "x", signing = "release"}, 11).newer, "the same build is not an update")
	_check(not up.evaluate({build = 13, apk = "x", signing = "debug"}, 11).newer, "a debug-signed build is not offered (it could not install over this one)")
	_check(not up.evaluate("nonsense", 11).newer and not up.evaluate({build = 13}, 11).newer, "unreadable update information is ignored")
	_check(not up.supported(), "local and desktop builds never check for updates")
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
