extends Node3D
## Sketch mode: draw on a plane the way a desktop CAD sketcher works, from first person.
##
## The crosshair ray meets the sketch plane at the cursor. Lines, rectangles, circles and arcs
## snap to existing points, the sketch origin and the grid. Relations (horizontal, parallel,
## tangent…) and dimensions hold the geometry; every change is solved by the CAD core, which
## reports the degrees of freedom left or refuses a conflicting change. Finishing adds (or
## updates) a sketch feature in the part's history; Extrude, Revolve, Sweep and Loft use it.
##
## main.gd routes input here while a sketch is open and calls update() every frame.

signal ended(feature_id: String, committed: bool)
signal changed

const Units := preload("res://scripts/units.gd")
const TOOLS := [
	{id = "line", name = "Line", pri = "place point (chains)", alt = "end the chain", opt = ["solid", "construction"]},
	{id = "rect", name = "Rectangle", pri = "corner, then opposite corner", alt = "cancel", opt = ["solid", "construction"]},
	{id = "circle", name = "Circle", pri = "centre, then edge", alt = "cancel", opt = ["solid", "construction"]},
	{id = "arc", name = "Arc", pri = "centre, start, end", alt = "cancel", opt = ["counter-clockwise", "clockwise"]},
	{id = "dimension", name = "Dimension", pri = "line, circle, arc or two points", alt = "cancel", opt = ["aligned", "horizontal", "vertical"]},
	{id = "relation", name = "Relation", pri = "pick geometry to relate", alt = "cancel",
		opt = ["horizontal", "vertical", "coincident", "parallel", "perpendicular", "equal", "tangent", "fix"]},
	{id = "erase", name = "Delete", pri = "delete geometry", alt = "remove its relations and dimensions", opt = []},
]
const COLOR_FREE := Color("7cc4ff")
const COLOR_DEFINED := Color("f2f5f8")
const COLOR_CONSTRUCTION := Color("8f9bab")
const COLOR_ACTIVE := Color("ff8a3d")
const COLOR_DIM := Color("ffd166")
const COLOR_GRID := Color(0.78, 0.85, 0.93, 0.18)
const KIND_NAMES := {line = "Line", circle = "Circle", arc = "Arc"}

var game: Node  # main.gd
var active := false
var sketch := {}
var edit_id := ""
var status := {ok = true, dof = 0, message = ""}
var index := 0
var options := {}

var _o := Vector3.ZERO
var _n := Vector3.UP
var _x := Vector3.RIGHT
var _y := Vector3.FORWARD
var _pts := {}   # point id -> Vector2 (includes the origin "o")
var _ents := {}  # entity id -> Dictionary
var _pending: Array = []  # spots placed for the entity being drawn: {id, uv}
var _picks: Array = []    # dimension / relation picks: {kind, id}
var _history: Array = []
var _future: Array = []
var _raw := Vector2.ZERO     # where the crosshair meets the plane
var _cursor := Vector2.ZERO  # after snapping
var _snap_id := ""
var _valid := false
var _tol := 0.01
var _hover := {}
var _lines := MeshInstance3D.new()
var _grid := MeshInstance3D.new()
var _labels: Array[Label3D] = []


func _ready() -> void:
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.vertex_color_use_as_albedo = true
	line_mat.no_depth_test = true
	line_mat.render_priority = 20
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_lines.mesh = ImmediateMesh.new()
	_lines.material_override = line_mat
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lines)
	var grid_mat := StandardMaterial3D.new()
	grid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid_mat.vertex_color_use_as_albedo = true
	grid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_grid.mesh = ImmediateMesh.new()
	_grid.material_override = grid_mat
	_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_grid)
	visible = false


# ---------- entering and leaving ----------

## Opens a new sketch on plane (CAD JSON plane), or the existing sketch feature edit.
func begin(plane: Dictionary, plane_name: String, edit: String = "") -> bool:
	edit_id = edit
	if edit != "":
		sketch = game.doc.get_sketch(edit)
		if sketch.is_empty():
			return false
	else:
		sketch = {plane = plane, planeName = plane_name, points = [], entities = [], constraints = []}
	for k in ["points", "entities", "constraints"]:
		if not sketch.has(k):
			sketch[k] = []
	var b: Dictionary = game.doc.plane_basis(sketch.plane)
	_o = b.origin
	_n = (b.normal as Vector3).normalized()
	_x = (b.xdir as Vector3).normalized()
	_y = (b.ydir as Vector3).normalized()
	_history.clear()
	_future.clear()
	_pending.clear()
	_picks.clear()
	index = 0
	var r: Dictionary = game.doc.solve_sketch(sketch)
	status = r
	if r.ok:
		sketch = r.sketch
	_index()
	active = true
	visible = true
	return true


