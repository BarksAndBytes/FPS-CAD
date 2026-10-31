extends Node3D
## The training course: a guided run through movement, size, the tool wheel and the main tools on
## the "Training course" part from the CAD core. Each objective checks the real game state (where
## the player stands, how big they are, what the model's parameters are), so it cannot be skipped
## by pressing buttons blindly.
##
## Course layout in Godot space (Y up, start at z = +14, walking toward -z):
##   z = 9    walk marker        z = 5..7   80 cm step        z = -0.5..0.5  wall, 30 cm tunnel
##   x = 3, z = -5   lift block (1 m)       x = -3, z = -5   build pad (sketch and extrude here)

signal finished(choice: String)  # "stay", "free", "title"

const UiTheme := preload("res://scripts/ui_theme.gd")
const COURSE := ["Start pad", "Step", "Wall", "Crawl tunnel", "Lift block", "Build pad"]
const SETTINGS := "user://settings.cfg"

var game: Node  # main.gd
var step := -1
var steps: Array = []
var _look_total := 0.0
var _last_yaw := 0.0
var _map_seen := false
var _done_t := -1.0
var _t := 0.0

var _layer := CanvasLayer.new()
var _card := PanelContainer.new()
var _count := Label.new()
var _heading := Label.new()
var _body := Label.new()
var _bar := ColorRect.new()
var _bar_back := ColorRect.new()
var _end := PanelContainer.new()
var _marker := Node3D.new()
var _ring := MeshInstance3D.new()
var _beam := MeshInstance3D.new()


func _ready() -> void:
	_build_steps()
	_build_ui()
	_build_marker()


func start() -> void:
	step = -1
	_look_total = 0.0
	_last_yaw = game.player.yaw
	_map_seen = false
	_end.visible = false
	_card.visible = true
	_advance()


# ---------- objectives ----------

func _build_steps() -> void:
	# Each step names a text method (prompts follow the device in use) and a check method.
	steps = [
		{title = "Look around", text = "_text_look", check = "_check_look"},
		{title = "Walk", text = "_text_walk", check = "_check_walk", marker = Vector3(0, 0, 9)},
		{title = "Jump", text = "_text_jump", check = "_check_jump", marker = Vector3(0, 0.8, 6)},
		{title = "Shrink", text = "_text_shrink", check = "_check_shrink"},
		{title = "Crawl through", text = "_text_crawl", check = "_check_crawl", marker = Vector3(0, 0, -1.4)},
		{title = "Grow back", text = "_text_grow", check = "_check_grow"},
		{title = "Pick a tool", text = "_text_wheel", check = "_check_wheel"},
		{title = "Push a face", text = "_text_push", check = "_check_push", marker = Vector3(3, 0, -5)},
		{title = "Start a sketch", text = "_text_sketch", check = "_check_sketch", marker = Vector3(-3, 0.05, -5)},
		{title = "Draw a rectangle", text = "_text_rect", check = "_check_rect"},
		{title = "Finish the sketch", text = "_text_finish", check = "_check_finish"},
		{title = "Extrude it", text = "_text_extrude", check = "_check_extrude"},
		{title = "Measure", text = "_text_measure", check = "_check_measure"},
		{title = "Controls", text = "_text_map", check = "_check_map"},
	]


func _p(action: StringName) -> String:
	return Actions.prompt(action)


func _text_look() -> String:
	match Actions.last_device:
		"keyboard": return "Move the mouse to look around."
		"touch": return "Push the stick at the bottom right to look around. Dragging anywhere on the right side works too."
	return "Use the right stick to look around."


func _check_look() -> bool:
	return _look_total > 3.0


func _text_walk() -> String:
	return "Walk to the orange marker (%s)." % _p(&"move")


func _check_walk() -> bool:
	return _near_xz(Vector3(0, 0, 9), 1.2)


func _text_jump() -> String:
	return "This ledge is 80 cm high, too tall to step onto. Press %s to jump up." % _p(&"jump")


func _check_jump() -> bool:
	var f: Vector3 = game.player.feet
	return f.y > 0.7 and absf(f.x) < 2.5 and f.z > 5.0 and f.z < 7.0


func _text_shrink() -> String:
	return ("The wall ahead has a 30 cm tunnel. Shrink until you are shorter than that: %s "
		+ "(a tap halves your size, holding keeps shrinking). Your height is at the top left.") % _p(&"shrink")


func _check_shrink() -> bool:
	return game.player.size * 1.75 < 0.3


func _text_crawl() -> String:
	return "Walk through the tunnel to the other side of the wall."


func _check_crawl() -> bool:
	var f: Vector3 = game.player.feet
	return f.z < -0.7 and absf(f.x) < 1.5


