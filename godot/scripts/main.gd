extends Node3D
## Wires the game together: the CAD document (from the C++ extension), the player, the model
## view, the tools, the HUD, the tool wheel, touch controls, the controls map, the splash cards,
## the title screen and the training course. Owns gameplay input, files and autosave.
## Everything runs locally; files live in the app's user:// folder.
##
## States: "splash" → "title" → "play". Play modes: "training", "new", "challenge", "free",
## "assembly".
## Inside play, sketch mode (sketcher.gd) takes the tools while a sketch is open, and the
## feature panel (feature_dialog.gd) takes the D-pad and buttons while a feature is set up.

const PROJECTS := "user://projects"
const EXPORTS := "user://exports"
const RECOVERY := "user://recovery/autosave"
const AUTOSAVE_SECONDS := 120.0
const UiTheme := preload("res://scripts/ui_theme.gd")
const ToolsScript := preload("res://scripts/tools.gd")
const Tutorial := preload("res://scripts/tutorial.gd")
const Sketcher := preload("res://scripts/sketcher.gd")
const Challenge := preload("res://scripts/challenge.gd")
const ToolWheel := preload("res://scripts/tool_wheel.gd")
const Whiteboard := preload("res://scripts/whiteboard.gd")
const Units := preload("res://scripts/units.gd")
const Boards := preload("res://scripts/boards.gd")

var doc: RefCounted
var is_assembly := false
var state := "boot"
var mode := ""
var last_saved := ""

var player: Node3D
var view: Node3D
var tools: Node
var hud: CanvasLayer
var _menu_page := ""  # "", "units" or "material": which page of the pause menu shows
var board: Node3D  # whiteboard.gd: the messages, standing in the room
var boards: Node3D  # boards.gd: the whiteboards the player adds, and carrying any board
var wheel: Control
var touch: Control
var cmap: CanvasLayer
var title: CanvasLayer
var splash: CanvasLayer
var tutorial: Node3D
var challenge: Node3D
var level := 0
var sketcher: Node3D
var dialog: CanvasLayer
var numpad: CanvasLayer
var updater: Node
var _update_checked := false

var _aim := {}
var _autosave_t := 0.0
var _orbit_t := 0.0
var _wheel_from_button := false
var _cmap_from_menu := false


func _ready() -> void:
	if "--self-check" in OS.get_cmdline_user_args():
		# Packaged-build check (CI): the CAD extension and Open CASCADE loaded and can build a part.
		var ok := ClassDB.class_exists("CadPart") and ClassDB.instantiate("CadPart") != null
		print("SELF-CHECK ", "OK" if ok else "FAIL: the CAD extension did not load")
		print("FFMPEG ", Whiteboard.ffmpeg_path() if Whiteboard.ffmpeg_path() != "" else "none")
		get_tree().quit(0 if ok else 1)
		return
	UiTheme.apply()
	UiTheme.apply_scale(get_tree(), UiTheme.saved_scale_choice())
	for dir in [PROJECTS, EXPORTS, RECOVERY.get_base_dir()]:
		DirAccess.make_dir_recursive_absolute(dir)
	if OS.has_feature("mobile"):
		Actions.last_device = "touch"

	hud = preload("res://scripts/hud.gd").new()
	add_child(hud)
	if not ClassDB.class_exists(&"CadPart"):
		hud.toast("The CAD extension did not load. Build it first: see docs/BUILDING.md")
		push_error("FPS-CAD: CadPart class missing; the GDExtension in godot/bin did not load.")
		return
	hud.visible = false

	view = preload("res://scripts/model_view.gd").new()
	add_child(view)
	board = Whiteboard.new()
	add_child(board)
	hud.board = board
	boards = preload("res://scripts/boards.gd").new()
	boards.game = self
	add_child(boards)
	player = preload("res://scripts/player.gd").new()
	add_child(player)
	player.cast = _cast
	player.growth_blocked.connect(_on_growth_blocked)
	player.input_enabled = false
	tools = ToolsScript.new()
	add_child(tools)
	tools.view = view
	tools.player = player
	tools.hud = hud
	tools.changed.connect(_on_model_changed)
	tools.tool_switched.connect(func(_i):
		boards.drop()  # changing tool sets a carried board down
		_show_tool()
	)
	tools.board_tool.connect(boards.act)
	tools.sketch_requested.connect(_on_sketch_requested)
	tools.feature_requested.connect(_on_feature_requested)
	tools.reference_requested.connect(_on_reference_requested)
	sketcher = Sketcher.new()
	sketcher.game = self
	add_child(sketcher)
	sketcher.ended.connect(_on_sketch_ended)
	sketcher.changed.connect(_show_tool)
	numpad = preload("res://scripts/number_pad.gd").new()
	add_child(numpad)
	dialog = preload("res://scripts/feature_dialog.gd").new()
	dialog.game = self
	add_child(dialog)
	dialog.closed.connect(_on_dialog_closed)

	wheel = preload("res://scripts/tool_wheel.gd").new()
	var wheel_layer := CanvasLayer.new()
	wheel_layer.layer = 5
	add_child(wheel_layer)
	wheel_layer.add_child(wheel)
	wheel.picked.connect(_wheel_pick)

	touch = preload("res://scripts/touch_controls.gd").new()
	hud.add_child(touch)
	touch.player = player
	touch.action_pressed.connect(_on_touch_pressed)
	touch.action_released.connect(_on_touch_released)

	cmap = preload("res://scripts/controller_map.gd").new()
	add_child(cmap)
	cmap.closed.connect(_on_cmap_closed)
	title = preload("res://scripts/title.gd").new()
	add_child(title)
	title.chosen.connect(_on_title_chosen)

	updater = preload("res://scripts/updater.gd").new()
	add_child(updater)
	updater.update_available.connect(_on_update_available)
	updater.checked.connect(_on_update_checked)
	updater.before_install.connect(_autosave)

	hud.request.connect(_on_hud_request)
	Actions.device_changed.connect(_on_device_changed)
	_on_device_changed(Actions.last_device)

	_load_background()
	if "--skip-splash" in OS.get_cmdline_user_args():
		_show_title()
	else:
		state = "splash"
		splash = preload("res://scripts/splash.gd").new()
		add_child(splash)
		splash.finished.connect(_show_title)