## Adds the sketch to the part (or updates the edited one) and leaves sketch mode.
func finish() -> void:
	if not active:
		return
	_pending.clear()
	_picks.clear()
	var has_geometry: bool = not (sketch.entities as Array).is_empty()
	var id := edit_id
	if edit_id != "":
		var r: Dictionary = game.doc.set_sketch(edit_id, sketch)
		if not r.ok:
			game.hud.toast(r.message)
			return
	elif has_geometry:
		id = game.doc.add_sketch(sketch)
		if id == "":
			game.hud.toast("That sketch would break the model")
			return
	_close()
	ended.emit(id, has_geometry or edit_id != "")


## Leaves sketch mode without changing the part.
func discard() -> void:
	if not active:
		return
	_close()
	ended.emit("", false)


func _close() -> void:
	active = false
	visible = false
	_pending.clear()
	_picks.clear()
	for l in _labels:
		l.visible = false


func has_pending() -> bool:
	return not _pending.is_empty() or not _picks.is_empty()


func cancel_pending() -> void:
	_pending.clear()
	_picks.clear()


# ---------- tools ----------

func tool() -> Dictionary:
	return TOOLS[index]


func option() -> String:
	var opts: Array = tool().opt
	return "" if opts.is_empty() else opts[options.get(tool().id, 0)]


func set_tool(i: int) -> void:
	if i < 0 or i >= TOOLS.size():
		return
	index = i
	cancel_pending()


func set_tool_id(id: String) -> void:
	for i in TOOLS.size():
		if TOOLS[i].id == id:
			set_tool(i)


func cycle_option() -> void:
	var opts: Array = tool().opt
	if opts.is_empty():
		game.hud.toast("%s has no options" % tool().name)
		return
	var n: int = (options.get(tool().id, 0) + 1) % opts.size()
	options[tool().id] = n
	_picks.clear()
	game.hud.toast("%s: %s" % [tool().name, opts[n]])


func count(kind: String) -> int:
	var n := 0
	for e in sketch.get("entities", []):
		if e.kind == kind:
			n += 1
	return n


func status_text() -> String:
	var what := "Editing sketch" if edit_id != "" else "New sketch"
	var state: String = status.message if (sketch.entities as Array).size() > 0 else "empty"
	return "%s on %s  ·  %s" % [what, sketch.get("planeName", "plane"), state]


func defined() -> bool:
	return status.ok and int(status.dof) == 0


# ---------- per frame ----------

func update() -> void:
	if not active:
		return
	_aim(game.player.eye_position(), game.player.aim_direction())
	_hover = _target(_prefer_points()) if _valid else {}
	_redraw()
	game.hud.set_aim(_aim_label(), _snap_id != "" or not _hover.is_empty())


func _aim(eye: Vector3, dir: Vector3) -> void:
	_valid = false
	var denom := dir.dot(_n)
	if absf(denom) < 1e-6:
		return
	var t := (_o - eye).dot(_n) / denom
	if t <= 0.0:
		return
	var w := eye + dir * t
	_raw = Vector2((w - _o).dot(_x), (w - _o).dot(_y))
	_tol = maxf(0.022 * t, 1e-7)
	_valid = true
	_snap()


func _snap() -> void:
	_snap_id = ""
	var best := _tol
	for id in _pts:
		var d: float = (_pts[id] as Vector2).distance_to(_raw)
		if d < best:
			best = d
			_snap_id = id
	if _snap_id != "":
		_cursor = _pts[_snap_id]
		return
	var s: float = game.player.snap_step()
	_cursor = Vector2(snappedf(_raw.x, s), snappedf(_raw.y, s))
	if not _pending.is_empty():
		var a: Vector2 = _pending[-1].uv
		if absf(_raw.x - a.x) < _tol:
			_cursor.x = a.x
		if absf(_raw.y - a.y) < _tol:
			_cursor.y = a.y


## Places at a plane position as if the crosshair were there (tests and touch use this).
func click_at(uv: Vector2, primary := true) -> void:
	_raw = uv
	_tol = maxf(0.01 * game.player.size, 1e-7)
	_valid = true
	_snap()
	_hover = _target(_prefer_points())
	press(primary)