func _text_grow() -> String:
	return "Back to full size: %s, or R on a keyboard." % _p(&"grow")


func _check_grow() -> bool:
	return game.player.size > 0.9


func _text_wheel() -> String:
	if Actions.last_device == "touch":
		return "Tap the tool name at the top left to open the tool wheel. Tap Modify: its tools branch out. Tap Push / Pull."
	return "Hold %s to open the tool wheel and point at Modify: its tools branch out. Let go to open it, point at Push / Pull and press %s." % [
		_p(&"tool_wheel"), _p(&"ui_accept")]


func _check_wheel() -> bool:
	return game.tools.tool().id == "push"


func _text_push() -> String:
	return "Aim at the top of the grey block and press %s to push it up. Make it 2 m tall. %s pulls it back down." % [
		_p(&"primary"), _p(&"secondary")]


func _check_push() -> bool:
	return _param("Lift block", "h") >= 1.99


func _text_sketch() -> String:
	if Actions.last_device == "touch":
		return "Real CAD starts with a sketch. Open the tool wheel, pick Sketch, aim at the orange pad and tap Fire to sketch on its top face."
	return "Real CAD starts with a sketch. Open the tool wheel, pick Sketch, aim at the orange pad and press %s to sketch on its top face." % _p(&"primary")


func _check_sketch() -> bool:
	return game.sketcher.active


func _text_rect() -> String:
	if Actions.last_device == "touch":
		return "Open the tool wheel for the sketch tools, tap Draw and pick Rectangle. Tap Fire on one corner, then on the opposite corner."
	return "The view now looks straight down at the sketch: move to pan, %s / %s to zoom. Hold %s for the sketch tools, open Draw and pick Rectangle, then press %s on one corner and on the opposite corner." % [
		_p(&"grow"), _p(&"shrink"), _p(&"tool_wheel"), _p(&"primary")]


func _check_rect() -> bool:
	return game.sketcher.active and game.sketcher.count("line") >= 4


func _text_finish() -> String:
	if Actions.last_device == "touch":
		return "Open Menu and choose Finish sketch. It joins the part's history as a feature."
	return "Press %s to finish the sketch. It joins the part's history as a feature." % _p(&"finish")


func _check_finish() -> bool:
	return not game.sketcher.active and _count_type("sketch") > 0


func _text_extrude() -> String:
	if Actions.last_device == "controller":
		return "Extrude is ready. Aim at your sketch and press RT. Change the depth with D-pad ←→ (Y to type it), walk around the preview, then press A."
	if Actions.last_device == "touch":
		return "Extrude is ready. Aim at your sketch and tap Fire. Change the depth with the arrows in the panel, then tap OK."
	return "Extrude is ready. Aim at your sketch and click. Change the depth with ←→ (N to type it), walk around the preview, then press Enter."


func _check_extrude() -> bool:
	if game.dialog.visible:
		return false
	for f in _features():
		if f.type == "extrude" and f.params.has("sketch") and f.ok:
			return true
	return false


func _count_type(t: String) -> int:
	var n := 0
	for f in _features():
		if f.type == t:
			n += 1
	return n


func _text_measure() -> String:
	return "Pick Measure from the wheel. Press %s on one corner, then on another, to read the distance between them." % _p(&"primary")


func _check_measure() -> bool:
	return game.tools.measure_text() != ""


func _text_map() -> String:
	if Actions.last_device == "touch":
		return "Open Menu, then Controls, to see every control. Close it to finish."
	return "Press %s to open the controls map, then %s to close it. It works any time." % [
		_p(&"controller_map"), _p(&"ui_cancel")]


func _check_map() -> bool:
	return _map_seen and not game.cmap.visible


func _near_xz(target: Vector3, radius: float) -> bool:
	var f: Vector3 = game.player.feet
	return Vector2(f.x - target.x, f.z - target.z).length() < radius


func _features() -> Array:
	return game.doc.get_features() if game.doc != null and game.doc.has_method("get_features") else []


func _param(feature_name: String, key: String) -> float:
	for f in _features():
		if f.name == feature_name:
			var v: Variant = f.params.get(key, 0.0)
			return float(v) if (v is float or v is int) else 0.0
	return 0.0


func _advance() -> void:
	step += 1
	if step >= steps.size():
		_complete()
		return
	var s: Dictionary = steps[step]
	_count.text = "TRAINING  ·  %d / %d" % [step + 1, steps.size()]
	_heading.text = s.title
	_heading.add_theme_color_override("font_color", UiTheme.FG)
	_refresh_text()
	_marker.visible = s.has("marker")
	if s.has("marker"):
		_marker.position = s.marker
	_bar.size.x = _bar_back.size.x * float(step) / steps.size()
	_done_t = -1.0