# ---------- states and modes ----------

## Stands the message board on the ground ahead of the player and a little to the left, turned
## to face them, avoiding parts in the way. glide: slide it there from where it was.
func place_board_ahead(glide: bool) -> void:
	var fwd := Vector3(-sin(player.yaw), 0, -cos(player.yaw))
	var left := Vector3(fwd.z, 0, -fwd.x)
	board.active = false  # look past the board where it stands now
	for spot in [[2.8, 1.6], [2.8, -1.6], [3.6, 0.0], [2.2, 2.4], [2.2, -2.4], [4.5, 1.6]]:
		var at: Vector3 = player.feet + fwd * spot[0] + left * spot[1]
		var down: Dictionary = _cast(Vector3(at.x, player.feet.y + 3.0, at.z), Vector3.DOWN, 50.0)
		var y: float = down.point.y if not down.is_empty() and down.get("env", false) else player.feet.y
		if not down.is_empty() and not down.get("env", false):
			continue  # a part is there
		board.place(Vector3(at.x, y, at.z), player.eye_position(), glide)
		return
	board.place(player.feet + fwd * 2.8 + left * 1.6, player.eye_position(), glide)


## The pavilion, seen from a slow orbit behind the splash and title screens.
func _load_background() -> void:
	var part = ClassDB.instantiate(&"CadPart")
	part.make_sample()
	view.room.set_table(false)
	_open(part, false)
	_spawn(Vector3(0, 2.5, 18), 0.0, 1.0)
	player.fly = true


func _show_title() -> void:
	_close_editors()
	splash = null
	state = "title"
	mode = ""
	_end_challenge()
	if tutorial != null:
		tutorial.queue_free()
		tutorial = null
	hud.set_menu(false)
	hud.set_panel(false)
	hud.visible = false
	board.hide_board()
	boards.clear()
	wheel.close(false)
	player.input_enabled = false
	if doc == null or is_assembly or doc.get_part_name() != "Pavilion":
		_load_background()
	player.fly = true
	title.show_title(Tutorial.is_done())
	if not _update_checked:
		_update_checked = true
		updater.check_on_launch()


