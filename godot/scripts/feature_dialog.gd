extends CanvasLayer
## The property panel for sketch-based features (Extrude, Revolve, Sweep, Loft), like a desktop
## CAD tool's property manager. The feature is added to the part as soon as the panel opens and
## updates live as fields change, so the player can walk around the preview; OK keeps it and
## Cancel restores the part as it was.
##
## Controller: D-pad ↑↓ pick a field, D-pad ←→ or RT/LT change it, Y types a value, A OK,
## B cancel. Keyboard: arrow keys, N to type, Enter, Esc. Mouse and touch: the on-screen buttons.

signal closed(ok: bool, feature_id: String)

const UiTheme := preload("res://scripts/ui_theme.gd")
const Units := preload("res://scripts/units.gd")
const TITLES := {extrude = "EXTRUDE", revolve = "REVOLVE", sweep = "SWEEP", loft = "LOFT"}
const OPS := [["add", "Add material"], ["cut", "Cut away"], ["new-body", "New body"]]

var game: Node  # main.gd
var type := ""
var feature_id := ""
var editing := false
var sketch_id := ""
var values := {}
var fields: Array = []  # {key, label, kind: "length" | "angle" | "choice", choices}
var focus := 0
var ok := true
var message := ""

var _panel := PanelContainer.new()
var _title: Label
var _rows := VBoxContainer.new()
var _status: Label
var _help: Label


func _ready() -> void:
	layer = 6
	visible = false
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.offset_right = -20
	_panel.custom_minimum_size = Vector2(400, 0)
	root.add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_panel.add_child(col)
	_title = UiTheme.title("", 24, UiTheme.ACCENT)
	col.add_child(_title)
	_rows.add_theme_constant_override("separation", 6)
	col.add_child(_rows)
	_status = UiTheme.text("", 15, UiTheme.MUTED)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	for spec in [["Cancel", false], ["OK", true]]:
		var b := Button.new()
		b.text = spec[0]
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 46)
		if spec[1]:
			b.pressed.connect(accept)
		else:
			b.pressed.connect(cancel)
		buttons.add_child(b)
	col.add_child(buttons)
	_help = UiTheme.text("", 13, UiTheme.MUTED)
	_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_help)


# ---------- opening ----------

## Adds a new feature of type t on the sketch and opens the panel. False when it cannot start.
func open_new(t: String, sketch: String, op: String) -> bool:
	type = t
	editing = false
	sketch_id = sketch
	if not _setup_fields():
		return false
	values.op = op
	game.doc.checkpoint()
	var r: Dictionary = game.doc.insert_feature(type, op, _params())
	if String(r.get("id", "")) == "":
		game.doc.abandon()
		game.hud.toast(r.get("message", "Could not add the feature"))
		return false
	feature_id = r.id
	_open(r)
	return true


## Opens the panel on an existing feature (from the model panel).
func open_edit(f: Dictionary) -> bool:
	type = f.type
	editing = true
	feature_id = f.id
	var p: Dictionary = f.params
	sketch_id = p.get("sketch", "")
	if type == "loft" and p.get("sketches", []).size() > 0:
		sketch_id = p.sketches[0]
	if not _setup_fields():
		return false
	for k in ["depth", "direction", "end", "angle", "axis", "path"]:
		if p.has(k) and values.has(k):
			values[k] = p[k]
	if type == "loft" and p.get("sketches", []).size() > 1:
		values.to = p.sketches[-1]
	values.op = f.op
	game.doc.checkpoint()
	_open(game.doc.update_feature(feature_id, values.op, _params()))
	return true


func _open(r: Dictionary) -> void:
	focus = 0
	visible = true
	# Buttons elsewhere must not keep focus, or A and the D-pad would go to them.
	var held: Control = get_viewport().gui_get_focus_owner()
	if held != null:
		held.release_focus()
	_show(r)
	game.on_model_changed()


