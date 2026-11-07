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
const TITLES := {extrude = "EXTRUDE", revolve = "REVOLVE", sweep = "SWEEP", loft = "LOFT", plane = "PLANE",
	axis = "AXIS", point = "POINT", fillet = "FILLET", chamfer = "CHAMFER", hole = "HOLE", shell = "SHELL"}
## Features built from things picked in the model (edges, faces, a point) plus sizes set here.
const PICKED_TYPES := ["fillet", "chamfer", "hole", "shell"]
## Fields that show or hide others when they change.
const SHAPING_KEYS := ["kind", "end", "direction", "thread"]
## Tapped holes: thread and its tap drill (metres), metric coarse and Unified.
const THREADS_METRIC := [["M2", 0.0016], ["M2.5", 0.00205], ["M3", 0.0025], ["M4", 0.0033], ["M5", 0.0042],
	["M6", 0.005], ["M8", 0.0068], ["M10", 0.0085], ["M12", 0.0102], ["M16", 0.014]]
const THREADS_INCH := [["#4-40", 0.00226], ["#6-32", 0.00271], ["#8-32", 0.00345], ["#10-24", 0.0038], ["#10-32", 0.00404],
	["1/4-20", 0.00511], ["5/16-18", 0.00653], ["3/8-16", 0.00794], ["1/2-13", 0.01072]]
const REFERENCE_TYPES := ["plane", "axis", "point", "csys"]
const OPS := [["add", "Add material"], ["cut", "Cut away"], ["new-body", "New body"]]

var game: Node  # main.gd
var type := ""
var feature_id := ""
var editing := false
var sketch_id := ""
var base_params := {}  # a reference feature's params the panel does not edit (what it refers to)
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
	base_params = {}
	values = {}
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


## Adds a feature built from picks (base: edges, faces or a point, as the core stores them) and
## opens the panel on its sizes: fillet, chamfer, hole, shell.
func open_feature(t: String, base: Dictionary, op: String) -> bool:
	type = t
	editing = false
	sketch_id = ""
	base_params = base.duplicate(true)
	values = {}
	if not _setup_fields():
		return false
	values.op = op
	game.doc.checkpoint()
	var r: Dictionary = game.doc.insert_feature(type, op, _params())
	if String(r.get("id", "")) == "":
		game.doc.abandon()
		game.hud.toast(r.get("message", "Could not add the %s" % type))
		return false
	feature_id = r.id
	_open(r)
	return true


## Whether a new reference of this type and kind has sizes to set in the panel.
static func wants_panel(t: String, params: Dictionary) -> bool:
	var kind := String(params.get("kind", ""))
	return (t == "plane" and kind in ["offset", "angle"]) or (t == "point" and kind == "xyz")