func _start_mode(m: String, challenge_index := 0) -> void:
	state = "play"
	mode = m
	_close_editors()
	title.visible = false
	hud.visible = true
	player.fly = false
	_end_challenge()
	if tutorial != null:
		tutorial.queue_free()
		tutorial = null
	# The wooden table is for free build and challenges; elsewhere parts stand on the room floor.
	view.room.set_table(m == "free" or m == "challenge")
	board.clear_card()
	board.set_status("")
	var d: RefCounted
	match m:
		"training":
			d = ClassDB.instantiate(&"CadPart")
			d.make_training()
			_open(d, false)
			_spawn(Vector3(0, 0.05, 14), 0.0, 1.0)
			tutorial = Tutorial.new()
			tutorial.game = self
			add_child(tutorial)
			tutorial.finished.connect(_on_tutorial_finished)
			tutorial.start()
		"challenge":
			level = challenge_index
			d = ClassDB.instantiate(&"CadPart")
			d.new_blank("My copy", "mm")
			challenge = Challenge.new()
			challenge.game = self
			add_child(challenge)
			challenge.finished.connect(_on_challenge_finished)
			challenge.start(level)
			_open(d, false)
			var sp: Dictionary = challenge.spawn(view.room.top, view.room.floor_y())
			_spawn(sp.feet, sp.yaw, sp.size, sp.pitch)
		"new":
			d = ClassDB.instantiate(&"CadPart")
			d.new_blank("Part 1", "mm")
			_open(d, false)
			_spawn(Vector3(0, 0, 4), 0.0, 1.0)
		"assembly":
			d = ClassDB.instantiate(&"CadAssembly")
			d.make_sample()
			_open(d, true)
			_spawn(Vector3(0, 0, 0.35), 0.0, 0.05)  # the pin plate is 200 mm across
		_:
			# Free build: a desk organiser on the table, walking up to it.
			d = ClassDB.instantiate(&"CadPart")
			d.make_desk_sample()
			_open(d, false)
			_spawn(Vector3(0, view.room.floor_y(), view.room.top.end.y + 1.3), 0.0, 1.0, -0.5)
	# The message board: beside the table when there is one, else set down ahead of the player
	# (the training course moves it to each objective).
	if view.room.has_table:
		var fy: float = view.room.floor_y()
		board.place(Vector3(-1.45, fy, -0.25), Vector3(0, fy, view.room.top.end.y + 1.3))
	elif m != "training":
		place_board_ahead(false)
	boards.load_from(doc)  # the part's own boards, and the message board where it was left
	tools.reset()
	if m == "new" or m == "challenge":
		tools.set_tool_id("sketch")
		hud.toast("A blank part. Aim at the ground and press %s to start a sketch on the Top plane" % Actions.prompt(&"primary"))
	hud.set_menu_items(_menu_items())
	if Actions.last_device == "keyboard":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _toggle_menu() -> void:
	if not hud.menu_open and _menu_page != "":
		_menu_page = ""
		hud.set_menu_items(_menu_items())
	hud.set_menu(not hud.menu_open)


## From the Units or Material page back to the pause menu, on the entry that opened it.
func _menu_back() -> void:
	var was := _menu_page
	_menu_page = ""
	hud.set_menu_items(_menu_items())
	hud.focus_menu_action(was + "_menu")


func _units_items() -> Array:
	var items := []
	var now := Units.system_of(hud.units, doc.get_mass_units())
	for s in Units.SYSTEMS:
		items.append(["%s%s  ·  %s" % [s.id, "  ✓" if s == now else "", s.name], "units:" + s.id])
	items.append(["Back", "menu_back"])
	return items


func _material_items() -> Array:
	var items := []
	var mu: String = doc.get_mass_units()
	var now: String = doc.get_material()
	for m in doc.material_library():
		items.append(["%s%s  ·  %s" % [m.name, "  ✓" if m.name == now else "", Units.density_text(float(m.density), hud.units, mu)],
			"material:" + String(m.name)])
	items.append(["Custom density…" + ("  ✓  " + Units.density_text(doc.get_density(), hud.units, mu) if now == "Custom" else ""),
		"material_custom"])
	items.append(["Back", "menu_back"])
	return items


func _apply_units(id: String) -> void:
	var s := {}
	for sys in Units.SYSTEMS:
		if sys.id == id:
			s = sys
	if s.is_empty() or doc == null or not doc.has_method("set_units"):
		return
	if sketcher.active:
		hud.toast("Finish the sketch before changing units")
		return
	var r: Dictionary = doc.set_units(s.length, s.mass)
	if not r.ok:
		hud.toast(r.message)
		return
	hud.units = s.length
	_after_part_settings()
	_menu_back()
	hud.toast("Units: %s (%s) · sizes stay as they are" % [s.id, s.name])


func _apply_material(name: String) -> void:
	if doc == null or not doc.has_method("set_material"):
		return
	var r: Dictionary = doc.set_material(name, 0.0)
	if not r.ok:
		hud.toast(r.message)
		return
	_after_part_settings()
	_menu_back()
	var lines: PackedStringArray = Boards.material_lines(doc.material_info(), hud.units, doc.get_mass_units())
	var parts := PackedStringArray()
	for l in lines:
		parts.append(l.trim_prefix("Material   ").replace("   ·   ", " · ").replace("   ", " · "))
	hud.toast("Material: " + " · ".join(parts))


## After the units or material change: redraw what shows them and save.
func _after_part_settings() -> void:
	view.set_appearance(doc.material_info())
	hud.refresh_panel()
	boards.refresh_properties()
	tools.model_changed()
	_show_tool()
	_autosave()