## Field definitions and defaults for the current type. False (with a toast) when the feature
## cannot be made, such as a sweep with no path sketch.
func _setup_fields() -> bool:
	values = {}
	fields = []
	var others := _other_sketches()
	match type:
		"extrude":
			fields = [
				{key = "depth", label = "Depth", kind = "length"},
				{key = "direction", label = "Direction", kind = "choice",
					choices = [["normal", "Out of the plane"], ["reverse", "Into the plane"], ["symmetric", "Both sides"]]},
				{key = "end", label = "End", kind = "choice", choices = [["blind", "Blind (depth)"], ["through_all", "Through all"]]},
			]
			values = {depth = _default_depth(), direction = "normal", end = "blind"}
		"revolve":
			var axes := [["x", "Sketch X axis"], ["y", "Sketch Y axis"]]
			var preferred := "y"
			var sk: Dictionary = game.doc.get_sketch(sketch_id)
			for e in sk.get("entities", []):
				if e.kind == "line":
					var construction: bool = e.get("construction", false)
					axes.append([e.id, ("Centerline " if construction else "Line ") + String(e.id)])
					if construction and preferred == "y":
						preferred = e.id
			fields = [
				{key = "angle", label = "Angle", kind = "angle"},
				{key = "axis", label = "Axis", kind = "choice", choices = axes},
				{key = "direction", label = "Direction", kind = "choice", choices = [["normal", "Forward"], ["reverse", "Reverse"]]},
			]
			values = {angle = TAU, axis = preferred, direction = "normal"}
		"sweep", "loft":
			if others.is_empty():
				game.hud.toast("Sweep needs a second sketch for its path: draw a line or arc chain on another plane" if type == "sweep"
					else "Loft needs a second sketch: draw another profile on a parallel plane")
				return false
			var key := "path" if type == "sweep" else "to"
			fields = [{key = key, label = "Path" if type == "sweep" else "Loft to", kind = "choice", choices = others}]
			values[key] = others[-1][0]
		_:
			return false
	fields.append({key = "op", label = "Result", kind = "choice", choices = OPS})
	values.op = "add"
	return true


## [id, name] of every sketch except the profile, unused ones last so they are the default.
func _other_sketches() -> Array:
	var used := []
	var unused := []
	for v in game.doc.sketch_views():
		if v.id == sketch_id:
			continue
		if v.consumed:
			used.append([v.id, v.name])
		else:
			unused.append([v.id, v.name])
	return used + unused


func _default_depth() -> float:
	var sk: Dictionary = game.doc.get_sketch(sketch_id)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in sk.get("points", []):
		var v := Vector2(float(p.x), float(p.y))
		lo = lo.min(v)
		hi = hi.max(v)
	for e in sk.get("entities", []):
		if e.kind == "circle":
			hi.x = maxf(hi.x, lo.x + float(e.r) * 2.0)
	var step: float = game.player.snap_step()
	var size: float = (hi - lo).length() if lo.x < INF else float(game.player.grid_step())
	return maxf(snappedf(size * 0.5, step), step)


func _params() -> Dictionary:
	match type:
		"extrude":
			return {sketch = sketch_id, depth = values.depth, direction = values.direction, end = values.end}
		"revolve":
			return {sketch = sketch_id, angle = values.angle, axis = values.axis, direction = values.direction}
		"sweep":
			return {sketch = sketch_id, path = values.path}
		"loft":
			return {sketches = [sketch_id, values.to]}
	return {}


# ---------- editing ----------

func set_value(key: String, value: Variant) -> void:
	values[key] = value
	_apply()


func _apply() -> void:
	_show(game.doc.update_feature(feature_id, values.op, _params()))
	game.on_model_changed()


func _show(r: Dictionary) -> void:
	ok = r.get("ok", false)
	message = r.get("message", "")
	_title.text = TITLES.get(type, type.to_upper()) + ("  ·  EDIT" if editing else "")
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	for i in fields.size():
		_rows.add_child(_row(i))
	if ok:
		_status.text = "Preview shown in the model. Walk around it, then confirm."
		_status.add_theme_color_override("font_color", UiTheme.MUTED)
	else:
		_status.text = "⚠ " + message
		_status.add_theme_color_override("font_color", Color("e0775f"))
	var pad := Actions.last_device == "controller"
	_help.text = ("D-pad ↑↓ field · ←→ or RT/LT change · Y type a value · A OK · B cancel" if pad
		else "↑↓ field · ←→ change · N type a value · Enter OK · Esc cancel")