## Adds a reference feature (plane, axis, point) with params and opens the panel on its sizes.
## False when the kind has nothing to set: the feature is then added as it is.
func open_reference(t: String, params: Dictionary) -> bool:
	type = t
	editing = false
	sketch_id = ""
	base_params = params.duplicate(true)
	values = {}
	if not _setup_fields():
		return false
	for k in values:
		if params.has(k):
			values[k] = params[k]
	game.doc.checkpoint()
	var r: Dictionary = game.doc.insert_feature(type, "", _params())
	if String(r.get("id", "")) == "":
		game.doc.abandon()
		game.hud.toast(r.get("message", "Could not add it"))
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
	if type in PICKED_TYPES:
		base_params = p.duplicate(true)
		values = p.duplicate(true)
		if not _setup_fields():
			return false
		values.op = f.op
		game.doc.checkpoint()
		_open(game.doc.update_feature(feature_id, values.op, _params()))
		return true
	if type in REFERENCE_TYPES:
		base_params = p.duplicate(true)
		values = {}
		if not _setup_fields():
			game.hud.toast("%s has no sizes to change: delete it and make it again" % f.name)
			return false
		for k in values:
			if p.has(k):
				values[k] = p[k]
		game.doc.checkpoint()
		_open(game.doc.update_feature(feature_id, "", _params()))
		return true
	sketch_id = p.get("sketch", "")
	base_params = {}
	values = {}
	if p.has("face"):
		base_params.face = p.face
	if type == "loft" and p.get("sketches", []).size() > 0:
		sketch_id = p.sketches[0]
	if not _setup_fields():
		return false
	for k in ["depth", "depth2", "direction", "end", "angle", "axis", "path"]:
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
	fields = []
	var others := _other_sketches()
	match type:
		"extrude":
			_defaults({depth = _default_depth(), depth2 = _default_depth(), direction = "normal", end = "blind"})
			fields = []
			if values.end == "blind":
				fields.append({key = "depth", label = "Depth", kind = "length"})
			fields.append({key = "end", label = "End", kind = "choice",
				choices = [["blind", "Blind (depth)"], ["through_all", "Through all"], ["up_to_face", "Up to the face aimed at"]]})
			fields.append({key = "direction", label = "Direction", kind = "choice",
				choices = [["normal", "Out of the plane"], ["reverse", "Into the plane"], ["symmetric", "Both sides"],
					["two", "Both sides, two depths"]]})
			if values.direction == "two":
				fields.append({key = "depth2", label = "Depth 2", kind = "length"})
		"revolve":
			var axes := [["x", "Sketch X axis"], ["y", "Sketch Y axis"]]
			var preferred := "y"
			for rv in game.doc.reference_views():
				if rv.kind == "axis" and rv.ok:
					axes.append([rv.id, rv.name])
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
		"plane":
			match String(base_params.get("kind", "offset")):
				"offset":
					fields = [{key = "distance", label = "Distance", kind = "length", signed = true}]
					values = {distance = base_params.get("distance", game.player.grid_step())}
				"angle":
					fields = [{key = "angle", label = "Angle", kind = "angle", signed = true}]
					values = {angle = base_params.get("angle", PI / 4.0)}
				_:
					return false
		"fillet":
			_defaults({r = game.player.snap_step()})
			fields = [{key = "r", label = "Radius", kind = "length"}]
		"chamfer":
			_defaults({d = game.player.snap_step()})
			fields = [{key = "d", label = "Distance", kind = "length"}]
		"shell":
			_defaults({t = game.player.snap_step()})
			fields = [{key = "t", label = "Wall", kind = "length"}]
		"hole":
			var inch: bool = game.hud.units in ["in", "ft"]
			var threads: Array = THREADS_INCH if inch else THREADS_METRIC
			var d0 := 0.25 * 0.0254 if inch else 0.006
			_defaults({kind = "simple", d = d0, end = "through_all", depth = d0 * 2.0, cbore_d = d0 * 1.8, cbore_depth = d0,
				csink_d = d0 * 2.0, csink_angle = PI / 2.0, thread = threads[5][0]})
			fields = [{key = "kind", label = "Type", kind = "choice",
				choices = [["simple", "Simple"], ["counterbore", "Counterbore"], ["countersink", "Countersink"], ["tapped", "Tapped"]]}]
			if values.kind == "tapped":
				fields.append({key = "thread", label = "Thread", kind = "choice", choices = threads.map(func(t): return [t[0], t[0]])})
				for t in threads:
					if t[0] == values.thread:
						values.d = t[1]
			else:
				fields.append({key = "d", label = "Diameter", kind = "length"})
			fields.append({key = "end", label = "End", kind = "choice", choices = [["through_all", "Through all"], ["blind", "Blind (depth)"]]})
			if values.end == "blind":
				fields.append({key = "depth", label = "Depth", kind = "length"})
			if values.kind == "counterbore":
				fields += [{key = "cbore_d", label = "Bore Ø", kind = "length"}, {key = "cbore_depth", label = "Bore depth", kind = "length"}]
			elif values.kind == "countersink":
				fields += [{key = "csink_d", label = "Sink Ø", kind = "length"}, {key = "csink_angle", label = "Sink angle", kind = "angle"}]
		"point":
			if String(base_params.get("kind", "xyz")) != "xyz":
				return false
			fields = [{key = "x", label = "X", kind = "length", signed = true}, {key = "y", label = "Y", kind = "length", signed = true},
				{key = "z", label = "Z", kind = "length", signed = true}]
			values = {x = base_params.get("x", 0.0), y = base_params.get("y", 0.0), z = base_params.get("z", 0.0)}
		_:
			return false
	if type in REFERENCE_TYPES or type in ["fillet", "chamfer", "shell"]:
		values.op = ""
		return true
	if type == "hole":
		values.op = "cut"
		return true
	fields.append({key = "op", label = "Result", kind = "choice", choices = OPS})
	if not values.has("op"):
		values.op = "add"
	return true


## Sets defaults for keys not yet set (so the panel keeps what was chosen when fields change).
func _defaults(d: Dictionary) -> void:
	for k in d:
		if not values.has(k):
			values[k] = d[k]


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
			var e := {sketch = sketch_id, depth = values.depth, direction = values.direction, end = values.end}
			if values.direction == "two":
				e.depth2 = values.depth2
			if values.end == "up_to_face" and base_params.has("face"):
				e.face = base_params.face
			return e
		"fillet", "chamfer", "shell", "hole":
			var p := base_params.duplicate(true)
			for k in values:
				if k != "op":
					p[k] = values[k]
			if type == "hole":
				if values.kind != "tapped":
					p.erase("thread")
				if values.end != "blind":
					p.erase("depth")
			return p
		"revolve":
			return {sketch = sketch_id, angle = values.angle, axis = values.axis, direction = values.direction}
		"sweep":
			return {sketch = sketch_id, path = values.path}
		"loft":
			return {sketches = [sketch_id, values.to]}
		"plane", "axis", "point", "csys":
			var p := base_params.duplicate(true)
			for k in values:
				if k != "op":
					p[k] = values[k]
			return p
	return {}


# ---------- editing ----------

func set_value(key: String, value: Variant) -> void:
	values[key] = value
	_apply()


func _apply() -> void:
	if type == "extrude" and values.get("end", "") == "up_to_face" and not base_params.has("face"):
		var ref: Dictionary = game.aimed_face_ref()
		if ref.is_empty():
			values.end = "blind"
			game.hud.toast("Aim at a flat face of the model first, then choose Up to the face aimed at")
		else:
			base_params.face = ref
	if type in ["extrude", "hole"]:
		_setup_fields()  # the fields follow the choices (a blind end shows Depth, a counterbore its sizes)
		focus = mini(focus, fields.size() - 1)
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
	value.disabled = false
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
			values[f.key] = snappedf(float(v) + d * step, step) if f.get("signed", false) else maxf(snappedf(float(v) + d * step, step), step)
		"angle":
			if v is String:
				game.hud.toast("%s is an expression; type a new value to change it" % f.label)
				return
			var a := snappedf(float(v) + d * deg_to_rad(15.0), deg_to_rad(15.0))
			values[f.key] = clampf(a, -TAU, TAU) if f.get("signed", false) else clampf(a, deg_to_rad(15.0), TAU)
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