func _menu_items() -> Array:
	var items := [["Resume", "resume"]]
	if sketcher != null and sketcher.active:
		items += [["Finish sketch", "finish_sketch"], ["Discard sketch", "discard_sketch"]]
	items.append(["Controls", "controls"])
	items.append(["Interface size: " + UiTheme.scale_label(UiTheme.saved_scale_choice()), "ui_scale"])
	if updater != null and updater.supported():
		if not updater.latest.is_empty():
			items.insert(1, ["Update to build %d" % int(updater.latest.get("build", 0)), "update"])
		items.append(["Check for updates", "check_updates"])
		items.append(["Update checks at launch: " + ("On" if updater.enabled() else "Off"), "toggle_update_checks"])
	if mode == "training":
		items.append(["Restart training", "restart_training"])
	if mode == "challenge":
		items += [["Restart challenge", "restart_challenge"], ["Challenge list", "challenge_list"]]
	if doc != null and doc.has_method("material_info") and not is_assembly:
		items += [["Units: " + Units.system_label(hud.units, doc.get_mass_units()), "units_menu"],
			["Material: " + doc.get_material(), "material_menu"]]
	items += [
		["Save", "save"], ["Open last saved", "open_saved"],
		["Export STEP", "export_step"], ["Export IGES", "export_iges"],
		["Export STL", "export_stl"], ["Export 3MF", "export_3mf"],
		["Exit to title", "title"], ["Quit", "quit"],
	]
	return items


func _spawn(feet: Vector3, yaw: float, size: float, pitch := -0.12) -> void:
	player.feet = feet
	player.yaw = yaw
	player.pitch = pitch
	player.set_size_now(size)


func _on_growth_blocked() -> void:
	if state == "play":
		hud.toast("No room to grow here · step into the open, or turn on Fly to pass through parts")
		Input.start_joy_vibration(0, 0.25, 0.1, 0.08)


func _on_update_checked(message: String) -> void:
	if hud.visible:
		hud.toast(message)


func _on_update_available(info: Dictionary) -> void:
	title.show_update(info)
	if state == "play":
		hud.set_menu_items(_menu_items())
		hud.toast("Update available: build %d · in the pause menu" % int(info.get("build", 0)))


func _on_title_chosen(id: String) -> void:
	if id.begins_with("challenge:"):
		_start_mode("challenge", int(id.get_slice(":", 1)))
		return
	match id:
		"challenges":
			_show_levels()
		"update":
			updater.install()
		"controls":
			cmap.open()
		"quit":
			get_tree().quit()
		_:
			_start_mode(id)


func _on_tutorial_finished(choice: String) -> void:
	match choice:
		"free":
			_start_mode("free")
		"title":
			_show_title()
		_:
			if tutorial != null:
				tutorial.queue_free()
				tutorial = null
			mode = "free"
			hud.set_menu_items(_menu_items())


func _on_cmap_closed() -> void:
	if state == "title":
		title.focus_default()
	elif _cmap_from_menu:
		hud.set_menu(true)
	_cmap_from_menu = false


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
	view.set_appearance(doc.material_info() if doc.has_method("material_info") else {})
	hud.refresh_panel()
	boards.load_from(doc)
	_show_tool()


func _on_model_changed() -> void:
	view.refresh()
	tools.model_changed()
	boards.refresh_properties()
	if hud.panel_open:
		hud.refresh_panel()
	if challenge != null:
		challenge.on_model_changed()


func _end_challenge() -> void:
	if challenge != null:
		challenge.queue_free()
		challenge = null


func _on_challenge_finished(choice: String) -> void:
	match choice:
		"next":
			_start_mode("challenge", level + 1)
		"retry":
			_start_mode("challenge", level)
		"list":
			_show_title()
			_show_levels()
		_:
			_show_title()


func _show_levels() -> void:
	var list: Array = ClassDB.instantiate(&"CadPart").challenge_list()
	var rows := []
	for i in list.size():
		rows.append({name = list[i].name, brief = list[i].brief, locked = i >= Challenge.unlocked(),
			best = Challenge.best_time(list[i].id)})
	title.show_levels(rows)


## For the feature panel and other helpers: redraw after the document changed.
func on_model_changed() -> void:
	_on_model_changed()


## Leaves sketch mode and the feature panel without keeping their changes.
func _close_editors() -> void:
	if numpad != null and numpad.visible:
		numpad.close()
	if dialog != null and dialog.visible:
		dialog.cancel()
	if sketcher != null and sketcher.active:
		sketcher.discard()


# ---------- sketches and features ----------