func _row(i: int) -> Control:
	var f: Dictionary = fields[i]
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.25) if i != focus else UiTheme.ACCENT.darkened(0.7)
	sb.border_color = UiTheme.ACCENT if i == focus else UiTheme.LINE
	sb.set_border_width_all(2 if i == focus else 1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(6)
	box.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var label := UiTheme.text(f.label, 15, UiTheme.FG if i == focus else UiTheme.MUTED)
	label.custom_minimum_size = Vector2(96, 0)
	row.add_child(label)
	var less := Button.new()
	less.text = "◀"
	less.focus_mode = Control.FOCUS_NONE
	less.pressed.connect(func():
		focus = i
		adjust(-1))
	row.add_child(less)
	var value := Button.new()
	value.text = _value_text(f)
	value.focus_mode = Control.FOCUS_NONE
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.disabled = f.key == "depth" and values.get("end", "") == "through_all"
	value.pressed.connect(func():
		focus = i
		if f.kind == "choice":
			adjust(1)
		else:
			type_value())
	row.add_child(value)
	var more := Button.new()
	more.text = "▶"
	more.focus_mode = Control.FOCUS_NONE
	more.pressed.connect(func():
		focus = i
		adjust(1))
	row.add_child(more)
	return box


func _value_text(f: Dictionary) -> String:
	var v: Variant = values.get(f.key)
	match f.kind:
		"length":
			return v if v is String else game.hud.length(float(v))
		"angle":
			return v if v is String else "%.0f°" % rad_to_deg(float(v))
		"choice":
			for c in f.choices:
				if c[0] == v:
					return c[1]
	return str(v)


func move_focus(d: int) -> void:
	focus = posmod(focus + d, fields.size())
	_show({ok = ok, message = message})


func adjust(d: int) -> void:
	var f: Dictionary = fields[focus]
	var v: Variant = values.get(f.key)
	match f.kind:
		"length":
			if v is String:
				game.hud.toast("%s is an expression; type a new value to change it" % f.label)
				return
			var step: float = game.player.snap_step()
			values[f.key] = maxf(snappedf(float(v) + d * step, step), step)
		"angle":
			if v is String:
				game.hud.toast("%s is an expression; type a new value to change it" % f.label)
				return
			values[f.key] = clampf(snappedf(float(v) + d * deg_to_rad(15.0), deg_to_rad(15.0)), deg_to_rad(15.0), TAU)
		"choice":
			var n: int = f.choices.size()
			var at := 0
			for k in n:
				if f.choices[k][0] == v:
					at = k
			values[f.key] = f.choices[posmod(at + d, n)][0]
	_apply()


func type_value() -> void:
	var f: Dictionary = fields[focus]
	if f.kind == "choice":
		return
	var angle: bool = f.kind == "angle"
	var units: String = game.hud.units
	var key: String = f.key
	game.numpad.ask(f.label, Units.show(values[key], units, angle),
		("Degrees" if angle else "In " + units) + ", or an expression using the part's variables.",
		func(text: String): set_value(key, Units.parse(text, units, angle)))


func accept() -> void:
	if not visible:
		return
	if not ok:
		game.hud.toast("Fix the problem first, or cancel: " + message)
		return
	visible = false
	closed.emit(true, feature_id)


func cancel() -> void:
	if not visible:
		return
	visible = false
	game.doc.abandon()
	game.on_model_changed()
	closed.emit(false, feature_id)


## Input from main.gd while the panel is open. Returns true when the event was used.
func handle(e: InputEvent) -> bool:
	if not visible or game.numpad.visible:
		return false
	var mouse := e is InputEventMouseButton
	if e.is_action_pressed(&"ui_up", true):
		move_focus(-1)
	elif e.is_action_pressed(&"ui_down", true):
		move_focus(1)
	elif e.is_action_pressed(&"ui_left", true) or (not mouse and e.is_action_pressed(&"secondary")):
		adjust(-1)
	elif e.is_action_pressed(&"ui_right", true) or (not mouse and e.is_action_pressed(&"primary")):
		adjust(1)
	elif e.is_action_pressed(&"inspect") or (e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_N):
		type_value()
	elif e.is_action_pressed(&"ui_accept"):
		accept()
	elif e.is_action_pressed(&"ui_cancel") or e.is_action_pressed(&"menu"):
		cancel()
	else:
		return false
	return true