func press(primary: bool) -> void:
	if not _valid:
		game.hud.toast("Aim at the sketch plane")
		return
	var spot := {id = _snap_id, uv = _cursor}
	match tool().id:
		"line":
			_line(primary, spot)
		"rect":
			_rect(primary, spot)
		"circle":
			_circle(primary, spot)
		"arc":
			_arc(primary, spot)
		"dimension":
			_dimension(primary)
		"relation":
			_relation(primary)
		"erase":
			_erase(primary)


# ---------- drawing tools ----------

func _line(primary: bool, spot: Dictionary) -> void:
	if not primary:
		_pending.clear()
		return
	if _pending.is_empty():
		_pending = [spot]
		return
	var a: Dictionary = _pending[0]
	if (a.uv as Vector2).distance_to(spot.uv) < 1e-12:
		return
	var s: Dictionary = sketch.duplicate(true)
	var ida := _point(s, a)
	var idb := _point(s, spot)
	var lid := _new_id(s, "l")
	s.entities.append(_entity(lid, "line", [ida, idb]))
	_auto_hv(s, lid, a.uv, spot.uv)
	if _commit(s, "Line"):
		if spot.id != "":
			_pending.clear()  # ended on an existing point: the chain is closed or joined
		else:
			_pending = [{id = idb, uv = _pts.get(idb, spot.uv)}]


func _rect(primary: bool, spot: Dictionary) -> void:
	if not primary:
		_pending.clear()
		return
	if _pending.is_empty():
		_pending = [spot]
		return
	var a: Dictionary = _pending[0]
	var au: Vector2 = a.uv
	var cu: Vector2 = spot.uv
	if absf(au.x - cu.x) < 1e-12 or absf(au.y - cu.y) < 1e-12:
		game.hud.toast("A rectangle needs width and height")
		return
	var s: Dictionary = sketch.duplicate(true)
	var ida := _point(s, a)
	var idb := _point(s, {id = "", uv = Vector2(cu.x, au.y)})
	var idc := _point(s, spot)
	var idd := _point(s, {id = "", uv = Vector2(au.x, cu.y)})
	var corners := [ida, idb, idc, idd]
	for i in 4:
		var lid := _new_id(s, "l")
		s.entities.append(_entity(lid, "line", [corners[i], corners[(i + 1) % 4]]))
		s.constraints.append({id = _new_id(s, "c"), kind = "horizontal" if i % 2 == 0 else "vertical", refs = [lid]})
	if _commit(s, "Rectangle"):
		_pending.clear()


func _circle(primary: bool, spot: Dictionary) -> void:
	if not primary:
		_pending.clear()
		return
	if _pending.is_empty():
		_pending = [spot]
		return
	var c: Dictionary = _pending[0]
	var r := _snapped_radius(c.uv, spot)
	if r <= 0.0:
		return
	var s: Dictionary = sketch.duplicate(true)
	var idc := _point(s, c)
	var e := _entity(_new_id(s, "k"), "circle", [idc])
	e.r = r
	s.entities.append(e)
	if _commit(s, "Circle"):
		_pending.clear()


func _arc(primary: bool, spot: Dictionary) -> void:
	if not primary:
		_pending.clear()
		return
	if _pending.size() < 2:
		if _pending.size() == 1 and (spot.uv as Vector2).distance_to(_pending[0].uv) < 1e-12:
			return
		_pending.append(spot)
		return
	var cu: Vector2 = _pending[0].uv
	var su: Vector2 = _pending[1].uv
	var r := cu.distance_to(su)
	var eu: Vector2 = spot.uv
	var end_spot := spot
	if absf(eu.distance_to(cu) - r) > _tol or spot.id == "":
		var dir := (eu - cu).normalized() if eu.distance_to(cu) > 1e-12 else Vector2.RIGHT
		end_spot = {id = "", uv = cu + dir * r}
	if (end_spot.uv as Vector2).distance_to(su) < 1e-9:
		game.hud.toast("Pick an end point away from the start")
		return
	var s: Dictionary = sketch.duplicate(true)
	var idc := _point(s, _pending[0])
	var ids := _point(s, _pending[1])
	var ide := _point(s, end_spot)
	var pts := [idc, ids, ide] if option() != "clockwise" else [idc, ide, ids]
	s.entities.append({id = _new_id(s, "a"), kind = "arc", pts = pts})
	if _commit(s, "Arc"):
		_pending.clear()