func _refresh_text() -> void:
	if step >= 0 and step < steps.size():
		_body.text = call(steps[step].text)


func _process(dt: float) -> void:
	if step < 0 or step >= steps.size():
		return
	_t += dt
	_look_total += absf(angle_difference(_last_yaw, game.player.yaw))
	_last_yaw = game.player.yaw
	if game.cmap.visible:
		_map_seen = true
	var blocked: bool = game.hud.menu_open or game.hud.panel_open or game.cmap.visible or game.numpad.visible
	_card.visible = not blocked
	_ring.position.y = 0.15 + 0.08 * sin(_t * 3.0)
	_ring.rotation.y = _t * 0.8
	if _done_t >= 0.0:
		_done_t += dt
		if _done_t > 1.1:
			_advance()
		return
	if Engine.get_process_frames() % 20 == 0:
		_refresh_text()  # prompts follow the device in use
	if call(steps[step].check):
		_done_t = 0.0
		_heading.text = "✓  " + steps[step].title
		_heading.add_theme_color_override("font_color", UiTheme.ACCENT)
		_bar.size.x = _bar_back.size.x * float(step + 1) / steps.size()
		Input.start_joy_vibration(0, 0.3, 0.5, 0.18)
		var tw := create_tween()
		tw.tween_property(_card, "scale", Vector2(1.04, 1.04), 0.12)
		tw.tween_property(_card, "scale", Vector2.ONE, 0.18)


func _complete() -> void:
	_marker.visible = false
	_card.visible = false
	_end.visible = true
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("progress", "tutorial_done", true)
	cfg.save(SETTINGS)
	UiTheme.keep_focus(_end)


func is_open_card() -> bool:
	return _end.visible


func keep_focus() -> void:
	if _end.visible:
		UiTheme.keep_focus(_end)


static func is_done() -> bool:
	var cfg := ConfigFile.new()
	return cfg.load(SETTINGS) == OK and bool(cfg.get_value("progress", "tutorial_done", false))


# ---------- presentation ----------

func _build_ui() -> void:
	_layer.layer = 2
	add_child(_layer)
	var top := CenterContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_top = 16
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(top)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.custom_minimum_size = Vector2(minf(560, maxf(320, get_viewport().get_visible_rect().size.x - 640)), 0)
	_card.resized.connect(func(): _card.pivot_offset = _card.size / 2.0)
	top.add_child(_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_card.add_child(col)
	_count = UiTheme.title("", 14, UiTheme.ACCENT)
	_heading = UiTheme.title("", 26)
	_body = UiTheme.text("", 17)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_count)
	col.add_child(_heading)
	col.add_child(_body)
	var bar_holder := Control.new()
	bar_holder.custom_minimum_size = Vector2(0, 4)
	col.add_child(bar_holder)
	_bar_back.color = UiTheme.LINE
	_bar_back.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar_holder.add_child(_bar_back)
	_bar.color = UiTheme.ACCENT
	_bar.size = Vector2(0, 4)
	bar_holder.add_child(_bar)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(centre)
	centre.add_child(_end)
	var end_col := VBoxContainer.new()
	end_col.add_theme_constant_override("separation", 12)
	end_col.custom_minimum_size = Vector2(420, 0)
	_end.add_child(end_col)
	end_col.add_child(UiTheme.title("TRAINING COMPLETE", 32, UiTheme.ACCENT))
	var note := UiTheme.text("You can move at any size, sketch on any flat face or plane, and build features from sketches. Every change is a real dimension in the part's history, ready to export.", 17, UiTheme.MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	end_col.add_child(note)
	for spec in [["stay", "Keep building here"], ["free", "Free build"], ["title", "Title screen"]]:
		var b := Button.new()
		b.text = spec[1]
		b.custom_minimum_size = Vector2(0, 52)
		var id: String = spec[0]
		b.pressed.connect(func():
			_end.visible = false
			step = steps.size()
			finished.emit(id))
		end_col.add_child(b)
	_end.visible = false


func _build_marker() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = UiTheme.ACCENT
	var torus := TorusMesh.new()
	torus.inner_radius = 0.5
	torus.outer_radius = 0.62
	_ring.mesh = torus
	_ring.material_override = mat
	var beam_mat := StandardMaterial3D.new()
	beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.albedo_color = Color(UiTheme.ACCENT, 0.28)
	beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.05
	cyl.height = 8.0
	_beam.mesh = cyl
	_beam.material_override = beam_mat
	_beam.position.y = 4.0
	_marker.add_child(_ring)
	_marker.add_child(_beam)
	_marker.visible = false
	add_child(_marker)