func _on_sketch_requested(plane: Dictionary, plane_name: String, edit_id: String) -> void:
	if not sketcher.begin(plane, plane_name, edit_id):
		hud.toast("That sketch can no longer be opened")
		return
	view.hidden_sketch = edit_id
	view.refresh()
	view.show_plane({}, 0.0)
	view.clear_highlight()
	hud.set_menu_items(_menu_items())
	_show_tool()
	hud.toast("Sketching on %s · move to pan, %s / %s zoom · %s finishes · %s free look" % [
		sketcher.sketch.get("planeName", "the plane"), Actions.prompt(&"grow"), Actions.prompt(&"shrink"),
		Actions.prompt(&"finish"), Actions.prompt(&"normal_to")])


func _on_sketch_ended(feature_id: String, committed: bool) -> void:
	view.hidden_sketch = ""
	_on_model_changed()
	hud.set_menu_items(_menu_items())
	hud.set_status("")
	if committed and feature_id != "":
		# Like a desktop CAD tool: finishing a sketch leads straight to making it solid.
		tools.set_tool_id("extrude")
		hud.toast("Sketch done. Extrude is ready: aim at the sketch and press %s" % Actions.prompt(&"primary"))
	else:
		hud.toast("Sketch closed without changes")
		_show_tool()


## A new plane, axis, point or coordinate system: the feature panel when it has sizes to set,
## else straight into the history.
func _on_reference_requested(type: String, params: Dictionary) -> void:
	if dialog.wants_panel(type, params):
		if dialog.open_reference(type, params):
			_show_tool()
	else:
		tools.insert_reference(type, params)


func _on_feature_requested(type: String, sketch_id: String, op: String) -> void:
	if dialog.open_new(type, sketch_id, op):
		_show_tool()


func _on_dialog_closed(ok: bool, feature_id: String) -> void:
	if ok:
		var fname := "Feature"
		for f in doc.get_features():
			if f.id == feature_id:
				fname = f.name
		hud.toast("%s updated" % fname if dialog.editing else "%s added" % fname)
	else:
		hud.toast("Cancelled")
	_on_model_changed()
	_show_tool()


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
	var r: Dictionary = doc.export_file(path, "in" if hud.units == "ft" else hud.units if hud.units in ["mm", "cm", "m", "in"] else "mm")
	hud.toast(("Exported %s · %s" % [path, r.message]) if r.ok else ("Export failed: " + r.message))


func _autosave() -> void:
	if doc == null or state != "play":
		return
	var path := RECOVERY + (".fpasm" if is_assembly else ".fpprt")
	doc.save_file(ProjectSettings.globalize_path(path))


func _notification(what: int) -> void:
	# Android may stop a backgrounded app without warning, so save on the way out.
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_autosave()


# ---------- frame ----------