func _snapped_radius(centre: Vector2, spot: Dictionary) -> float:
	if spot.id != "":
		return centre.distance_to(spot.uv)
	var step: float = game.player.snap_step()
	return maxf(snappedf(centre.distance_to(_raw), step), step)


# ---------- dimensions and relations ----------

func _dimension(primary: bool) -> void:
	if not primary:
		_picks.clear()
		return
	var t := _hover
	if t.is_empty():
		game.hud.toast("Aim at a line, circle, arc or point")
		return
	if _picks.is_empty():
		if t.kind == "point":
			_picks = [t]
			game.hud.toast("Now the second point (%s: %s)" % [Actions.prompt(&"context_wheel"), option()])
			return
		var e: Dictionary = _ents[t.id]
		match e.kind:
			"line":
				ask_dimension("distance", [t.id], _pts[e.pts[0]].distance_to(_pts[e.pts[1]]))
			"circle":
				ask_dimension("diameter", [t.id], float(e.r) * 2.0)
			"arc":
				ask_dimension("radius", [t.id], _pts[e.pts[0]].distance_to(_pts[e.pts[1]]))
		return
	if t.kind != "point" or t.id == _picks[0].id:
		game.hud.toast("Pick a second, different point")
		return
	var pid: String = _picks[0].id
	var p: Vector2 = _pts[pid]
	var q: Vector2 = _pts[t.id]
	_picks.clear()
	match option():
		"horizontal":
			ask_dimension("hdistance", [pid, t.id], q.x - p.x)
		"vertical":
			ask_dimension("vdistance", [pid, t.id], q.y - p.y)
		_:
			ask_dimension("distance", [pid, t.id], p.distance_to(q))


## Asks for a dimension's value (editing the existing one of the same kind on the same refs).
func ask_dimension(kind: String, refs: Array, current: float) -> void:
	var existing := _find_constraint(kind, refs)
	var value: Variant = existing.value if not existing.is_empty() else current
	var titles := {distance = "Distance", hdistance = "Horizontal distance", vdistance = "Vertical distance",
		diameter = "Diameter", radius = "Radius"}
	var units: String = game.hud.units
	game.numpad.ask(titles.get(kind, "Dimension"), Units.show(value, units),
		"In %s, or an expression such as width / 2 using the part's variables." % units,
		set_dimension.bind(kind, refs))


func set_dimension(text: String, kind: String, refs: Array) -> bool:
	var value: Variant = Units.parse(text, game.hud.units)
	if value is float and kind in ["distance", "diameter", "radius"] and value <= 0.0:
		game.hud.toast("A %s must be more than zero" % kind)
		return false
	var s: Dictionary = sketch.duplicate(true)
	var found := false
	for c in s.constraints:
		if c.kind == kind and _same_refs(c.refs, refs):
			c.value = value
			found = true
	if not found:
		s.constraints.append({id = _new_id(s, "d"), kind = kind, refs = refs, value = value})
	return _commit(s, "Dimension")


func _relation(primary: bool) -> void:
	if not primary:
		_picks.clear()
		return
	var kind := option()
	var t := _hover
	if t.is_empty():
		game.hud.toast("Aim at sketch geometry")
		return
	var wants_point: bool = kind == "fix" or (kind == "coincident" and _picks.is_empty())
	if wants_point and t.kind != "point":
		game.hud.toast("Pick a point")
		return
	if not wants_point and kind != "coincident" and t.kind != "entity":
		game.hud.toast("Pick a line, circle or arc")
		return
	if kind in ["horizontal", "vertical", "parallel", "perpendicular"] and _ents[t.id].kind != "line":
		game.hud.toast("Pick a line")
		return
	if not _picks.is_empty() and _picks[0].id == t.id:
		return
	_picks.append(t)
	var need := 1 if kind in ["horizontal", "vertical", "fix"] else 2
	if _picks.size() < need:
		game.hud.toast("Now the second one")
		return
	var ids := _picks.map(func(p): return p.id)
	_picks.clear()
	var ckind := kind
	var refs: Array = ids
	match kind:
		"coincident":
			if t.kind == "entity":
				ckind = "point_on_line" if _ents[t.id].kind == "line" else "point_on_circle"
		"tangent":
			var k0: String = _ents[ids[0]].kind
			var k1: String = _ents[ids[1]].kind
			if k0 == "line" and k1 != "line":
				refs = ids
			elif k1 == "line" and k0 != "line":
				refs = [ids[1], ids[0]]
			else:
				game.hud.toast("Tangent needs a line and a circle or arc")
				return
		"equal":
			if (_ents[ids[0]].kind == "line") != (_ents[ids[1]].kind == "line"):
				game.hud.toast("Equal needs two lines, or two circles or arcs")
				return
	var s: Dictionary = sketch.duplicate(true)
	s.constraints.append({id = _new_id(s, "c"), kind = ckind, refs = refs})
	_commit(s, kind.capitalize())


func _erase(primary: bool) -> void:
	var t := _hover
	if t.is_empty() or t.id == "o":
		game.hud.toast("Aim at sketch geometry")
		return
	var s: Dictionary = sketch.duplicate(true)
	if not primary:
		var before: int = s.constraints.size()
		s.constraints = (s.constraints as Array).filter(func(c): return not (t.id in c.refs))
		var removed: int = before - s.constraints.size()
		if removed == 0:
			game.hud.toast("Nothing holds that")
			return
		if _commit(s, "Release"):
			game.hud.toast("Removed %d relation%s and dimension%s" % [removed, "" if removed == 1 else "s", "" if removed == 1 else "s"])
		return
	var gone := {}
	if t.kind == "point":
		for e in s.entities:
			if t.id in e.pts:
				gone[e.id] = true
	else:
		gone[t.id] = true
	s.entities = (s.entities as Array).filter(func(e): return not gone.has(e.id))
	var used := {}
	for e in s.entities:
		for p in e.pts:
			used[p] = true
	for p in s.points:
		if not used.has(p.id):
			gone[p.id] = true
	s.points = (s.points as Array).filter(func(p): return used.has(p.id))
	s.constraints = (s.constraints as Array).filter(func(c):
		for r in c.refs:
			if gone.has(r):
				return false
		return true)
	_commit(s, "Delete")


# ---------- history ----------

func _commit(s: Dictionary, what: String) -> bool:
	var r: Dictionary = game.doc.solve_sketch(s)
	if not r.ok:
		game.hud.toast("%s not applied: %s" % [what, r.message])
		return false
	_history.append(sketch)
	if _history.size() > 200:
		_history.pop_front()
	_future.clear()
	sketch = r.sketch
	status = r
	_index()
	changed.emit()
	return true


func undo() -> bool:
	if _history.is_empty():
		return false
	_future.append(sketch)
	_restore(_history.pop_back())
	return true


func redo() -> bool:
	if _future.is_empty():
		return false
	_history.append(sketch)
	_restore(_future.pop_back())
	return true


func _restore(s: Dictionary) -> void:
	cancel_pending()
	sketch = s
	status = game.doc.solve_sketch(sketch)
	_index()
	changed.emit()


# ---------- helpers ----------

func _index() -> void:
	_pts = {"o": Vector2.ZERO}
	for p in sketch.points:
		_pts[p.id] = Vector2(float(p.x), float(p.y))
	_ents = {}
	for e in sketch.entities:
		_ents[e.id] = e


func _new_id(s: Dictionary, prefix: String) -> String:
	var used := {}
	for k in ["points", "entities", "constraints"]:
		for item in s[k]:
			used[item.id] = true
	var i := 1
	while used.has("%s%d" % [prefix, i]):
		i += 1
	return "%s%d" % [prefix, i]


## Id of the spot's point, adding a new point to s when the spot is free.
func _point(s: Dictionary, spot: Dictionary) -> String:
	if spot.id != "":
		return spot.id
	var id := _new_id(s, "p")
	s.points.append({id = id, x = (spot.uv as Vector2).x, y = (spot.uv as Vector2).y})
	spot.id = id
	return id


func _entity(id: String, kind: String, pts: Array) -> Dictionary:
	return {id = id, kind = kind, pts = pts, construction = option() == "construction"}


func _auto_hv(s: Dictionary, line_id: String, a: Vector2, b: Vector2) -> void:
	if absf(a.y - b.y) < 1e-12:
		s.constraints.append({id = _new_id(s, "c"), kind = "horizontal", refs = [line_id]})
	elif absf(a.x - b.x) < 1e-12:
		s.constraints.append({id = _new_id(s, "c"), kind = "vertical", refs = [line_id]})


func _find_constraint(kind: String, refs: Array) -> Dictionary:
	for c in sketch.constraints:
		if c.kind == kind and _same_refs(c.refs, refs):
			return c
	return {}