## What the player collides with and stands on: the model, the table and the room floor.
func _cast(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	if doc == null:
		return {}
	var hit: Dictionary = doc.pick(origin, dir, max_distance)
	if challenge != null:  # the target part is solid too
		var th: Dictionary = challenge.pick(origin, dir, max_distance)
		if not th.is_empty() and (hit.is_empty() or th.distance < hit.distance):
			hit = th
	var bh: Dictionary = board.cast(origin, dir, max_distance)
	if not bh.is_empty() and (hit.is_empty() or bh.distance < hit.distance) and bh.board != boards.carried():
		hit = bh
	var xh: Dictionary = boards.cast_extra(origin, dir, max_distance)
	if not xh.is_empty() and (hit.is_empty() or xh.distance < hit.distance):
		hit = xh
	var env: Dictionary = view.room.cast(origin, dir, max_distance)
	if not env.is_empty() and (hit.is_empty() or env.distance < hit.distance):
		return env
	return hit


func _aim_hit() -> Dictionary:
	var o: Vector3 = player.eye_position()
	var d: Vector3 = player.aim_direction()
	var hit: Dictionary = doc.pick(o, d, player.camera.far)
	if challenge != null:
		var th: Dictionary = challenge.pick(o, d, player.camera.far)
		if not th.is_empty() and (hit.is_empty() or th.distance < hit.distance):
			hit = th
	# The table and the floor count as "ground" for the tools (sketch on the Top plane, place on it).
	var env: Dictionary = view.room.cast(o, d, player.camera.far)
	if not env.is_empty() and (hit.is_empty() or env.distance < hit.distance):
		env.ground = true
		return env
	return hit


## True while something covers the view and should get the controller instead of the player.
func modal_open() -> bool:
	var tutorial_card: bool = (tutorial != null and tutorial.is_open_card()) or (challenge != null and challenge.is_open_card())
	return hud.menu_open or hud.panel_open or cmap.visible or tutorial_card or numpad.visible or updater.busy()


func _process(dt: float) -> void:
	if doc == null:
		return
	view.follow(player.camera.global_position, player.size)
	player.floor_limit = view.room.floor_y()
	if state != "play":
		_orbit(dt)
		if state == "title" and not cmap.visible and not updater.busy() and Actions.last_device == "controller":
			title.keep_focus()
		_update_mouse_mode()
		return
	var playing: bool = not modal_open()
	player.input_enabled = playing and not wheel.visible
	player.limited = dialog.visible
	_aim = _aim_hit()
	if playing and not dialog.visible:
		_gameplay_input()
	if sketcher.active:
		if playing:
			sketcher.update()
		hud.set_status(sketcher.status_text(), Color("f2f5f8") if sketcher.defined() else Color("7cc4ff"))
	else:
		tools.update(_aim if playing and not dialog.visible else {}, dt)
		boards.update_carry()
	hud.set_readout(player.size, player.grid_step(), player.snap_step(), player.fly, player.feet)
	hud.set_measure(tools.measure_text())
	touch.set_fly(player.fly)
	_keep_focus()
	_autosave_t += dt
	if _autosave_t > AUTOSAVE_SECONDS:
		_autosave_t = 0.0
		_autosave()
	_update_mouse_mode()


## Slow orbit around the model behind the splash and title screens.
func _orbit(dt: float) -> void:
	_orbit_t += dt * 0.08
	var r := 18.0
	player.feet = Vector3(sin(_orbit_t) * r, 2.5, cos(_orbit_t) * r)
	player.yaw = atan2(player.feet.x, player.feet.z)
	player.pitch = -0.14


## A controller always needs something focused in an open menu, or A and the D-pad do nothing.
func _keep_focus() -> void:
	if Actions.last_device != "controller" or cmap.visible:
		return
	if numpad.visible:
		numpad.keep_focus()
	elif hud.menu_open:
		UiTheme.keep_focus(hud.menu_control())
	elif tutorial != null and tutorial.is_open_card():
		tutorial.keep_focus()
	elif challenge != null and challenge.is_open_card():
		challenge.keep_focus()
	elif hud.panel_open:
		UiTheme.keep_focus(hud.panel_control())


## The wheel's tree: sketch tools in sketch mode, else the modelling tools (tool_wheel.gd).
func _wheel_tree() -> Array:
	return sketcher.wheel_tree() if sketcher.active else tools.wheel_tree()


func _wheel_current() -> int:
	return sketcher.index if sketcher.active else tools.index


## Opens the wheel; from_button means it stays open until something is picked (touch, the HUD,
## number keys) instead of closing when the wheel button is let go. group opens that group.
func _open_wheel(from_button: bool, group := -1) -> void:
	_wheel_from_button = from_button
	var title := "SKETCH TOOLS" if sketcher.active else "TOOLS"
	var how := "aim, then %s" % Actions.prompt(&"ui_accept")
	if not from_button:
		how = ("right stick: group · left stick: tool · let go to pick" if Actions.last_device == "controller"
			else "mouse: group, then further out: tool · click or let go to pick")
	wheel.setup(_wheel_tree(), title, how + "   ·   %s back" % Actions.prompt(&"ui_cancel"))
	wheel.open(_wheel_current())
	if group >= 0:
		wheel.enter(group)
		_wheel_from_button = true


func _wheel_pick(value: int) -> void:
	if value < 0:
		return
	if sketcher.active:
		sketcher.set_tool(value)
		_show_tool()
	else:
		tools.set_tool(value)


## Number keys pick the wheel's inner-ring entries: a tool directly, or a group's branch.
func _wheel_shortcut(i: int) -> void:
	var tree := _wheel_tree()
	if i >= tree.size():
		return
	if tree[i].has("children"):
		_open_wheel(true, i)
	else:
		_wheel_pick(int(tree[i].value))


func _gameplay_input() -> void:
	if wheel.visible:
		# Right stick: the group. Left stick (or WASD): the tool on its branch.
		wheel.aim(Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down"))
		wheel.aim_branch(Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back"))
		if _wheel_from_button and Input.is_action_just_pressed(&"tool_wheel"):
			wheel.close()
			return
		var released: bool = not _wheel_from_button and Input.is_action_just_released(&"tool_wheel")
		# A click picks too while the mouse is captured (holding Q); with the pointer showing, the
		# wheel's buttons take clicks themselves.
		var pressed: bool = Input.is_action_just_pressed(&"ui_accept") \
			or (Input.is_action_just_pressed(&"primary")
				and (Actions.last_device != "keyboard" or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED))
		if released or pressed:
			var r: int = wheel.commit(released)
			if r == ToolWheel.ENTERED:
				_wheel_from_button = true  # a group opened: aim at its tools and press to pick
			else:
				_wheel_pick(r)
		return
	if Input.is_action_just_pressed(&"tool_wheel"):
		_open_wheel(false)
		return
	if sketcher.active:
		_sketch_input()
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
			_wheel_shortcut(i)
	if boards.carrying():
		# Carrying a board: the D-pad (or +/- and the mouse wheel) turns and resizes it.
		if Input.is_action_just_pressed(&"undo"):
			boards.turn(1.0)
		if Input.is_action_just_pressed(&"redo"):
			boards.turn(-1.0)
		if Input.is_action_just_pressed(&"grow"):
			boards.rescale(1.0)
		if Input.is_action_just_pressed(&"shrink"):
			boards.rescale(-1.0)
	elif Input.is_action_just_pressed(&"redo"):
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
		hud.toast("Nothing to finish. Pick Sketch from the wheel to start a sketch")
	if Input.is_action_just_pressed(&"screenshot"):
		_screenshot()


## Input while a sketch is open: the triggers draw, X finishes, Y switches between the sketch view and free look,
## the D-pad's left and right undo and redo inside the sketch.
func _sketch_input() -> void:
	var mouse_free: bool = Actions.last_device == "keyboard" and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	if Input.is_action_just_pressed(&"primary") and not mouse_free:
		sketcher.press(true)
	if Input.is_action_just_pressed(&"secondary") and not mouse_free:
		sketcher.press(false)
	if Input.is_action_just_pressed(&"context_wheel"):
		sketcher.cycle_option()
		_show_tool()
	for i in 9:
		if Input.is_action_just_pressed(StringName("tool_%d" % (i + 1))):
			_wheel_shortcut(i)
	if Input.is_action_just_pressed(&"finish"):
		sketcher.finish()
	if Input.is_action_just_pressed(&"inspect"):
		sketcher.toggle_view()
	if Input.is_action_just_pressed(&"redo"):
		if sketcher.redo():
			hud.toast("Redo (sketch)")
	elif Input.is_action_just_pressed(&"undo") and not Input.is_key_pressed(KEY_SHIFT):
		if sketcher.undo():
			hud.toast("Undo (sketch)")
	if Input.is_action_just_pressed(&"screenshot"):
		_screenshot()


func _unhandled_input(event: InputEvent) -> void:
	if state == "title":
		if event.is_action_pressed(&"controller_map") and not cmap.visible:
			cmap.open()
			get_viewport().set_input_as_handled()
		return
	if state != "play" or cmap.visible or numpad.visible or updater.busy():
		return  # the splash, the controls map, the number pad and the updater handle their own input
	if dialog.visible and not hud.menu_open:
		if dialog.handle(event):
			get_viewport().set_input_as_handled()
		return
	if boards.carrying() and event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		boards.turn(1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"controller_map"):
		hud.set_panel(false)
		_cmap_from_menu = hud.menu_open
		hud.set_menu(false)
		wheel.close(false)
		cmap.open()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_cancel"):
		var closed := true
		if hud.menu_open and _menu_page != "":
			_menu_back()  # from Units or Material back to the pause menu
		elif hud.menu_open:
			hud.set_menu(false)
		elif hud.panel_open:
			hud.set_panel(false)
		elif wheel.visible:
			wheel.back()
		elif sketcher.active and sketcher.has_pending() and event.is_action_pressed(&"crouch"):
			sketcher.cancel_pending()  # B drops the line or shape being drawn
		else:
			closed = false  # B with nothing open is crouch / fly down; Esc falls through to the menu
		if closed:
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed(&"menu"):
		if tutorial != null and tutorial.is_open_card():
			return
		if hud.panel_open:
			hud.set_panel(false)
		else:
			_toggle_menu()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"model_panel"):
		hud.toggle_panel()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and not modal_open() \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and Actions.last_device == "keyboard":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED  # first click on the view grabs the mouse
		get_viewport().set_input_as_handled()


## Holding Q, the mouse is captured and steers the wheel. This runs before the GUI: the wheel's
## full-screen layer sits under the (hidden) pointer and would take the motion otherwise.
func _input(event: InputEvent) -> void:
	if wheel != null and wheel.visible and event is InputEventMouseMotion \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and state == "play":
		wheel.point(event.relative)
		get_viewport().set_input_as_handled()


func _update_mouse_mode() -> void:
	var want_free: bool = state != "play" or modal_open() or Actions.last_device == "touch" \
		or (wheel.visible and _wheel_from_button) or dialog.visible
	if want_free and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _screenshot() -> void:
	DirAccess.make_dir_recursive_absolute("user://screenshots")
	var path := "user://screenshots/%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
	get_viewport().get_texture().get_image().save_png(path)
	hud.toast("Screenshot saved to " + ProjectSettings.globalize_path(path))


# ---------- UI requests ----------

func _show_tool() -> void:
	if sketcher != null and sketcher.active:
		var t: Dictionary = sketcher.tool().duplicate()
		t.name = "Sketch · " + t.name
		hud.set_tool(t, sketcher.option())
		hud.set_status(sketcher.status_text())
		return
	if dialog != null and dialog.visible:
		hud.set_tool({name = "Feature", pri = "change the focused value", alt = "change it back"}, "")
		hud.set_status("")
		return
	hud.set_status("")
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
	if state == "play":
		hud.set_menu_items(_menu_items())  # prompts in the menu follow the device


func _on_touch_pressed(name: String) -> void:
	if state != "play" or dialog.visible:
		return
	match name:
		"primary":
			if sketcher.active:
				sketcher.press(true)
			else:
				tools.press(true)
		"secondary":
			if sketcher.active:
				sketcher.press(false)
			else:
				tools.press(false)
		"wheel":
			_open_wheel(true)


func _on_touch_released(name: String) -> void:
	if name != "wheel":
		tools.release()


func _on_hud_request(action: String, arg: Variant) -> void:
	if action.begins_with("units:"):
		_apply_units(action.substr(6))
		return
	if action.begins_with("material:"):
		_apply_material(action.substr(9))
		return
	match action:
		"units_menu":
			_menu_page = "units"
			hud.set_menu_items(_units_items(), "UNITS")
			hud.focus_menu_action("units:" + Units.system_of(hud.units, doc.get_mass_units()).get("id", ""))
		"material_menu":
			_menu_page = "material"
			hud.set_menu_items(_material_items(), "MATERIAL")
			hud.focus_menu_action("material:" + doc.get_material())
		"menu_back":
			_menu_back()
		"material_custom":
			_menu_back()
			hud.set_menu(false)
			var mu: String = doc.get_mass_units()
			var unit_text: String = Units.density_text(1.0, hud.units, mu).get_slice(" ", 1)
			var now: String = Units.density_text(doc.get_density(), hud.units, mu).get_slice(" ", 0).replace(",", "")
			numpad.ask("Density (%s)" % unit_text, now, "The part's mass uses it; other properties stay unknown",
				func(text: String) -> void:
					var v := text.replace(",", "").to_float()
					var r: Dictionary = doc.set_material("Custom", Units.density_from(v, hud.units, mu))
					if not r.ok:
						hud.toast(r.message)
						return
					_after_part_settings()
					hud.toast("Material: Custom · %s" % Units.density_text(doc.get_density(), hud.units, mu))
			)
		"open_wheel":
			if state == "play" and not dialog.visible:
				_open_wheel(true)
		"undo":
			if sketcher.active:
				sketcher.undo()
			elif doc.has_method("undo") and doc.undo():
				_on_model_changed()
		"redo":
			if sketcher.active:
				sketcher.redo()
			elif doc.has_method("redo") and doc.redo():
				_on_model_changed()
		"finish_sketch":
			hud.set_menu(false)
			sketcher.finish()
		"discard_sketch":
			hud.set_menu(false)
			sketcher.discard()
		"edit_sketch":
			hud.set_panel(false)
			_on_sketch_requested({}, "", arg)
		"edit_feature":
			hud.set_panel(false)
			for f in doc.get_features():
				if f.id == arg and dialog.open_edit(f):
					_show_tool()
		"fly":
			player.fly = not player.fly
			hud.toast("Fly on · through walls" if player.fly else "Walking")
		"panel":
			hud.toggle_panel()
		"menu":
			_toggle_menu()
		"controls":
			_cmap_from_menu = hud.menu_open
			hud.set_menu(false)
			hud.set_panel(false)
			cmap.open()
		"resume":
			hud.set_menu(false)
		"update":
			hud.set_menu(false)
			_autosave()
			updater.install()
		"check_updates":
			hud.toast("Checking for updates…")
			updater.check(true)
		"toggle_update_checks":
			updater.set_enabled(not updater.enabled())
			hud.set_menu_items(_menu_items())
			hud.focus_menu_action("toggle_update_checks")
		"ui_scale":
			var choices: Array = UiTheme.SCALE_CHOICES
			var next: float = choices[(choices.find(UiTheme.saved_scale_choice()) + 1) % choices.size()]
			UiTheme.apply_scale(get_tree(), next, true)
			await get_tree().process_frame  # let the layout settle at the new size
			hud.set_menu_items(_menu_items())
			hud.focus_menu_action("ui_scale")
			hud.toast("Interface size " + UiTheme.scale_label(next))
		"restart_challenge":
			hud.set_menu(false)
			_start_mode("challenge", level)
		"challenge_list":
			hud.set_menu(false)
			_show_title()
			_show_levels()
		"restart_training":
			hud.set_menu(false)
			_close_editors()
			_start_mode("training")
		"title":
			_autosave()
			_show_title()
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
			_close_editors()
			_open(d, last_saved.ends_with(".fpasm"))
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