func _same_refs(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if String(a[i]) != String(b[i]):
			return false
	return true


func _prefer_points() -> bool:
	match tool().id:
		"dimension":
			return true
		"relation":
			return option() == "fix" or (option() == "coincident" and _picks.is_empty())
	return false


## The point or entity under the crosshair, within the pick tolerance.
func _target(prefer_points: bool) -> Dictionary:
	var pt := {}
	var bp := _tol
	for id in _pts:
		var d: float = (_pts[id] as Vector2).distance_to(_raw)
		if d < bp:
			bp = d
			pt = {kind = "point", id = id}
	var ent := {}
	var be := _tol
	for id in _ents:
		var d := _distance_to(_ents[id], _raw)
		if d < be:
			be = d
			ent = {kind = "entity", id = id}
	if prefer_points:
		return pt if not pt.is_empty() else ent
	return ent if not ent.is_empty() else pt


func _distance_to(e: Dictionary, p: Vector2) -> float:
	match e.kind:
		"line":
			var a: Vector2 = _pts.get(e.pts[0], Vector2.ZERO)
			var b: Vector2 = _pts.get(e.pts[1], Vector2.ZERO)
			return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))
		"circle":
			return absf((_pts.get(e.pts[0], Vector2.ZERO) as Vector2).distance_to(p) - float(e.r))
		"arc":
			var c: Vector2 = _pts.get(e.pts[0], Vector2.ZERO)
			var s: Vector2 = _pts.get(e.pts[1], Vector2.ZERO)
			var en: Vector2 = _pts.get(e.pts[2], Vector2.ZERO)
			var a0 := (s - c).angle()
			var sweep := fposmod((en - c).angle() - a0, TAU)
			if sweep < 1e-9:
				sweep = TAU
			if fposmod((p - c).angle() - a0, TAU) <= sweep:
				return absf(c.distance_to(p) - c.distance_to(s))
			return minf(p.distance_to(s), p.distance_to(en))
	return INF


func _w(uv: Vector2, lift := 0.0) -> Vector3:
	return _o + _x * uv.x + _y * uv.y + _n * lift


func _polyline(e: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	match e.kind:
		"line":
			out.append(_pts.get(e.pts[0], Vector2.ZERO))
			out.append(_pts.get(e.pts[1], Vector2.ZERO))
		"circle":
			var c: Vector2 = _pts.get(e.pts[0], Vector2.ZERO)
			for i in 65:
				out.append(c + Vector2.from_angle(TAU * i / 64.0) * float(e.r))
		"arc":
			var c: Vector2 = _pts.get(e.pts[0], Vector2.ZERO)
			var s: Vector2 = _pts.get(e.pts[1], Vector2.ZERO)
			var en: Vector2 = _pts.get(e.pts[2], Vector2.ZERO)
			out = _arc_points(c, s, (en - c).angle())
	return out


func _arc_points(c: Vector2, s: Vector2, end_angle: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var r := c.distance_to(s)
	var a0 := (s - c).angle()
	var sweep := fposmod(end_angle - a0, TAU)
	if sweep < 1e-9:
		sweep = TAU
	var n := maxi(4, int(ceil(sweep / TAU * 64.0)))
	for i in n + 1:
		out.append(c + Vector2.from_angle(a0 + sweep * i / n) * r)
	return out


# ---------- display ----------

func _redraw() -> void:
	var im: ImmediateMesh = _lines.mesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var base := COLOR_DEFINED if defined() else COLOR_FREE
	var picked := {}
	for p in _picks:
		picked[p.id] = true
	for id in _ents:
		var e: Dictionary = _ents[id]
		var color := COLOR_CONSTRUCTION if e.get("construction", false) else base
		if picked.has(id) or (_hover.get("kind", "") == "entity" and _hover.id == id):
			color = COLOR_ACTIVE
		_strip(im, _polyline(e), color, e.get("construction", false))
	# Points, the origin axes and the cursor.
	var d := _tol * 0.35
	for id in _pts:
		var c := COLOR_ACTIVE if (picked.has(id) or (_hover.get("kind", "") == "point" and _hover.id == id)) else base
		if id != "o":
			_cross(im, _pts[id], d, c)
	_seg(im, Vector2.ZERO, Vector2(_tol * 3.0, 0), Color("ff5d5d"))
	_seg(im, Vector2.ZERO, Vector2(0, _tol * 3.0), Color("6ee06e"))
	if _valid:
		_rubber_band(im)
		_cross(im, _cursor, _tol * 0.6, COLOR_ACTIVE)
		if _snap_id != "":
			var k := _tol * 0.5
			_strip(im, PackedVector2Array([_cursor + Vector2(-k, -k), _cursor + Vector2(k, -k),
				_cursor + Vector2(k, k), _cursor + Vector2(-k, k), _cursor + Vector2(-k, -k)]), COLOR_ACTIVE, false)
	im.surface_end()
	_draw_grid()
	_draw_labels()


func _rubber_band(im: ImmediateMesh) -> void:
	if _pending.is_empty():
		return
	var a: Vector2 = _pending[0].uv
	match tool().id:
		"line":
			_seg(im, a, _cursor, COLOR_ACTIVE)
		"rect":
			_strip(im, PackedVector2Array([a, Vector2(_cursor.x, a.y), _cursor, Vector2(a.x, _cursor.y), a]), COLOR_ACTIVE, false)
		"circle":
			var r := _snapped_radius(a, {id = _snap_id, uv = _cursor})
			var pts := PackedVector2Array()
			for i in 65:
				pts.append(a + Vector2.from_angle(TAU * i / 64.0) * r)
			_strip(im, pts, COLOR_ACTIVE, false)
		"arc":
			if _pending.size() == 1:
				_seg(im, a, _cursor, COLOR_ACTIVE)
			else:
				var s: Vector2 = _pending[1].uv
				var end_angle := (_cursor - a).angle()
				var pts := _arc_points(a, s, end_angle) if option() != "clockwise" else _arc_points(a, a + Vector2.from_angle(end_angle) * a.distance_to(s), (s - a).angle())
				_strip(im, pts, COLOR_ACTIVE, false)


func _seg(im: ImmediateMesh, a: Vector2, b: Vector2, color: Color) -> void:
	im.surface_set_color(color)
	im.surface_add_vertex(_w(a))
	im.surface_set_color(color)
	im.surface_add_vertex(_w(b))


func _strip(im: ImmediateMesh, pts: PackedVector2Array, color: Color, dashed: bool) -> void:
	if not dashed:
		for i in pts.size() - 1:
			_seg(im, pts[i], pts[i + 1], color)
		return
	var dash := _tol * 0.8
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var n := maxi(1, int(a.distance_to(b) / dash))
		for k in range(0, n, 2):
			_seg(im, a.lerp(b, float(k) / n), a.lerp(b, float(mini(k + 1, n)) / n), color)


func _cross(im: ImmediateMesh, p: Vector2, d: float, color: Color) -> void:
	_seg(im, p + Vector2(-d, 0), p + Vector2(d, 0), color)
	_seg(im, p + Vector2(0, -d), p + Vector2(0, d), color)


func _draw_grid() -> void:
	var im: ImmediateMesh = _grid.mesh
	im.clear_surfaces()
	var step: float = game.player.grid_step()
	var centre := _raw if _valid else Vector2.ZERO
	centre = Vector2(snappedf(centre.x, step), snappedf(centre.y, step))
	var n := 12
	var lift: float = 0.0015 * game.player.size
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(-n, n + 1):
		var fade := COLOR_GRID * Color(1, 1, 1, 1.0 - absf(i) / float(n + 1))
		for pair in [[Vector2(centre.x + i * step, centre.y - n * step), Vector2(centre.x + i * step, centre.y + n * step)],
				[Vector2(centre.x - n * step, centre.y + i * step), Vector2(centre.x + n * step, centre.y + i * step)]]:
			im.surface_set_color(fade)
			im.surface_add_vertex(_w(pair[0], lift))
			im.surface_set_color(fade)
			im.surface_add_vertex(_w(pair[1], lift))
	im.surface_end()


func _draw_labels() -> void:
	var shown := 0
	for c in sketch.constraints:
		if not c.has("value") or c.value == null:
			continue
		var pos: Variant = _label_position(c)
		if pos == null:
			continue
		var l := _label(shown)
		shown += 1
		l.position = _w(pos)
		l.text = _dimension_text(c)
	for i in range(shown, _labels.size()):
		_labels[i].visible = false


func _label(i: int) -> Label3D:
	while _labels.size() <= i:
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.fixed_size = true
		l.pixel_size = 0.0008 * preload("res://scripts/ui_theme.gd").ui_scale
		l.font_size = 30
		l.outline_size = 10
		l.modulate = COLOR_DIM
		l.outline_modulate = Color(0, 0, 0, 0.85)
		l.render_priority = 30
		l.outline_render_priority = 29
		add_child(l)
		_labels.append(l)
	_labels[i].visible = true
	return _labels[i]


func _label_position(c: Dictionary) -> Variant:
	var refs: Array = c.refs
	match c.kind:
		"distance", "hdistance", "vdistance":
			if refs.size() == 1 and _ents.has(refs[0]):
				var e: Dictionary = _ents[refs[0]]
				var a: Vector2 = _pts.get(e.pts[0], Vector2.ZERO)
				var b: Vector2 = _pts.get(e.pts[1], Vector2.ZERO)
				var side := (b - a).orthogonal().normalized() * _tol * 1.2
				return (a + b) / 2.0 + side
			if refs.size() == 2 and _pts.has(refs[0]) and _pts.has(refs[1]):
				return (_pts[refs[0]] + _pts[refs[1]]) / 2.0
		"diameter", "radius":
			if _ents.has(refs[0]):
				var e: Dictionary = _ents[refs[0]]
				var c0: Vector2 = _pts.get(e.pts[0], Vector2.ZERO)
				if e.kind == "circle":
					return c0 + Vector2(0.7071, 0.7071) * float(e.r)
				var poly := _polyline(e)
				return poly[poly.size() >> 1]
		"angle":
			if _ents.has(refs[0]):
				var e: Dictionary = _ents[refs[0]]
				return ((_pts.get(e.pts[0], Vector2.ZERO) as Vector2) + _pts.get(e.pts[1], Vector2.ZERO)) / 2.0
	return null


func _dimension_text(c: Dictionary) -> String:
	var prefix: String = {diameter = "⌀", radius = "R", hdistance = "↔ ", vdistance = "↕ "}.get(c.kind, "")
	if c.value is String:
		return prefix + String(c.value)
	if c.kind == "angle":
		return "%.1f°" % rad_to_deg(float(c.value))
	return prefix + game.hud.length(float(c.value))


func _aim_label() -> String:
	if not _valid:
		return "Aim at the sketch plane"
	if not _pending.is_empty():
		var a: Vector2 = _pending[0].uv
		match tool().id:
			"line":
				return "Line %s" % game.hud.length(a.distance_to(_cursor))
			"rect":
				return "%s × %s" % [game.hud.length(absf(_cursor.x - a.x)), game.hud.length(absf(_cursor.y - a.y))]
			"circle":
				return "⌀ %s" % game.hud.length(2.0 * _snapped_radius(a, {id = _snap_id, uv = _cursor}))
			"arc":
				return "R %s" % game.hud.length(a.distance_to(_cursor if _pending.size() == 1 else _pending[1].uv))
	if tool().id in ["dimension", "relation", "erase"] and not _hover.is_empty():
		var what: String = "Origin" if _hover.id == "o" else ("Point" if _hover.kind == "point" else KIND_NAMES.get(_ents[_hover.id].kind, "Entity"))
		match tool().id:
			"erase":
				return "Delete " + what.to_lower()
			"relation":
				return "%s · %s" % [option().capitalize(), what.to_lower()]
		return "Dimension " + what.to_lower()
	if _snap_id == "o":
		return "Origin"
	if _snap_id != "":
		return "On point"
	return "%s, %s" % [game.hud.length(_cursor.x), game.hud.length(_cursor.y)]


## Flies the player to look straight at the sketch, from the side they are on.
func look_normal_to() -> void:
	var p: Node3D = game.player
	var centre := Vector2.ZERO
	for id in _pts:
		centre += _pts[id]
	centre /= _pts.size()
	var extent := 0.0
	for id in _pts:
		extent = maxf(extent, centre.distance_to(_pts[id]))
	for e in sketch.entities:
		if e.kind == "circle":
			extent = maxf(extent, centre.distance_to(_pts.get(e.pts[0], Vector2.ZERO)) + float(e.r))
	var target := _w(centre)
	var n := _n
	if (p.eye_position() - target).dot(n) < 0.0:
		n = -n
	var dist := maxf(extent * 2.6, 2.5 * p.size)
	p.fly = true
	p.feet = target + n * dist - Vector3(0, p.EYE * p.size, 0)
	p.pitch = clampf(asin(clampf(-n.y, -1.0, 1.0)), -1.55, 1.55)
	if absf(n.y) < 0.999:
		p.yaw = atan2(n.x, n.z)
	game.hud.toast("Looking straight at the sketch · flying")
