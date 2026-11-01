extends Node3D
## Sketch mode: draw on a plane the way a desktop CAD sketcher works, from first person.
##
## The crosshair ray meets the sketch plane at the cursor. Drawing tools (lines, rectangles,
## polygons, slots, points, circles, arcs, ellipses, splines) snap to existing points, the sketch
## origin and the grid. Editing tools trim, extend, fillet, chamfer, offset, move, copy, mirror
## and pattern geometry, and copy a model face's edges in. Relations (horizontal, parallel,
## tangent, symmetric…) and dimensions hold the geometry; every change is solved by the CAD core,
## which reports the degrees of freedom left or refuses a conflicting change. Finishing adds (or
## updates) a sketch feature in the part's history; Extrude, Revolve, Sweep and Loft use it.
##
## main.gd routes input here while a sketch is open and calls update() every frame.

signal ended(feature_id: String, committed: bool)
signal changed

const Units := preload("res://scripts/units.gd")
const SG := preload("res://scripts/sketch_geom.gd")
const RELATIONS := ["horizontal", "vertical", "coincident", "parallel", "perpendicular", "tangent", "equal",
	"collinear", "concentric", "midpoint", "symmetric", "fix"]
const TOOLS := [
	{id = "line", name = "Line", pri = "place point (chains)", alt = "end the chain", opt = []},
	{id = "rect", name = "Corner rectangle", pri = "corner, then opposite corner", alt = "cancel", opt = []},
	{id = "rect_centre", name = "Centre rectangle", pri = "centre, then a corner", alt = "cancel", opt = []},
	{id = "rect_3pt", name = "3-point rectangle", pri = "both ends of one side, then the width", alt = "cancel", opt = []},
	{id = "polygon", name = "Polygon", pri = "centre, then a corner", alt = "number of sides", opt = []},
	{id = "slot", name = "Slot", pri = "one end's centre, the other end's, then the width", alt = "cancel", opt = []},
	{id = "point", name = "Point", pri = "place a point", alt = "cancel", opt = []},
	{id = "circle", name = "Circle", pri = "centre, then edge", alt = "cancel", opt = []},
	{id = "circle_3pt", name = "3-point circle", pri = "three points on the circle", alt = "cancel", opt = []},
	{id = "arc", name = "Centre arc", pri = "centre, start, end (the shorter way round)", alt = "cancel", opt = []},
	{id = "arc_3pt", name = "3-point arc", pri = "start, end, then a point it passes through", alt = "cancel", opt = []},
	{id = "arc_tangent", name = "Tangent arc", pri = "end of a line or arc, then the arc's end (chains)", alt = "end the chain", opt = []},
	{id = "ellipse", name = "Ellipse", pri = "centre, end of one axis, then the other axis", alt = "cancel", opt = []},
	{id = "spline", name = "Spline", pri = "points it passes through; the first again closes it", alt = "finish the spline", opt = []},
	{id = "text", name = "Text", pri = "where the text starts, or text to change", alt = "cancel", opt = []},
	{id = "trim", name = "Trim", pri = "the piece to cut away, up to where it crosses", alt = "cancel", opt = []},
	{id = "split", name = "Split", pri = "where to split a line or arc (a circle takes two)", alt = "cancel", opt = []},
	{id = "extend", name = "Extend", pri = "a line, near the end to lengthen", alt = "cancel", opt = []},
	{id = "fillet", name = "Fillet", pri = "a corner where two lines meet", alt = "set the radius", opt = []},
	{id = "chamfer", name = "Chamfer", pri = "a corner where two lines meet", alt = "set the distance", opt = []},
	{id = "offset", name = "Offset", pri = "a chain, on the side to offset to", alt = "set the distance", opt = []},
	{id = "convert", name = "Convert edges", pri = "a model face: its edges are copied in", alt = "cancel", opt = []},
	{id = "move", name = "Move", pri = "geometry or a point, then where it goes (or the centre to turn or scale about)", alt = "cancel", opt = ["move", "copy", "rotate", "scale"]},
	{id = "mirror", name = "Mirror", pri = "the mirror line, then each chain to mirror", alt = "pick another mirror line", opt = []},
	{id = "pattern_linear", name = "Linear pattern", pri = "a chain, then where its first copy goes", alt = "cancel", opt = []},
	{id = "pattern_circular", name = "Circular pattern", pri = "a chain, then the centre", alt = "cancel", opt = []},
	{id = "construct", name = "Construction", pri = "switch geometry to construction and back", alt = "cancel", opt = []},
	{id = "dimension", name = "Dimension", pri = "a line, curve or point; a second for angles and distances", alt = "cancel", opt = ["aligned", "horizontal", "vertical"]},
	{id = "relation", name = "Relation", pri = "pick geometry to relate", alt = "cancel", opt = RELATIONS},
	{id = "erase", name = "Delete", pri = "delete geometry", alt = "remove its relations and dimensions", opt = []},
]
const FatLines := preload("res://scripts/fat_lines.gd")
# Colours that read on the white room and on parts: blue while geometry can still move, near
# black once fully defined, grey (dashed) for construction, orange for what is being worked on.
const COLOR_FREE := Color("1f6fd1")
const COLOR_DEFINED := Color("1b2129")
const COLOR_CONSTRUCTION := Color("7d8794")
const COLOR_ACTIVE := Color("ff7a1f")
const COLOR_DIM := Color("ffd166")
const COLOR_GRID := Color(0.22, 0.28, 0.36, 0.22)
const FAT := {"1f6fd1": 3.0, "1b2129": 3.0, "7d8794": 2.0, "ff7a1f": 3.5}  # colour -> on-screen width
const DRAW_TOOLS := ["line", "rect", "rect_centre", "rect_3pt", "polygon", "slot", "point", "circle", "circle_3pt",
	"arc", "arc_3pt", "arc_tangent", "ellipse", "spline", "text"]
const KIND_NAMES := {line = "Line", circle = "Circle", arc = "Arc", ellipse = "Ellipse", spline = "Spline", text = "Text"}
const SIDES := [3, 4, 5, 6, 8, 10, 12]

var game: Node  # main.gd
var active := false
var sketch := {}
var edit_id := ""
var status := {ok = true, dof = 0, message = ""}
var index := 0
var options := {}
## New geometry from the drawing tools is construction geometry: dashed, for reference
## (centrelines, revolve axes), never part of a closed profile. LB toggles it while drawing.
var construction_mode := false
var polygon_sides := 6
## Values the fillet, chamfer and offset tools reuse (SI number or expression), set with the
## alternate button or asked for on first use.
var fillet_radius: Variant = null
var chamfer_distance: Variant = null
var offset_distance: Variant = null
## Cap height for new text (SI); dimension a text to change it.
var text_height := 0.0

var _o := Vector3.ZERO
var _n := Vector3.UP
var _x := Vector3.RIGHT
var _y := Vector3.FORWARD
var _pts := {}   # point id -> Vector2 (includes the origin "o")
var _fixed := {} # point id -> true for fixed points
var _ents := {}  # entity id -> Dictionary
var _curves := {}  # spline id -> PackedVector2Array, sampled by the core
var _pending: Array = []  # spots placed for the entity being drawn: {id, uv}
var _picks: Array = []    # picks for editing tools, dimensions and relations: {kind, id, ...}
var _history: Array = []
var _future: Array = []
var _raw := Vector2.ZERO     # where the crosshair meets the plane
var _cursor := Vector2.ZERO  # after snapping
var _snap_id := ""
var _snap_mid := ""  # line whose midpoint the cursor snapped to
var _snap_on := ""   # line or curve the cursor snapped onto
var _valid := false
var _tol := 0.01
var _hover := {}
var _lines := MeshInstance3D.new()
var _grid := MeshInstance3D.new()
var _labels: Array[Label3D] = []
var _fat := {}        # colour -> this frame's line list
var _fat_nodes := {}  # colour -> MeshInstance3D drawing it
var _fill := MeshInstance3D.new()  # closed profiles, shaded
var _fill_mat := StandardMaterial3D.new()
var _pose := {}  # where the player was before the sketch, restored when it closes
var _drag := {}       # Move: the solved sketch as it would be at the cursor, shown while moving
var _drag_delta := Vector2(INF, INF)


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
	_fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_fill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fill_mat.no_depth_test = true
	_fill_mat.render_priority = 15
	_fill.material_override = _fill_mat
	_fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_fill)
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
	_pose = game.player.pose()
	_enter_sketch_view(edit != "")
	return true


## Adds the sketch to the part (or updates the edited one) and leaves sketch mode.
func finish() -> void:
	if not active:
		return
	_pending.clear()
	_picks.clear()
	var has_geometry: bool = not (sketch.entities as Array).is_empty() or not (sketch.points as Array).is_empty()
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
	if not _pose.is_empty():
		game.player.restore_pose(_pose)
		_pose = {}
	_pending.clear()
	_picks.clear()
	for l in _labels:
		l.visible = false


func has_pending() -> bool:
	return not _pending.is_empty() or not _picks.is_empty()


func cancel_pending() -> void:
	_pending.clear()
	_picks.clear()
	_drag = {}


# ---------- tools ----------

## Sketch tools grouped for the tool wheel (values are TOOLS indices).
const WHEEL := [
	["Lines", "Lines, rectangles, polygons, slots and points", ["line", "rect", "rect_centre", "rect_3pt", "polygon", "slot", "point"]],
	["Curves", "Circles, arcs, ellipses and splines", ["circle", "circle_3pt", "arc", "arc_3pt", "arc_tangent", "ellipse", "spline"]],
	["Modify", "Trim, extend, split, fillet, chamfer, offset, convert edges", ["trim", "extend", "split", "fillet", "chamfer", "offset", "convert"]],
	["Copy", "Move, copy, rotate, scale, mirror and pattern", ["move", "mirror", "pattern_linear", "pattern_circular"]],
	["Constrain", "Dimensions and relations that hold the sketch", ["dimension", "relation"]],
	"text",
	"construct",
	"erase",
]


func wheel_tree() -> Array:
	var out := []
	for entry in WHEEL:
		if entry is String:
			out.append(_wheel_node(entry))
		else:
			var kids := []
			for id in entry[2]:
				kids.append(_wheel_node(id))
			out.append({name = entry[0], desc = entry[1], children = kids})
	return out


func _wheel_node(id: String) -> Dictionary:
	for i in TOOLS.size():
		if TOOLS[i].id == id:
			return {name = TOOLS[i].name, pri = TOOLS[i].pri, alt = TOOLS[i].alt, value = i}
	return {}


func tool() -> Dictionary:
	return TOOLS[index]


func option() -> String:
	if tool().id in DRAW_TOOLS:
		var mode := "construction" if construction_mode else "solid"
		return "%d sides · %s" % [polygon_sides, mode] if tool().id == "polygon" else mode
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


## Chooses a Relation (or another tool's option) by name.
func set_option(id: String, value: String) -> void:
	for t in TOOLS:
		if t.id == id:
			var k: int = (t.opt as Array).find(value)
			if k >= 0:
				options[id] = k


func cycle_option() -> void:
	if tool().id in DRAW_TOOLS:
		construction_mode = not construction_mode
		game.hud.toast("Construction geometry " + ("on: dashed, never part of a profile" if construction_mode else "off"))
		return
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
	var state: String = status.message if (sketch.entities as Array).size() > 0 or (sketch.points as Array).size() > 0 else "empty"
	return "%s on %s  ·  %s" % [what, sketch.get("planeName", "plane"), state]


func defined() -> bool:
	return status.ok and int(status.dof) == 0


# ---------- per frame ----------

func update() -> void:
	if not active:
		return
	_aim(game.player.eye_position(), game.player.aim_direction())
	_hover = _target(_prefer_points()) if _valid else {}
	_update_drag()
	_redraw()
	game.hud.set_aim(_aim_label(), _snap_id != "" or _snap_mid != "" or _snap_on != "" or not _hover.is_empty())


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
	_snap_mid = ""
	_snap_on = ""
	var best := _tol
	for id in _pts:
		var d: float = (_pts[id] as Vector2).distance_to(_raw)
		if d < best:
			best = d
			_snap_id = id
	if _snap_id != "":
		_cursor = _pts[_snap_id]
		return
	# Then the middle of a line, then anywhere on a line or curve: a point placed there stays
	# there (a midpoint or point-on relation).
	if tool().id in DRAW_TOOLS:
		for id in _ents:
			var e: Dictionary = _ents[id]
			if e.kind == "line":
				var m := (_p(e.pts[0]) + _p(e.pts[1])) / 2.0
				if m.distance_to(_raw) < best:
					best = m.distance_to(_raw)
					_snap_mid = id
					_cursor = m
		if _snap_mid != "":
			return
		var near := _tol * 0.6
		for id in _ents:
			var e: Dictionary = _ents[id]
			if not e.kind in ["line", "circle", "arc"]:
				continue
			var prim := _prim(e)
			var d := SG.distance(prim, _raw)
			if d < near:
				var at: Vector2 = Geometry2D.get_closest_point_to_segment(_raw, prim.a, prim.b) if e.kind == "line" \
					else (prim.c as Vector2) + (_raw - prim.c).normalized() * float(prim.r)
				if SG.distance(prim, at) < 1e-9 * maxf(1.0, at.length()):
					near = d
					_snap_on = id
					_cursor = at
		if _snap_on != "":
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
	if tool().id == "convert":
		_convert(primary)
		return
	if not _valid:
		game.hud.toast("Aim at the sketch plane")
		return
	var spot := {id = _snap_id, uv = _cursor, mid = _snap_mid, on = _snap_on}
	match tool().id:
		"line":
			_line(primary, spot)
		"rect":
			_rect(primary, spot)
		"rect_centre":
			_rect_centre(primary, spot)
		"rect_3pt":
			_rect_3pt(primary, spot)
		"polygon":
			_polygon(primary, spot)
		"slot":
			_slot(primary, spot)
		"point":
			_point_tool(primary, spot)
		"circle":
			_circle(primary, spot)
		"circle_3pt":
			_circle_3pt(primary, spot)
		"arc":
			_arc(primary, spot)
		"arc_3pt":
			_arc_3pt(primary, spot)
		"arc_tangent":
			_arc_tangent(primary, spot)
		"ellipse":
			_ellipse(primary, spot)
		"spline":
			_spline(primary, spot)
		"text":
			_text_tool(primary, spot)
		"split":
			_split(primary)
		"trim":
			_trim(primary)
		"extend":
			_extend(primary)
		"fillet":
			_corner_tool(primary, "fillet")
		"chamfer":
			_corner_tool(primary, "chamfer")
		"offset":
			_offset(primary)
		"move":
			_move(primary)
		"mirror":
			_mirror(primary)
		"pattern_linear", "pattern_circular":
			_pattern(primary, tool().id == "pattern_circular")
		"dimension":
			_dimension(primary)
		"relation":
			_relation(primary)
		"erase":
			_erase(primary)
		"construct":
			_construct(primary)


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


## Two clicks (or more) collected into _pending; returns true once there are n.
func _collect(primary: bool, spot: Dictionary, n: int) -> bool:
	if not primary:
		_pending.clear()
		return false
	if _pending.size() < n - 1:
		for p in _pending:
			if (p.uv as Vector2).distance_to(spot.uv) < 1e-12:
				return false
		_pending.append(spot)
		return false
	return true


## Four lines round the corner ids, horizontal and vertical in turn.
func _box(s: Dictionary, ids: Array) -> Array:
	var lines := []
	for i in 4:
		var lid := _new_id(s, "l")
		s.entities.append(_entity(lid, "line", [ids[i], ids[(i + 1) % 4]]))
		_con(s, "horizontal" if i % 2 == 0 else "vertical", [lid])
		lines.append(lid)
	return lines


func _rect(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 2):
		return
	var a: Dictionary = _pending[0]
	var au: Vector2 = a.uv
	var cu: Vector2 = spot.uv
	if absf(au.x - cu.x) < 1e-12 or absf(au.y - cu.y) < 1e-12:
		game.hud.toast("A rectangle needs width and height")
		return
	var s: Dictionary = sketch.duplicate(true)
	var ids := [_point(s, a), _point(s, _free(Vector2(cu.x, au.y))), _point(s, spot), _point(s, _free(Vector2(au.x, cu.y)))]
	_box(s, ids)
	if _commit(s, "Rectangle"):
		_pending.clear()


func _rect_centre(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 2):
		return
	var c: Vector2 = _pending[0].uv
	var k: Vector2 = spot.uv
	var h := (k - c).abs()
	if h.x < 1e-12 or h.y < 1e-12:
		game.hud.toast("A rectangle needs width and height")
		return
	var s: Dictionary = sketch.duplicate(true)
	var idc := _point(s, _pending[0])
	var ids := []
	for u in [c - h, c + Vector2(h.x, -h.y), c + h, c + Vector2(-h.x, h.y)]:
		ids.append(_point(s, spot if (u as Vector2).distance_to(k) < 1e-12 else _free(u)))
	_box(s, ids)
	# Construction diagonals, with the centre held at their middle.
	var d1 := _new_id(s, "l")
	s.entities.append({id = d1, kind = "line", pts = [ids[0], ids[2]], construction = true})
	var d2 := _new_id(s, "l")
	s.entities.append({id = d2, kind = "line", pts = [ids[1], ids[3]], construction = true})
	_con(s, "midpoint", [idc, d1])
	if _commit(s, "Rectangle"):
		_pending.clear()


func _rect_3pt(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 3):
		return
	var a: Vector2 = _pending[0].uv
	var b: Vector2 = _pending[1].uv
	var u := (b - a).normalized()
	var nrm := Vector2(-u.y, u.x)
	var w := ((spot.uv as Vector2) - b).dot(nrm)
	if absf(w) < 1e-12:
		game.hud.toast("Move the third point off the first side to give the rectangle a width")
		return
	var c := b + nrm * w
	var d := a + nrm * w
	var s: Dictionary = sketch.duplicate(true)
	var ids := [_point(s, _pending[0]), _point(s, _pending[1]),
		_point(s, spot if (spot.uv as Vector2).distance_to(c) < 1e-9 else _free(c)), _point(s, _free(d))]
	var lines := []
	for i in 4:
		var lid := _new_id(s, "l")
		s.entities.append(_entity(lid, "line", [ids[i], ids[(i + 1) % 4]]))
		lines.append(lid)
	_auto_hv(s, lines[0], a, b)
	if (s.constraints as Array).is_empty() or s.constraints[-1].refs != [lines[0]]:
		_con(s, "perpendicular", [lines[0], lines[1]])
	else:
		_auto_hv(s, lines[1], b, c)
	_con(s, "parallel", [lines[0], lines[2]])
	_con(s, "parallel", [lines[1], lines[3]])
	if _commit(s, "Rectangle"):
		_pending.clear()


func _polygon(primary: bool, spot: Dictionary) -> void:
	if not primary and _pending.is_empty():
		polygon_sides = SIDES[(SIDES.find(polygon_sides) + 1) % SIDES.size()]
		game.hud.toast("Polygon: %d sides" % polygon_sides)
		return
	if not _collect(primary, spot, 2):
		return
	var c: Vector2 = _pending[0].uv
	var v0: Vector2 = spot.uv
	var r := c.distance_to(v0)
	var s: Dictionary = sketch.duplicate(true)
	var idc := _point(s, _pending[0])
	# Corners on a construction circle, sides all equal.
	var kid := _new_id(s, "k")
	s.entities.append({id = kid, kind = "circle", pts = [idc], r = r, construction = true})
	var ids := []
	for i in polygon_sides:
		var u := c + (v0 - c).rotated(TAU * i / polygon_sides)
		var pid := _point(s, spot if i == 0 else _free(u))
		ids.append(pid)
		_con(s, "point_on_circle", [pid, kid])
	var first := ""
	for i in polygon_sides:
		var lid := _new_id(s, "l")
		s.entities.append(_entity(lid, "line", [ids[i], ids[(i + 1) % polygon_sides]]))
		if first == "":
			first = lid
		else:
			_con(s, "equal", [first, lid])
	if _commit(s, "Polygon"):
		_pending.clear()


func _slot(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 3):
		return
	var c1: Vector2 = _pending[0].uv
	var c2: Vector2 = _pending[1].uv
	var u := (c2 - c1).normalized()
	var nrm := Vector2(-u.y, u.x)
	var r := absf(((spot.uv as Vector2) - c1).dot(nrm))
	if r < 1e-12:
		game.hud.toast("Move off the centre line to give the slot a width")
		return
	var s: Dictionary = sketch.duplicate(true)
	var i1 := _point(s, _pending[0])
	var i2 := _point(s, _pending[1])
	var p1 := _point(s, _free(c1 + nrm * r))
	var p2 := _point(s, _free(c2 + nrm * r))
	var p3 := _point(s, _free(c2 - nrm * r))
	var p4 := _point(s, _free(c1 - nrm * r))
	var cl := _new_id(s, "l")
	s.entities.append({id = cl, kind = "line", pts = [i1, i2], construction = true})
	_auto_hv(s, cl, c1, c2)
	var top := _new_id(s, "l")
	s.entities.append(_entity(top, "line", [p1, p2]))
	var bottom := _new_id(s, "l")
	s.entities.append(_entity(bottom, "line", [p3, p4]))
	var a2 := _new_id(s, "a")
	s.entities.append(_entity(a2, "arc", [i2, p3, p2]))  # round the far end, counter-clockwise
	var a1 := _new_id(s, "a")
	s.entities.append(_entity(a1, "arc", [i1, p1, p4]))
	for l in [top, bottom]:
		for a in [a1, a2]:
			_con(s, "tangent", [l, a])
	_con(s, "equal", [a1, a2])
	if _commit(s, "Slot"):
		_pending.clear()


func _point_tool(primary: bool, spot: Dictionary) -> void:
	if not primary:
		return
	if spot.id != "":
		game.hud.toast("There is a point there already")
		return
	var s: Dictionary = sketch.duplicate(true)
	_point(s, spot)
	_commit(s, "Point")


func _circle(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 2):
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


func _circle_3pt(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 3):
		return
	var centre: Variant = SG.circumcentre(_pending[0].uv, _pending[1].uv, spot.uv)
	if centre == null:
		game.hud.toast("Those three points are in a line")
		return
	var s: Dictionary = sketch.duplicate(true)
	var idc := _point(s, _free(centre))
	var kid := _new_id(s, "k")
	var e := _entity(kid, "circle", [idc])
	e.r = (centre as Vector2).distance_to(spot.uv)
	s.entities.append(e)
	# Points that were already there stay on the circle.
	for sp in [_pending[0], _pending[1], spot]:
		if sp.id != "":
			_con(s, "point_on_circle", [sp.id, kid])
	if _commit(s, "Circle"):
		_pending.clear()


func _arc(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 3):
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
	# Arcs run counter-clockwise from their start to their end; take the shorter way round.
	var ccw := fposmod((end_spot.uv - cu).angle() - (su - cu).angle(), TAU) <= PI
	var arc := _entity(_new_id(s, "a"), "arc", [idc, ids, ide] if ccw else [idc, ide, ids])
	s.entities.append(arc)
	if _commit(s, "Arc"):
		_pending.clear()


func _arc_3pt(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 3):
		return
	var su: Vector2 = _pending[0].uv
	var eu: Vector2 = _pending[1].uv
	var mu: Vector2 = spot.uv
	var centre: Variant = SG.circumcentre(su, eu, mu)
	if centre == null:
		game.hud.toast("Those three points are in a line")
		return
	var c: Vector2 = centre
	# Counter-clockwise from start to end if that way passes through the third point.
	var ccw := fposmod((mu - c).angle() - (su - c).angle(), TAU) < fposmod((eu - c).angle() - (su - c).angle(), TAU)
	var s: Dictionary = sketch.duplicate(true)
	var idc := _point(s, _free(c))
	var ids := _point(s, _pending[0])
	var ide := _point(s, _pending[1])
	var aid := _new_id(s, "a")
	s.entities.append(_entity(aid, "arc", [idc, ids, ide] if ccw else [idc, ide, ids]))
	if spot.id != "":
		_con(s, "point_on_circle", [spot.id, aid])
	if _commit(s, "Arc"):
		_pending.clear()


## Direction a curve leaves the point spot, continuing smoothly from the line or arc that ends
## there: {dir, ent}, or {} when no line or arc ends at the point.
func _end_tangent(point_id: String) -> Dictionary:
	if point_id == "":
		return {}
	var found := {}
	for id in _ents:
		var e: Dictionary = _ents[id]
		var t := Vector2.ZERO
		if e.kind == "line" and point_id in e.pts:
			var other: String = e.pts[1] if e.pts[0] == point_id else e.pts[0]
			t = (_p(point_id) - _p(other)).normalized()
		elif e.kind == "arc" and (e.pts[1] == point_id or e.pts[2] == point_id):
			var r := _p(point_id) - _p(e.pts[0])
			t = Vector2(-r.y, r.x).normalized() * (1.0 if e.pts[2] == point_id else -1.0)
		elif e.kind == "spline" and _curves.has(id) and (e.pts[0] == point_id or e.pts[-1] == point_id) and e.pts[0] != e.pts[-1]:
			var c: PackedVector2Array = _curves[id]
			t = ((c[0] - c[1]) if e.pts[0] == point_id else (c[c.size() - 1] - c[c.size() - 2])).normalized()
		else:
			continue
		if found.is_empty() or (found.construction and not e.get("construction", false)):
			found = {dir = t, ent = id, construction = e.get("construction", false)}
	return found


func _arc_tangent(primary: bool, spot: Dictionary) -> void:
	if not primary:
		_pending.clear()
		return
	if _pending.is_empty():
		var t := _end_tangent(spot.id)
		if t.is_empty():
			game.hud.toast("Start at the end of a line or arc")
			return
		_pending = [{id = spot.id, uv = spot.uv, dir = t.dir, ent = t.ent}]
		return
	var p0: Dictionary = _pending[0]
	var p: Vector2 = p0.uv
	var t: Vector2 = p0.dir
	var q: Vector2 = spot.uv
	if q.distance_to(p) < 1e-12:
		return
	var centre: Variant = SG.tangent_centre(p, t, q)
	if centre == null:
		game.hud.toast("That end is straight ahead: use a line")
		return
	var c: Vector2 = centre
	var left := (c - p).dot(Vector2(-t.y, t.x)) > 0.0  # turning left: counter-clockwise
	var s: Dictionary = sketch.duplicate(true)
	var idc := _point(s, _free(c))
	var idq := _point(s, spot)
	var aid := _new_id(s, "a")
	s.entities.append(_entity(aid, "arc", [idc, p0.id, idq] if left else [idc, idq, p0.id]))
	_con(s, "tangent", [aid, p0.ent] if _ents[p0.ent].kind == "spline" else [p0.ent, aid])
	if _commit(s, "Tangent arc"):
		if spot.id != "":
			_pending.clear()
		else:
			var rq: Vector2 = _p(idq) - _p(idc)
			var nd := Vector2(-rq.y, rq.x).normalized() * (1.0 if left else -1.0)
			_pending = [{id = idq, uv = _p(idq), dir = nd, ent = aid}]


func _ellipse(primary: bool, spot: Dictionary) -> void:
	if not _collect(primary, spot, 3):
		return
	var c: Vector2 = _pending[0].uv
	var m: Vector2 = _pending[1].uv
	var u := (m - c).normalized()
	var r := absf(((spot.uv as Vector2) - c).dot(Vector2(-u.y, u.x)))
	if r < 1e-12:
		game.hud.toast("Move off the first axis to give the ellipse its other axis")
		return
	var s: Dictionary = sketch.duplicate(true)
	var e := _entity(_new_id(s, "e"), "ellipse", [_point(s, _pending[0]), _point(s, _pending[1])])
	e.r = r
	s.entities.append(e)
	if _commit(s, "Ellipse"):
		_pending.clear()


func _spline(primary: bool, spot: Dictionary) -> void:
	if not primary:
		if _pending.size() >= 2:
			_make_spline(false)
		_pending.clear()
		return
	if _pending.size() >= 3 and (spot.uv as Vector2).distance_to(_pending[0].uv) < 1e-12:
		_make_spline(true)
		return
	if not _pending.is_empty() and (spot.uv as Vector2).distance_to(_pending[-1].uv) < 1e-12:
		return
	_pending.append(spot)


func _make_spline(closed: bool) -> void:
	var s: Dictionary = sketch.duplicate(true)
	var ids := []
	for sp in _pending:
		ids.append(_point(s, sp))
	if closed:
		ids.append(ids[0])
	s.entities.append(_entity(_new_id(s, "s"), "spline", ids))
	if _commit(s, "Spline"):
		_pending.clear()


func _snapped_radius(centre: Vector2, spot: Dictionary) -> float:
	if spot.id != "":
		return centre.distance_to(spot.uv)
	var step: float = game.player.snap_step()
	return maxf(snappedf(centre.distance_to(_raw), step), step)


# ---------- editing tools ----------

func _split(primary: bool) -> void:
	if not primary:
		_picks.clear()
		return
	var t := _hover
	if t.is_empty() or t.kind != "entity" or not _ents[t.id].kind in ["line", "arc", "circle"]:
		game.hud.toast("Aim at a line, arc or circle where it should split")
		return
	if _is_copy(t.id):
		game.hud.toast("That is a pattern copy: change the original")
		return
	var e: Dictionary = _ents[t.id]
	var prim := _prim(e)
	var at: Vector2 = Geometry2D.get_closest_point_to_segment(_raw, prim.a, prim.b) if e.kind == "line" \
		else (prim.c as Vector2) + (_raw - prim.c).normalized() * float(prim.r)
	if e.kind == "circle":
		if _picks.is_empty() or _picks[0].id != t.id:
			_picks = [{kind = "entity", id = t.id, at = at}]
			game.hud.toast("A circle splits in two places: now the second")
			return
		var first: Vector2 = _picks[0].at
		_picks.clear()
		split_circle(t.id, first, at)
		return
	split_at(t.id, at)


## Splits a line or arc in two at the point on it nearest at; the pieces stay in line (lines) or
## on one circle (arcs).
func split_at(eid: String, at: Vector2) -> bool:
	var e: Dictionary = _ents[eid]
	var prim := _prim(e)
	var u := SG.param(prim, at)
	var span := SG.span(prim)
	if u < span * 1e-4 or u > span * (1.0 - 1e-4):
		game.hud.toast("Too near an end to split")
		return false
	var s: Dictionary = sketch.duplicate(true)
	_detach(s, eid)
	var ent := _find(s, eid)
	var first := 0 if e.kind == "line" else 1
	var end_id: String = ent.pts[first + 1]
	var mid := _point(s, _free(at))
	ent.pts[first + 1] = mid
	var piece: Dictionary = ent.duplicate(true)
	piece.id = _new_id(s, "l" if e.kind == "line" else "a")
	piece.pts[first] = mid
	piece.pts[first + 1] = end_id
	s.entities.append(piece)
	_con(s, "collinear" if e.kind == "line" else "equal", [eid, piece.id])
	_drop_length(s, eid)
	return _commit(s, "Split")


## Splits a circle into two arcs at the points on it nearest a and b.
func split_circle(eid: String, a: Vector2, b: Vector2) -> bool:
	var e: Dictionary = _ents[eid]
	var c := _p(e.pts[0])
	var r := float(e.r)
	var pa := c + (a - c).normalized() * r
	var pb := c + (b - c).normalized() * r
	if pa.distance_to(pb) < r * 1e-4:
		game.hud.toast("Pick a second place away from the first")
		return false
	var s: Dictionary = sketch.duplicate(true)
	_detach(s, eid)
	var ent := _find(s, eid)
	var ia := _point(s, _free(pa))
	var ib := _point(s, _free(pb))
	ent.kind = "arc"
	ent.pts = [ent.pts[0], ia, ib]
	ent.erase("r")
	var other := ent.duplicate(true)
	other.id = _new_id(s, "a")
	other.pts = [ent.pts[0], ib, ia]
	s.entities.append(other)
	_con(s, "equal", [eid, other.id])
	return _commit(s, "Split")


func _text_tool(primary: bool, spot: Dictionary) -> void:
	if not primary:
		return
	var t := _hover
	if not t.is_empty() and t.kind == "entity" and _ents[t.id].kind == "text":
		var tid: String = t.id
		game.numpad.ask_text("Change the text", String(_ents[tid].text), "Letters, digits and spaces.",
			func(text: String) -> void: set_text(tid, text))
		return
	var anchor := spot.duplicate()
	game.numpad.ask_text("Text", "", "It starts at the point you picked. Dimension it to set its height.",
		func(text: String) -> void: add_text(anchor, text))


## Adds text starting at spot (its baseline's left end), with a height dimension.
func add_text(spot: Dictionary, text: String) -> bool:
	var contours := glyph_contours(text)
	if contours.is_empty():
		game.hud.toast("Nothing to draw: type some letters")
		return false
	var h: float = text_height if text_height > 0.0 else float(game.player.snap_step()) * 2.0
	var s: Dictionary = sketch.duplicate(true)
	var tid := _new_id(s, "t")
	var e := _entity(tid, "text", [_point(s, spot)])
	e.r = h
	e.text = text
	e.contours = contours
	s.entities.append(e)
	_con(s, "distance", [tid], h)
	return _commit(s, "Text")


func set_text(tid: String, text: String) -> bool:
	var contours := glyph_contours(text)
	if contours.is_empty():
		game.hud.toast("Nothing to draw: type some letters")
		return false
	var s: Dictionary = sketch.duplicate(true)
	var e := _find(s, tid)
	e.text = text
	e.contours = contours
	return _commit(s, "Text")


## Outlines of text in the UI font as closed polygons [[x, y], …] for a cap height of 1, starting
## at (0, 0) on the baseline, y up. Curves are flattened into short straight pieces.
static func glyph_contours(text: String) -> Array:
	var out := []
	if text.strip_edges() == "":
		return out
	var ui := preload("res://scripts/ui_theme.gd")
	var font: Font = ui.body_font if ui.body_font != null else ThemeDB.fallback_font
	var ts := TextServerManager.get_primary_interface()
	var size := 256
	var cap := 0.0
	var probe := ts.create_shaped_text()
	ts.shaped_text_add_string(probe, "H", font.get_rids(), size)
	for g in ts.shaped_text_get_glyphs(probe):
		for c in _glyph_polys(ts, g, 0.0):
			for q in c:
				cap = maxf(cap, -float(q.y))
	ts.free_rid(probe)
	if cap <= 0.0:
		cap = size * 0.7
	var rid := ts.create_shaped_text()
	ts.shaped_text_add_string(rid, text, font.get_rids(), size)
	var x := 0.0
	for g in ts.shaped_text_get_glyphs(rid):
		var off: Vector2 = g.get("offset", Vector2.ZERO)
		for c in _glyph_polys(ts, g, x + off.x):
			var poly := []
			for q in c:
				poly.append([float(q.x) / cap, -float(q.y + off.y) / cap])
			if poly.size() >= 3:
				out.append(poly)
		x += float(g.get("advance", 0.0))
	ts.free_rid(rid)
	return out


## One glyph's contours as polygons (font pixels, y down), shifted right by dx.
static func _glyph_polys(ts: TextServer, g: Dictionary, dx: float) -> Array:
	var polys := []
	var frid: RID = g.get("font_rid", RID())
	if not frid.is_valid():
		return polys
	var info: Dictionary = ts.font_get_glyph_contours(frid, int(g.get("font_size", 256)), int(g.get("index", 0)))
	if info.is_empty():
		return polys
	var pts: PackedVector3Array = info.get("points", PackedVector3Array())
	var ends: PackedInt32Array = info.get("contours", PackedInt32Array())
	var start := 0
	for e in ends:
		var raw := []
		for i in range(start, e + 1):
			raw.append(pts[i])
		start = e + 1
		var poly := _flatten(raw)
		for i in poly.size():
			poly[i] = Vector2(poly[i].x + dx, poly[i].y)
		if poly.size() >= 3:
			polys.append(poly)
	return polys


## A TrueType / CFF contour (points with on / conic / cubic tags in z) as a polygon.
static func _flatten(raw: Array) -> Array:
	var n := raw.size()
	if n < 2:
		return []
	var on := func(p: Vector3) -> bool: return int(p.z) == TextServer.CONTOUR_CURVE_TAG_ON
	var first := -1
	for i in n:
		if on.call(raw[i]):
			first = i
			break
	var pts := []
	var start: Vector2
	if first < 0:  # all conic: start between the first two
		start = (Vector2(raw[0].x, raw[0].y) + Vector2(raw[1].x, raw[1].y)) / 2.0
		first = 0
	else:
		start = Vector2(raw[first].x, raw[first].y)
	pts.append(start)
	var cur := start
	var i := 1
	while i <= n:
		var p: Vector3 = raw[(first + i) % n]
		var pv := Vector2(p.x, p.y)
		var tag := int(p.z)
		if tag == TextServer.CONTOUR_CURVE_TAG_ON:
			pts.append(pv)
			cur = pv
			i += 1
		elif tag == TextServer.CONTOUR_CURVE_TAG_OFF_CONIC:
			var nx: Vector3 = raw[(first + i + 1) % n]
			var end := Vector2(nx.x, nx.y)
			if int(nx.z) == TextServer.CONTOUR_CURVE_TAG_OFF_CONIC:
				end = (pv + end) / 2.0
				i += 1
			else:
				i += 2
			if i > n + 1:
				end = start
			for k in range(1, 7):
				var t := k / 6.0
				pts.append(cur.lerp(pv, t).lerp(pv.lerp(end, t), t))
			cur = end
		else:  # cubic: two controls, then an end
			var c2v: Vector3 = raw[(first + i + 1) % n]
			var ev: Vector3 = raw[(first + i + 2) % n]
			var c2 := Vector2(c2v.x, c2v.y)
			var end := Vector2(ev.x, ev.y)
			for k in range(1, 9):
				var t := k / 8.0
				var u := 1.0 - t
				pts.append(cur * u * u * u + pv * 3.0 * u * u * t + c2 * 3.0 * u * t * t + end * t * t * t)
			cur = end
			i += 3
	# Drop the closing repeat and any doubled points.
	var clean := []
	for q in pts:
		if clean.is_empty() or (q as Vector2).distance_to(clean[-1]) > 1e-6:
			clean.append(q)
	if clean.size() > 1 and (clean[0] as Vector2).distance_to(clean[-1]) < 1e-6:
		clean.pop_back()
	return clean


## The pieces a crossing splits an entity into, as places along it.
func _cuts(eid: String) -> Array:
	var e: Dictionary = _ents[eid]
	var prim := _prim(e)
	var span := SG.span(prim)
	var out := []
	for id in _ents:
		if id == eid or _ents[id].kind == "text":
			continue
		for x in SG.hits(prim, _prim(_ents[id])):
			var u := SG.param(prim, x)
			if e.kind != "circle" and (u < span * 1e-7 or u > span * (1.0 - 1e-7)):
				continue  # at an end already
			out.append({u = u, at = x, by = id})
	return out


func _trim(primary: bool) -> void:
	if not primary:
		return
	var t := _hover
	if t.is_empty() or t.kind != "entity":
		game.hud.toast("Aim at the piece of a line, circle or arc to cut away")
		return
	var eid: String = t.id
	var e: Dictionary = _ents[eid]
	if not e.kind in ["line", "circle", "arc"]:
		game.hud.toast("Trim works on lines, circles and arcs; delete the %s instead" % String(e.kind))
		return
	if _is_copy(eid):
		game.hud.toast("That is a pattern copy: change the original")
		return
	var prim := _prim(e)
	var cuts := _cuts(eid)
	var uc := SG.param(prim, _raw)
	var lo := {}
	var hi := {}
	for c in cuts:
		if c.u < uc and (lo.is_empty() or c.u > lo.u):
			lo = c
		if c.u > uc and (hi.is_empty() or c.u < hi.u):
			hi = c
	var s: Dictionary = sketch.duplicate(true)
	_detach(s, eid)
	if e.kind == "circle":
		if cuts.size() < 2:
			_remove(s, {eid: true})
			_commit(s, "Trim")
			return
		for c in cuts:  # wrap round the circle
			if lo.is_empty() or (lo.u > uc and c.u > lo.u):
				lo = c
			if hi.is_empty() or (hi.u < uc and c.u < hi.u):
				hi = c
		var pl := _cut_point(s, lo)
		var ph := _cut_point(s, hi)
		var ent := _find(s, eid)
		ent.kind = "arc"
		ent.pts = [ent.pts[0], ph, pl]
		ent.erase("r")
		_commit(s, "Trim")
		return
	if lo.is_empty() and hi.is_empty():
		_remove(s, {eid: true})
		_commit(s, "Trim")
		return
	var ent := _find(s, eid)
	var first := 0 if e.kind == "line" else 1  # index of the start point in pts
	var start_id: String = ent.pts[first]
	var end_id: String = ent.pts[first + 1]
	if not lo.is_empty() and not hi.is_empty():
		var n_lo := _cut_point(s, lo)
		var n_hi := _cut_point(s, hi)
		ent.pts[first + 1] = n_lo
		var piece: Dictionary = ent.duplicate(true)
		piece.id = _new_id(s, "l" if e.kind == "line" else "a")
		piece.pts[first] = n_hi
		piece.pts[first + 1] = end_id
		s.entities.append(piece)
		_con(s, "collinear" if e.kind == "line" else "equal", [eid, piece.id])
	elif not lo.is_empty():
		ent.pts[first + 1] = _cut_point(s, lo)
	else:
		ent.pts[first] = _cut_point(s, hi)
	_drop_length(s, eid)
	_drop_unused(s, [start_id, end_id])
	_commit(s, "Trim")


## Id of a point at the crossing cut, reusing a point already there; a new point stays on the
## geometry that crosses.
func _cut_point(s: Dictionary, cut: Dictionary) -> String:
	var at: Vector2 = cut.at
	var near := _point_at(s, at, 1e-9)
	if near != "":
		return near
	var pid := _point(s, _free(at))
	var by: Dictionary = _ents.get(cut.by, {})
	if by.get("kind", "") == "line":
		_con(s, "point_on_line", [pid, cut.by])
	elif by.get("kind", "") in ["circle", "arc"]:
		_con(s, "point_on_circle", [pid, cut.by])
	return pid


func _extend(primary: bool) -> void:
	if not primary:
		return
	var t := _hover
	if t.is_empty() or t.kind != "entity" or _ents[t.id].kind != "line":
		game.hud.toast("Aim at a line, near the end to lengthen")
		return
	var e: Dictionary = _ents[t.id]
	if _is_copy(t.id):
		game.hud.toast("That is a pattern copy: change the original")
		return
	var a := _p(e.pts[0])
	var b := _p(e.pts[1])
	var which := 0 if _raw.distance_to(a) < _raw.distance_to(b) else 1
	var end_id: String = e.pts[which]
	var tip := a if which == 0 else b
	var tail := b if which == 0 else a
	if _uses(end_id) > 1 or _fixed.has(end_id) or end_id == "o":
		game.hud.toast("That end is joined to other geometry")
		return
	var dir := (tip - tail).normalized()
	var reach := _extent() * 4.0 + tip.length() + 1.0
	var ray := SG.seg(tip + dir * (tip.distance_to(tail) * 1e-6 + 1e-12), tip + dir * reach)
	var best := {}
	for id in _ents:
		if id == t.id or _ents[id].kind == "text":
			continue
		for x in SG.hits(ray, _prim(_ents[id])):
			var d := tip.distance_to(x)
			if best.is_empty() or d < best.d:
				best = {d = d, at = x, by = id}
	if best.is_empty():
		game.hud.toast("Nothing ahead of that end to extend to")
		return
	var s: Dictionary = sketch.duplicate(true)
	_detach(s, t.id)
	for p in s.points:
		if p.id == end_id:
			p.x = (best.at as Vector2).x
			p.y = (best.at as Vector2).y
	var by: Dictionary = _ents[best.by]
	if by.kind == "line":
		_con(s, "point_on_line", [end_id, best.by])
	elif by.kind in ["circle", "arc"]:
		_con(s, "point_on_circle", [end_id, best.by])
	_drop_length(s, t.id)
	_commit(s, "Extend")


## The two lines meeting at a corner point: [line, line], or [] with a message.
func _corner_lines(pid: String) -> Array:
	var lines := []
	for id in _ents:
		var e: Dictionary = _ents[id]
		if pid in e.pts:
			if e.kind != "line" or e.get("construction", false) or String(e.get("pattern", "")) != "":
				lines.append("")
			else:
				lines.append(id)
	if lines.size() != 2 or "" in lines:
		return []
	return lines


func _corner_tool(primary: bool, which: String) -> void:
	var title := "Fillet radius" if which == "fillet" else "Chamfer distance"
	if not primary:
		_ask_length(title, fillet_radius if which == "fillet" else chamfer_distance, _set_corner_value.bind(which, ""))
		return
	var pid: String = _hover.id if _hover.get("kind", "") == "point" else _snap_id
	if pid == "" or _corner_lines(pid).is_empty():
		game.hud.toast("Aim at a corner where two lines meet")
		return
	var value: Variant = fillet_radius if which == "fillet" else chamfer_distance
	if value == null:
		_ask_length(title, null, _set_corner_value.bind(which, pid))
		return
	if which == "fillet":
		fillet_corner(pid, value)
	else:
		chamfer_corner(pid, value)


func _set_corner_value(text: String, which: String, pid: String) -> void:
	var v: Variant = Units.parse(text, game.hud.units)
	if v is float and v <= 0.0:
		game.hud.toast("It must be more than zero")
		return
	if which == "fillet":
		fillet_radius = v
	else:
		chamfer_distance = v
	if pid != "":
		if which == "fillet":
			fillet_corner(pid, v)
		else:
			chamfer_corner(pid, v)
	else:
		game.hud.toast("%s: %s" % ["Fillet radius" if which == "fillet" else "Chamfer distance",
			game.hud.length(float(v)) if v is float else String(v)])


## The corner pid, cut back along both lines by the same distance: {P, ends: [{line, other, u, len}]}.
func _corner(pid: String) -> Dictionary:
	var lines := _corner_lines(pid)
	if lines.is_empty():
		return {}
	var p := _p(pid)
	var ends := []
	for lid in lines:
		var e: Dictionary = _ents[lid]
		var other: String = e.pts[1] if e.pts[0] == pid else e.pts[0]
		var len := p.distance_to(_p(other))
		if len < 1e-12:
			return {}
		ends.append({line = lid, other = other, u = (_p(other) - p) / len, len = len})
	return {p = p, ends = ends}


## Keeps the old corner as a "virtual sharp" on both lines, so dimensions to it still hold, and
## turns the lines' length dimensions into distances from it.
func _virtual_sharp(s: Dictionary, pid: String, ends: Array) -> void:
	for en in ends:
		_con(s, "point_on_line", [pid, en.line])
		for c in s.constraints:
			if c.kind == "distance" and c.refs == [en.line]:
				c.refs = [pid, en.other]


func _sharp_needed(pid: String, lines: Array) -> bool:
	if pid == "o" or _fixed.has(pid):
		return true
	for c in sketch.constraints:
		if pid in c.refs:
			return true
		for l in lines:
			if c.kind == "distance" and c.refs == [l]:
				return true
	return false


func fillet_corner(pid: String, radius: Variant) -> bool:
	var k := _corner(pid)
	if k.is_empty():
		game.hud.toast("Aim at a corner where two lines meet")
		return false
	var u1: Vector2 = k.ends[0].u
	var u2: Vector2 = k.ends[1].u
	var ang := acos(clampf(u1.dot(u2), -1.0, 1.0))
	if ang < 1e-6 or ang > PI - 1e-6:
		game.hud.toast("Those lines run straight on: there is no corner to round")
		return false
	var r: float = float(radius) if radius is float else minf(k.ends[0].len, k.ends[1].len) * 0.25 * tan(ang / 2.0)
	var d := r / tan(ang / 2.0)
	if d >= k.ends[0].len or d >= k.ends[1].len:
		game.hud.toast("That radius is too big for these lines")
		return false
	var p: Vector2 = k.p
	var t1 := p + u1 * d
	var t2 := p + u2 * d
	var c := p + (u1 + u2).normalized() * (r / sin(ang / 2.0))
	var lines := [k.ends[0].line, k.ends[1].line]
	var keep := _sharp_needed(pid, lines)
	var s: Dictionary = sketch.duplicate(true)
	for en in k.ends:
		_detach(s, en.line)
	var i1 := _point(s, _free(t1))
	var i2 := _point(s, _free(t2))
	var ic := _point(s, _free(c))
	_reattach(s, k.ends[0].line, pid, i1)
	_reattach(s, k.ends[1].line, pid, i2)
	var aid := _new_id(s, "a")
	var ccw := (t1 - c).cross(t2 - c) > 0.0
	s.entities.append(_entity(aid, "arc", [ic, i1, i2] if ccw else [ic, i2, i1]))
	s.entities[-1].construction = false
	_con(s, "tangent", [lines[0], aid])
	_con(s, "tangent", [lines[1], aid])
	_con(s, "radius", [aid], radius)
	if keep:
		_virtual_sharp(s, pid, k.ends)
	else:
		_drop_unused(s, [pid])
	return _commit(s, "Fillet")


func chamfer_corner(pid: String, dist: Variant) -> bool:
	var k := _corner(pid)
	if k.is_empty():
		game.hud.toast("Aim at a corner where two lines meet")
		return false
	var d: float = float(dist) if dist is float else minf(k.ends[0].len, k.ends[1].len) * 0.25
	if d >= k.ends[0].len or d >= k.ends[1].len:
		game.hud.toast("That distance is too long for these lines")
		return false
	var p: Vector2 = k.p
	var s: Dictionary = sketch.duplicate(true)
	for en in k.ends:
		_detach(s, en.line)
	var i1 := _point(s, _free(p + (k.ends[0].u as Vector2) * d))
	var i2 := _point(s, _free(p + (k.ends[1].u as Vector2) * d))
	_reattach(s, k.ends[0].line, pid, i1)
	_reattach(s, k.ends[1].line, pid, i2)
	var lid := _new_id(s, "l")
	s.entities.append({id = lid, kind = "line", pts = [i1, i2], construction = false})
	_virtual_sharp(s, pid, k.ends)
	_con(s, "distance", [pid, i1], dist)
	_con(s, "distance", [pid, i2], dist)
	return _commit(s, "Chamfer")


func _offset(primary: bool) -> void:
	if not primary:
		_ask_length("Offset distance", offset_distance, _set_offset.bind("", Vector2.ZERO))
		return
	var t := _hover
	if t.is_empty() or t.kind != "entity":
		game.hud.toast("Aim at a line, arc, circle or chain, on the side to offset to")
		return
	if offset_distance == null:
		_ask_length("Offset distance", null, _set_offset.bind(t.id, _raw))
		return
	offset_chain(t.id, _raw, offset_distance)


func _set_offset(text: String, eid: String, side: Vector2) -> void:
	var v: Variant = Units.parse(text, game.hud.units)
	if v is float and v <= 0.0:
		game.hud.toast("It must be more than zero")
		return
	offset_distance = v
	if eid != "":
		offset_chain(eid, side, v)
	else:
		game.hud.toast("Offset distance: %s" % (game.hud.length(float(v)) if v is float else String(v)))


## Offsets the chain holding eid towards the side point by dist (SI number or expression). Lines
## stay parallel to their originals at that distance; arcs share their originals' centres.
func offset_chain(eid: String, side: Vector2, dist: Variant) -> bool:
	var e: Dictionary = _ents[eid]
	var d: float = float(dist) if dist is float else _extent() * 0.05
	var s: Dictionary = sketch.duplicate(true)
	if e.kind == "circle":
		var c := _p(e.pts[0])
		var r: float = float(e.r) + (d if side.distance_to(c) > float(e.r) else -d)
		if r <= 1e-12:
			game.hud.toast("That offset is bigger than the circle")
			return false
		var k := _entity(_new_id(s, "k"), "circle", [e.pts[0]])
		k.r = r
		k.construction = e.get("construction", false)
		s.entities.append(k)
		return _commit(s, "Offset")
	if not e.kind in ["line", "arc"]:
		game.hud.toast("Offset works on lines, arcs and circles")
		return false
	var ch := _ordered_chain(eid)
	var items: Array = ch.items
	for it in items:
		if not _ents[it.id].kind in ["line", "arc"]:
			game.hud.toast("Offset works on chains of lines and arcs")
			return false
	# Which side: left or right of the picked piece, in the chain's direction of travel.
	var sign := 1.0
	for it in items:
		if it.id == eid:
			var a := _start_of(it)
			var b := _end_of(it)
			if e.kind == "line":
				sign = 1.0 if (b - a).cross(side - a) > 0.0 else -1.0
			else:
				var c := _p(e.pts[0])
				var inward := side.distance_to(c) < c.distance_to(_p(e.pts[1]))
				# Travelling counter-clockwise, the centre is on the left.
				sign = (1.0 if inward else -1.0) * (-1.0 if it.rev else 1.0)
	var delta := d * sign  # positive: to the left of travel
	var segs := []
	for it in items:
		var en: Dictionary = _ents[it.id]
		var a := _start_of(it)
		var b := _end_of(it)
		if en.kind == "line":
			var nl := (b - a).normalized()
			nl = Vector2(-nl.y, nl.x) * delta
			segs.append({kind = "line", a = a + nl, b = b + nl, src = it.id})
		else:
			var c := _p(en.pts[0])
			var r: float = c.distance_to(_p(en.pts[1]))
			var r2 := r - delta * (-1.0 if it.rev else 1.0)
			if r2 <= 1e-12:
				game.hud.toast("That offset is bigger than an arc in the chain")
				return false
			segs.append({kind = "arc", c = c, r = r2, a = c + (a - c).normalized() * r2, b = c + (b - c).normalized() * r2,
				src = it.id, rev = it.rev, centre = en.pts[0]})
	# Join neighbours where their offsets meet.
	var n := segs.size()
	var joints := []
	for i in (n if ch.closed else n - 1):
		var s1: Dictionary = segs[i]
		var s2: Dictionary = segs[(i + 1) % n]
		var orig := _end_of(items[i])
		joints.append(_meet(s1, s2, orig))
	var ends := []  # per seg: [start point, end point]
	for i in n:
		var st: Vector2 = segs[i].a
		var en2: Vector2 = segs[i].b
		if ch.closed or i > 0:
			st = joints[(i - 1 + n) % n]
		if ch.closed or i < n - 1:
			en2 = joints[i]
		ends.append([st, en2])
	var ids := []
	for i in (n if ch.closed else n + 1):
		var at: Vector2 = ends[i][0] if i < n else ends[n - 1][1]
		ids.append(_point(s, _free(at)))
	for i in n:
		var sg: Dictionary = segs[i]
		var a_id: String = ids[i]
		var b_id: String = ids[(i + 1) % ids.size()] if ch.closed else ids[i + 1]
		var src: Dictionary = _ents[sg.src]
		if sg.kind == "line":
			var lid := _new_id(s, "l")
			s.entities.append({id = lid, kind = "line", pts = [a_id, b_id], construction = src.get("construction", false)})
			_con(s, "parallel", [sg.src, lid])
			_con(s, "distance", [sg.src, lid], dist)
		else:
			var aid := _new_id(s, "a")
			var pts := [sg.centre, b_id, a_id] if sg.rev else [sg.centre, a_id, b_id]
			s.entities.append({id = aid, kind = "arc", pts = pts, construction = src.get("construction", false)})
	return _commit(s, "Offset")


## Where two offset pieces meet: the shared end when they still touch (smooth joints), else where
## their lines or circles cross nearest the original joint.
func _meet(s1: Dictionary, s2: Dictionary, orig: Vector2) -> Vector2:
	var e1: Vector2 = s1.b
	var e2: Vector2 = s2.a
	if e1.distance_to(e2) < 1e-9 * maxf(1.0, orig.length()):
		return (e1 + e2) / 2.0
	var cands := []
	if s1.kind == "line" and s2.kind == "line":
		var x: Variant = SG.line_line(s1.a, s1.b, s2.a, s2.b)
		if x != null:
			cands.append(x)
	elif s1.kind == "line":
		cands = SG.line_circle(s1.a, s1.b, s2.c, s2.r, false)
	elif s2.kind == "line":
		cands = SG.line_circle(s2.a, s2.b, s1.c, s1.r, false)
	else:
		cands = SG.circle_circle(s1.c, s1.r, s2.c, s2.r)
	var best: Variant = null
	for x in cands:
		if best == null or (x as Vector2).distance_to(orig) < (best as Vector2).distance_to(orig):
			best = x
	return best if best != null else (e1 + e2) / 2.0


## The chain eid belongs to, in order: {items: [{id, rev}], closed}. Walks through shared and
## coincident end points, stopping where the chain branches.
func _ordered_chain(eid: String) -> Dictionary:
	var rep := _point_groups()
	var ends := {}  # entity -> [start rep, end rep]
	for id in _ents:
		var se := _ends_of(_ents[id])
		if se.size() == 2:
			ends[id] = [rep.get(se[0], se[0]), rep.get(se[1], se[1])]
	if not ends.has(eid):
		return {items = [{id = eid, rev = false}], closed = false}
	var items := [{id = eid, rev = false}]
	var used := {eid: true}
	var home: String = ends[eid][0]
	var at: String = ends[eid][1]
	while at != home:
		var nid := _only_next(ends, used, at)
		if nid == "":
			break
		used[nid] = true
		var forward: bool = ends[nid][0] == at
		items.append({id = nid, rev = not forward})
		at = ends[nid][1] if forward else ends[nid][0]
	if at == home and items.size() > 1:
		return {items = items, closed = true}
	at = home
	while true:
		var nid := _only_next(ends, used, at)
		if nid == "":
			break
		used[nid] = true
		var forward: bool = ends[nid][1] == at  # travels into at
		items.push_front({id = nid, rev = not forward})
		at = ends[nid][0] if forward else ends[nid][1]
	return {items = items, closed = false}


## The one unused entity with an end at point rep at, or "" when none or several (a branch).
func _only_next(ends: Dictionary, used: Dictionary, at: String) -> String:
	var found := ""
	for id in ends:
		if not used.has(id) and (ends[id][0] == at or ends[id][1] == at):
			if found != "":
				return ""
			found = id
	return found


## Every entity joined to eid through shared or coincident points.
func _chain(eid: String) -> Array:
	var rep := _point_groups()
	var out := [eid]
	var seen := {eid: true}
	var i := 0
	while i < out.size():
		var e: Dictionary = _ents[out[i]]
		var mine := {}
		for p in _ends_of(e):
			mine[rep.get(p, p)] = true
		for id in _ents:
			if seen.has(id):
				continue
			for p in _ends_of(_ents[id]):
				if mine.has(rep.get(p, p)):
					seen[id] = true
					out.append(id)
					break
		i += 1
	return out


func _ends_of(e: Dictionary) -> Array:
	match e.kind:
		"line":
			return [e.pts[0], e.pts[1]]
		"arc":
			return [e.pts[1], e.pts[2]]
		"spline":
			if e.pts.size() > 2 and e.pts[0] == e.pts[-1]:
				return []
			return [e.pts[0], e.pts[-1]]
	return []


## Points joined by coincident relations map to one representative id.
func _point_groups() -> Dictionary:
	var parent := {}
	var find := func(a: String) -> String:
		var r := a
		while parent.has(r) and parent[r] != r:
			r = parent[r]
		return r
	for c in sketch.constraints:
		if c.kind == "coincident" and c.refs.size() == 2:
			var ra: String = find.call(String(c.refs[0]))
			var rb: String = find.call(String(c.refs[1]))
			if ra != rb:
				parent[ra] = rb
	var out := {}
	for id in _pts:
		out[id] = find.call(String(id))
	return out


func _start_of(it: Dictionary) -> Vector2:
	var se := _ends_of(_ents[it.id])
	return _p(se[1] if it.rev else se[0])


func _end_of(it: Dictionary) -> Vector2:
	var se := _ends_of(_ents[it.id])
	return _p(se[0] if it.rev else se[1])


## Copies entity ids into s with every point moved by xf; returns the new entity ids. Points xf
## leaves where they are (on a mirror line, say) are shared rather than copied when share_fixed.
func _copy(s: Dictionary, ids: Array, xf: Callable, reflects := false, share_still := false) -> Dictionary:
	var pmap := {}
	var emap := {}
	for id in ids:
		for p in _ents[id].pts:
			if pmap.has(p):
				continue
			var to: Vector2 = xf.call(_p(p))
			if share_still and to.distance_to(_p(p)) < 1e-9 * maxf(1.0, _extent()):
				pmap[p] = p
			else:
				pmap[p] = _point(s, _free(to))
	for id in ids:
		var e: Dictionary = (_ents[id] as Dictionary).duplicate(true)
		e.id = _new_id(s, String(id).left(1))
		e.erase("pattern")  # a copy of a pattern copy is ordinary geometry
		var pts := []
		for p in e.pts:
			pts.append(pmap[p])
		if reflects and e.kind == "arc":
			pts = [pts[0], pts[2], pts[1]]  # a mirror image runs the other way round
		e.pts = pts
		s.entities.append(e)
		emap[id] = e.id
	return {points = pmap, entities = emap}


func _move(primary: bool) -> void:
	if not primary:
		_picks.clear()
		return
	if _picks.is_empty():
		var t := _hover
		if t.is_empty():
			game.hud.toast("Aim at the geometry or point to move")
			return
		if t.id == "o":
			game.hud.toast("The sketch origin stays put")
			return
		if t.kind == "point" and option() in ["rotate", "scale"]:
			game.hud.toast("Rotate and scale take lines and curves")
			return
		_picks = [{kind = t.kind, id = t.id, from = _pts[t.id] if t.kind == "point" else _cursor}]
		game.hud.toast("Now the centre to turn about" if option() == "rotate" else ("Now the centre to scale about" if option() == "scale" else "Now where it goes"))
		return
	var pick: Dictionary = _picks[0]
	_picks.clear()
	var centre := _cursor
	match option():
		"rotate":
			game.numpad.ask("Turn by", "90", "Degrees, counter-clockwise (negative turns clockwise).",
				func(text: String) -> void: rotate_geometry(pick.id, centre, deg_to_rad(text.to_float())))
		"scale":
			game.numpad.ask("Scale by", "2", "A factor: 2 doubles, 0.5 halves.",
				func(text: String) -> void: scale_geometry(pick.id, centre, text.to_float()))
		_:
			if not _drag.is_empty():
				var moved := _drag
				_drag = {}
				_commit(moved, "Move")
			else:
				move_geometry(pick.kind, pick.id, _cursor - (pick.from as Vector2), option() == "copy")


## Moves (or copies) a point, or the chain holding an entity, by delta.
func move_geometry(kind: String, id: String, delta: Vector2, copy: bool) -> bool:
	if delta.length() < 1e-12:
		return false
	if copy:
		if kind == "point":
			game.hud.toast("Copy takes lines and curves; Point places a new point")
			return false
		var s: Dictionary = sketch.duplicate(true)
		_copy(s, _chain(id), func(u: Vector2) -> Vector2: return u + delta)
		return _commit(s, "Copy")
	return _transform(kind, id, func(u: Vector2) -> Vector2: return u + delta, 1.0, "Move")


## Turns the chain holding eid about centre by angle (radians, counter-clockwise).
func rotate_geometry(eid: String, centre: Vector2, angle: float) -> bool:
	if absf(angle) < 1e-12:
		return false
	if _ents.get(eid, {}).get("kind", "") == "text":
		game.hud.toast("Text stays level: move it instead")
		return false
	return _transform("entity", eid, func(u: Vector2) -> Vector2: return centre + (u - centre).rotated(angle), 1.0, "Rotate")


## Scales the chain holding eid about centre by factor.
func scale_geometry(eid: String, centre: Vector2, factor: float) -> bool:
	if factor <= 0.0 or absf(factor - 1.0) < 1e-12:
		game.hud.toast("Scale by a factor above zero")
		return false
	return _transform("entity", eid, func(u: Vector2) -> Vector2: return centre + (u - centre) * factor, factor, "Scale")


## Applies xf to a point, or to every point of the chain holding an entity (circle and ellipse
## sizes times rscale), then solves with them held there, so dimensions and relations either
## follow or refuse.
func _transform(kind: String, id: String, xf: Callable, rscale: float, what: String) -> bool:
	var moved := _transformed(kind, id, xf, rscale, true)
	if moved.is_empty():
		return false
	return _commit(moved, what)


## The solved sketch after _transform's move, or {} (with a message unless quiet is false).
func _transformed(kind: String, id: String, xf: Callable, rscale: float, tell: bool) -> Dictionary:
	var s: Dictionary = sketch.duplicate(true)
	var chain := [] if kind == "point" else _chain(id)
	var ids := [id] if kind == "point" else []
	for eid in chain:
		for p in _ents[eid].pts:
			if not p in ids:
				ids.append(p)
	for p in ids:
		if p == "o" or _fixed.has(p) or String(p).contains("."):
			if tell:
				game.hud.toast("That is fixed in place" if not String(p).contains(".") else "That is a pattern copy: move the original")
			return {}
	# Hold everything moved where it was put while the rest catches up, then let go.
	var k := 0
	for p in s.points:
		if p.id in ids:
			var to: Vector2 = xf.call(Vector2(float(p.x), float(p.y)))
			p.x = to.x
			p.y = to.y
			s.constraints.append({id = "_drag%d" % k, kind = "fix", refs = [p.id]})
			k += 1
	for e in s.entities:
		if e.id in chain and e.kind in ["circle", "ellipse", "text"]:
			e.r = float(e.r) * rscale
	var r: Dictionary = game.doc.solve_sketch(s)
	if not r.ok:
		if tell:
			game.hud.toast("Its dimensions and relations hold it where it is")
		return {}
	var moved: Dictionary = r.sketch
	moved.constraints = (moved.constraints as Array).filter(func(c): return not String(c.id).begins_with("_drag"))
	return moved


## Move: while geometry is picked, solve it at the cursor so it follows live; the click keeps it.
func _update_drag() -> void:
	if tool().id != "move" or _picks.is_empty() or option() != "move" or not _valid:
		_drag = {}
		_drag_delta = Vector2(INF, INF)
		return
	var pick: Dictionary = _picks[0]
	var delta: Vector2 = _cursor - (pick.from as Vector2)
	if delta == _drag_delta:
		return
	_drag_delta = delta
	_drag = {} if delta.length() < 1e-12 else _transformed(pick.kind, pick.id, func(u: Vector2) -> Vector2: return u + delta, 1.0, false)


func _mirror(primary: bool) -> void:
	if not primary:
		_picks.clear()
		game.hud.toast("Pick the mirror line")
		return
	var t := _hover
	if t.is_empty() or t.kind != "entity":
		game.hud.toast("Aim at a line" if _picks.is_empty() else "Aim at the geometry to mirror")
		return
	if _picks.is_empty():
		if _ents[t.id].kind != "line":
			game.hud.toast("The mirror line must be a line (often a construction centreline)")
			return
		_picks = [t]
		game.hud.toast("Now each piece of geometry to mirror")
		return
	if t.id == _picks[0].id:
		return
	mirror_chain(t.id, _picks[0].id)


## Mirrors the chain holding eid about line axis; each copied point is held symmetric to its
## original, and points on the line are shared.
func mirror_chain(eid: String, axis: String) -> bool:
	var a := _p(_ents[axis].pts[0])
	var b := _p(_ents[axis].pts[1])
	var ids := _chain(eid)
	ids.erase(axis)
	if _ents[eid].kind == "text":
		game.hud.toast("Text cannot be mirrored")
		return false
	var s: Dictionary = sketch.duplicate(true)
	var made := _copy(s, ids, func(u: Vector2) -> Vector2: return SG.reflect(u, a, b), true, true)
	for p in made.points:
		if made.points[p] != p:
			_con(s, "symmetric", [p, made.points[p], axis])
	for id in made.entities:
		if _ents[id].kind in ["circle", "ellipse"]:
			_con(s, "equal", [id, made.entities[id]])
	return _commit(s, "Mirror")


func _pattern(primary: bool, circular: bool) -> void:
	if not primary:
		_picks.clear()
		return
	if _picks.is_empty():
		var t := _hover
		if t.is_empty() or t.kind != "entity":
			game.hud.toast("Aim at the geometry to pattern, or at a pattern to change it")
			return
		var existing := _pattern_of(t.id)
		if not existing.is_empty():
			edit_pattern(existing.id)
			return
		_picks = [{kind = "entity", id = t.id, from = _cursor}]
		game.hud.toast("Now the centre to turn about" if circular else "Now where the first copy goes")
		return
	var pick: Dictionary = _picks[0]
	_picks.clear()
	var to := _cursor
	var centre_id := _snap_id
	var title := "Instances round the circle (with the original)" if circular else "Instances in the row (with the original)"
	game.numpad.ask(title, "6" if circular else "3", "A whole number, 2 or more.",
		func(text: String) -> void: pattern_chain(pick.id, circular, to if circular else to - (pick.from as Vector2), text.to_int(), centre_id))


## Patterns the chain holding eid: count instances in all, step apart (linear), or spread round
## centre over a full turn (circular; centre_id names an existing point, else one is placed).
## The core makes the copies and holds them to the originals; edit_pattern changes it later.
func pattern_chain(eid: String, circular: bool, step_or_centre: Vector2, count_total: int, centre_id := "") -> bool:
	if count_total < 2 or count_total > 100:
		game.hud.toast("Pick between 2 and 100")
		return false
	var ids := _chain(eid).filter(func(id): return not _is_copy(id))
	if ids.is_empty():
		game.hud.toast("Pattern the original, not a copy")
		return false
	var s: Dictionary = sketch.duplicate(true)
	if not s.has("patterns"):
		s.patterns = []
	var pat := {id = _new_id(s, "pt"), kind = "circular" if circular else "linear", entities = ids, count = count_total}
	if circular:
		pat.centre = centre_id if centre_id != "" else _point(s, _free(step_or_centre))
	else:
		if step_or_centre.length() < 1e-12:
			game.hud.toast("Pick a spot away from the first one")
			return false
		pat.spacing = step_or_centre.length()
		pat.angle = step_or_centre.angle()
	s.patterns.append(pat)
	return _commit(s, "Pattern")


## The pattern eid is a copy or an original of, or {}.
func _pattern_of(eid: String) -> Dictionary:
	var e: Dictionary = _ents.get(eid, {})
	for p in sketch.get("patterns", []):
		if e.get("pattern", "") == p.id or eid in p.entities:
			return p
	return {}


func _is_copy(eid: String) -> bool:
	return String(_ents.get(eid, {}).get("pattern", "")) != ""


## Asks for a pattern's number of instances, then its spacing (linear) or spread (circular).
func edit_pattern(pid: String) -> void:
	var pat := {}
	for p in sketch.get("patterns", []):
		if p.id == pid:
			pat = p
	if pat.is_empty():
		return
	var circular: bool = pat.kind == "circular"
	game.numpad.ask("Instances (with the original)", str(int(pat.count)), "A whole number, 2 or more.",
		func(text: String) -> void:
			var n := text.to_int()
			var units: String = game.hud.units
			if circular:
				game.numpad.ask("Spread", Units.show(pat.get("total", TAU), units, true), "Degrees: 360 spaces them evenly round the full turn.",
					func(t2: String) -> void: set_pattern(pid, n, Units.parse(t2, units, true)))
			else:
				game.numpad.ask("Spacing", Units.show(pat.spacing, units), "In %s, or an expression." % units,
					func(t2: String) -> void: set_pattern(pid, n, Units.parse(t2, units))))


## Changes a pattern: instance count and spacing (linear) or spread angle (circular).
func set_pattern(pid: String, count_total: int, value: Variant) -> bool:
	if count_total < 2 or count_total > 100:
		game.hud.toast("Pick between 2 and 100")
		return false
	var s: Dictionary = sketch.duplicate(true)
	for p in s.get("patterns", []):
		if p.id == pid:
			p.count = count_total
			if p.kind == "circular":
				p.total = value
			else:
				p.spacing = value
	return _commit(s, "Pattern")


func _convert(primary: bool) -> void:
	if not primary:
		return
	var p: Node3D = game.player
	var hit: Dictionary = game.doc.pick(p.eye_position(), p.aim_direction(), p.camera.far)
	if hit.is_empty() or not hit.has("face"):
		game.hud.toast("Aim at a face of the model")
		return
	convert_face(int(hit.body), int(hit.face), hit.point)


## Copies a model face's edges onto the sketch plane (probe: a point on the face). The copies are
## fixed and linked: when the model changes they follow their edges, keeping their dimensions and
## relations. Editing one (trim, split…) unlinks just that one.
func convert_face(body: int, face: int, probe: Vector3) -> bool:
	var r: Dictionary = game.doc.convert_face(sketch, body, face, probe)
	if not r.ok:
		game.hud.toast(String(r.message).capitalize() if r.message != "" else "That face could not be copied")
		return false
	return _commit(r.sketch, "Convert edges")


## Stops eid following the model (it is being edited by hand).
func _detach(s: Dictionary, eid: String) -> void:
	for l in s.get("links", []):
		l.entities = (l.entities as Array).filter(func(x): return x != eid)


func _is_linked(eid: String) -> bool:
	for l in sketch.get("links", []):
		if eid in l.entities:
			return true
	return false


# ---------- dimensions and relations ----------

func _dimension(primary: bool) -> void:
	if not primary:
		_picks.clear()
		return
	var t := _hover
	if _picks.is_empty():
		if t.is_empty():
			game.hud.toast("Aim at a line, circle, arc, ellipse or point")
			return
		if t.kind == "point":
			_picks = [t]
			game.hud.toast("Now a second point or a line (%s: %s)" % [Actions.prompt(&"context_wheel"), option()])
			return
		var e: Dictionary = _ents[t.id]
		match e.kind:
			"line":
				_picks = [t]
				game.hud.toast("Aim off the geometry for its length, at a line for the angle, or at a point")
			"circle":
				ask_dimension("diameter", [t.id], float(e.r) * 2.0)
			"arc":
				ask_dimension("radius", [t.id], _p(e.pts[0]).distance_to(_p(e.pts[1])))
			"ellipse":
				ask_dimension("radius", [t.id], float(e.r))
			"text":
				ask_dimension("distance", [t.id], float(e.r))
			_:
				game.hud.toast("Dimension a spline through its points")
		return
	var first: Dictionary = _picks[0]
	if first.kind == "entity":  # a line
		var line: Dictionary = _ents[first.id]
		if t.is_empty() or t.id == first.id:
			_picks.clear()
			ask_dimension("distance", [first.id], _p(line.pts[0]).distance_to(_p(line.pts[1])))
		elif t.kind == "point":
			_picks.clear()
			ask_dimension("distance", [t.id, first.id], _line_gap(t.id, first.id))
		elif _ents[t.id].kind == "line":
			_picks.clear()
			var d1 := _p(line.pts[1]) - _p(line.pts[0])
			var d2 := _p(_ents[t.id].pts[1]) - _p(_ents[t.id].pts[0])
			var ang := atan2(d1.cross(d2), d1.dot(d2))
			if absf(sin(ang)) < 1e-6:
				ask_dimension("distance", [first.id, t.id], _line_gap(_ents[t.id].pts[0], first.id))
			elif ang >= 0.0:
				ask_dimension("angle", [first.id, t.id], ang)
			else:
				ask_dimension("angle", [t.id, first.id], -ang)
		else:
			game.hud.toast("Pick a second line or a point, or aim off the geometry for the length")
		return
	if t.is_empty():
		game.hud.toast("Pick a second point or a line")
		return
	if t.kind == "entity":
		if _ents[t.id].kind != "line":
			game.hud.toast("Pick a second point or a line")
			return
		_picks.clear()
		ask_dimension("distance", [first.id, t.id], _line_gap(first.id, t.id))
		return
	if t.id == first.id:
		return
	var pid: String = first.id
	var p := _p(pid)
	var q := _p(t.id)
	_picks.clear()
	match option():
		"horizontal":
			ask_dimension("hdistance", [pid, t.id], q.x - p.x)
		"vertical":
			ask_dimension("vdistance", [pid, t.id], q.y - p.y)
		_:
			ask_dimension("distance", [pid, t.id], p.distance_to(q))


## Square distance from a point to a line.
func _line_gap(pid: String, lid: String) -> float:
	var e: Dictionary = _ents[lid]
	var a := _p(e.pts[0])
	var d := (_p(e.pts[1]) - a).normalized()
	return absf(d.cross(_p(pid) - a))


## Asks for a dimension's value (editing the existing one of the same kind on the same refs).
func ask_dimension(kind: String, refs: Array, current: float) -> void:
	var existing := _find_constraint(kind, refs)
	var value: Variant = existing.value if not existing.is_empty() else current
	var titles := {distance = "Distance", hdistance = "Horizontal distance", vdistance = "Vertical distance",
		diameter = "Diameter", radius = "Radius", angle = "Angle"}
	var title: String = titles.get(kind, "Dimension")
	if kind == "radius" and _ents.has(refs[0]) and _ents[refs[0]].kind == "ellipse":
		title = "Ellipse semi-axis"
	elif kind == "distance" and refs.size() == 1 and _ents.has(refs[0]) and _ents[refs[0]].kind == "text":
		title = "Text height"
	elif kind == "distance" and refs.size() == 2 and (_ents.has(refs[0]) or _ents.has(refs[1])):
		title = "Distance square to the line"
	var units: String = game.hud.units
	var angle := kind == "angle"
	game.numpad.ask(title, Units.show(value, units, angle),
		("In degrees, or an expression such as 90 deg - taper." if angle
			else "In %s, or an expression such as width / 2 using the part's variables." % units),
		set_dimension.bind(kind, refs))


func set_dimension(text: String, kind: String, refs: Array) -> bool:
	var value: Variant = Units.parse(text, game.hud.units, kind == "angle")
	if value is float and kind in ["distance", "diameter", "radius", "angle"] and value <= 0.0:
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
	if kind == "distance" and refs.size() == 1 and _ents.has(refs[0]) and _ents[refs[0]].kind == "text" and value is float:
		text_height = value  # the next text starts at this height
	return _commit(s, "Dimension")


## What a relation pick is: point, line, circle, arc, ellipse or spline.
func _kind_of(t: Dictionary) -> String:
	if t.is_empty():
		return ""
	return "point" if t.kind == "point" else String(_ents[t.id].kind)


func _relation(primary: bool) -> void:
	if not primary:
		_picks.clear()
		return
	var kind := option()
	var t := _hover
	if t.is_empty():
		game.hud.toast("Aim at sketch geometry")
		return
	if not _picks.is_empty() and _picks.any(func(p): return p.id == t.id):
		return
	var k := _kind_of(t)
	var picks := _picks.map(func(p): return _kind_of(p))
	var curves := ["circle", "arc", "ellipse"]
	var round_ := ["circle", "arc"]
	var want := ""  # what this pick must be, or "" if it fits
	var done := false
	match kind:
		"horizontal", "vertical":
			if picks.is_empty():
				want = "" if k in ["line", "point"] else "a line or a point"
				done = k == "line"
			else:
				want = "" if k == "point" else "a second point"
				done = true
		"fix":
			want = "" if k == "point" else "a point"
			done = true
		"coincident":
			if picks.is_empty():
				want = "" if k == "point" else "a point"
			else:
				want = "" if k in ["point", "line", "circle", "arc"] else "a point, line, circle or arc"
				done = true
		"parallel", "perpendicular", "collinear":
			want = "" if k == "line" else "a line"
			done = picks.size() == 1
		"tangent":
			if picks.is_empty():
				want = "" if k in ["line", "circle", "arc", "spline"] else "a line, curve or spline"
			elif picks[0] == "spline" or k == "spline":
				var other: String = t.id if picks[0] == "spline" else _picks[0].id
				var spl: String = _picks[0].id if picks[0] == "spline" else t.id
				var ok: bool = _kind_of(t if picks[0] == "spline" else _picks[0]) in ["line", "arc"] and _shares_end(spl, other)
				want = "" if ok else "a line or arc that the spline ends on"
				done = true
			else:
				want = "" if k in round_ or (k == "line" and picks[0] in round_) else ("a circle or arc" if picks[0] == "line" else "a line, circle or arc")
				done = true
		"equal":
			if picks.is_empty():
				want = "" if k in ["line"] + curves else "a line or curve"
			else:
				want = "" if (k == "line") == (picks[0] == "line") and k != "spline" else ("a line" if picks[0] == "line" else "a circle, arc or ellipse")
				done = true
		"concentric":
			want = "" if k in curves else "a circle, arc or ellipse"
			done = picks.size() == 1
		"midpoint":
			if picks.is_empty():
				want = "" if k == "point" else "a point"
			else:
				want = "" if k == "line" else "the line it sits at the middle of"
				done = true
		"symmetric":
			if picks.size() < 2:
				want = "" if k == "point" else "a point"
			else:
				want = "" if k == "line" else "the line of symmetry"
				done = true
	if want != "":
		game.hud.toast("Pick " + want)
		return
	_picks.append(t)
	if not done:
		game.hud.toast("Now the next one")
		return
	var ids: Array = _picks.map(func(p): return p.id)
	var kinds: Array = _picks.map(func(p): return _kind_of(p))
	_picks.clear()
	var ckind := kind
	var refs: Array = ids
	match kind:
		"coincident":
			if kinds[1] == "line":
				ckind = "point_on_line"
			elif kinds[1] in round_:
				ckind = "point_on_circle"
		"tangent":
			if kinds[1] == "line" and kinds[0] != "spline":
				refs = [ids[1], ids[0]]
	var s: Dictionary = sketch.duplicate(true)
	s.constraints.append({id = _new_id(s, "c"), kind = ckind, refs = refs})
	_commit(s, kind.capitalize())


## Whether a spline's first or last point ends a line or arc.
func _shares_end(spline_id: String, other_id: String) -> bool:
	var sp: Dictionary = _ents[spline_id]
	var o: Dictionary = _ents[other_id]
	var ends := _ends_of(o)
	return sp.pts[0] in ends or sp.pts[-1] in ends


func _construct(primary: bool) -> void:
	if not primary:
		return
	var t := _hover
	if t.is_empty() or t.kind != "entity":
		game.hud.toast("Aim at a line or curve")
		return
	var s: Dictionary = sketch.duplicate(true)
	for e in s.entities:
		if e.id == t.id:
			e.construction = not e.get("construction", false)
			if _commit(s, "Construction"):
				game.hud.toast(("%s is construction now" if e.construction else "%s is normal geometry again") % KIND_NAMES.get(e.kind, "Geometry"))
			return


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
	_remove(s, gone, [t.id] if t.kind == "point" else [])
	_commit(s, "Delete")


## Removes entities (and, with them, points nothing else uses and every relation that mentions
## either). Stand-alone points elsewhere stay.
func _remove(s: Dictionary, gone: Dictionary, points := []) -> void:
	var touched := points.duplicate()
	var dead_patterns := {}  # deleting a copy deletes its pattern
	for e in s.entities:
		if gone.has(e.id):
			touched.append_array(e.pts)
			if String(e.get("pattern", "")) != "":
				dead_patterns[e.pattern] = true
	if s.has("patterns"):
		var keep := []
		for p in s.patterns:
			p.entities = (p.entities as Array).filter(func(x): return not gone.has(x))
			if not dead_patterns.has(p.id) and not (p.entities as Array).is_empty():
				keep.append(p)
		s.patterns = keep
	for id in gone:
		_detach(s, id)
	s.entities = (s.entities as Array).filter(func(e): return not gone.has(e.id))
	s.constraints = (s.constraints as Array).filter(func(c):
		for r in c.refs:
			if gone.has(r):
				return false
		return true)
	_drop_unused(s, touched)


## Drops the listed points if no entity uses them any more, with their relations.
func _drop_unused(s: Dictionary, ids: Array) -> void:
	var used := {}
	for e in s.entities:
		for p in e.pts:
			used[p] = true
	var gone := {}
	for id in ids:
		if id != "o" and not used.has(id):
			gone[id] = true
	if gone.is_empty():
		return
	s.points = (s.points as Array).filter(func(p): return not gone.has(p.id))
	s.constraints = (s.constraints as Array).filter(func(c):
		for r in c.refs:
			if gone.has(r):
				return false
		return true)


## Drops a line's length (or an arc's) dimension, which no longer means the same after a trim or
## an extend.
func _drop_length(s: Dictionary, eid: String) -> void:
	s.constraints = (s.constraints as Array).filter(func(c): return not (c.kind == "distance" and c.refs == [eid]))


## Points entity lid at new_id instead of old_id.
func _reattach(s: Dictionary, lid: String, old_id: String, new_id: String) -> void:
	var e := _find(s, lid)
	for i in (e.pts as Array).size():
		if e.pts[i] == old_id:
			e.pts[i] = new_id


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
	_fixed = {}
	for p in sketch.points:
		_pts[p.id] = Vector2(float(p.x), float(p.y))
		if p.get("fixed", false):
			_fixed[p.id] = true
	_ents = {}
	var has_spline := false
	for e in sketch.entities:
		_ents[e.id] = e
		has_spline = has_spline or e.kind == "spline"
	_curves = {}
	if has_spline and game != null and game.doc != null:
		for c in game.doc.sketch_curves(sketch):
			if _ents.has(c.id) and _ents[c.id].kind == "spline":
				_curves[c.id] = c.points
	_update_fill()


## Shades every closed profile (construction geometry never closes one).
func _update_fill() -> void:
	var tris: PackedVector2Array = game.doc.sketch_fill(sketch) if game != null and game.doc != null else PackedVector2Array()
	if tris.size() < 3:
		_fill.mesh = null
		return
	var verts := PackedVector3Array()
	verts.resize(tris.size())
	for i in tris.size():
		verts[i] = _w(tris[i])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_fill.mesh = m


func _p(id: String) -> Vector2:
	return _pts.get(id, Vector2.ZERO)


func _free(uv: Vector2) -> Dictionary:
	return {id = "", uv = uv}


func _con(s: Dictionary, kind: String, refs: Array, value: Variant = null) -> void:
	var c := {id = _new_id(s, "c" if value == null else "d"), kind = kind, refs = refs}
	if value != null:
		c.value = value
	s.constraints.append(c)


func _find(s: Dictionary, eid: String) -> Dictionary:
	for e in s.entities:
		if e.id == eid:
			return e
	return {}


## Id of a point (or the origin) within tol of uv in s, or "".
func _point_at(s: Dictionary, uv: Vector2, tol: float) -> String:
	if uv.length() < tol:
		return "o"
	for p in s.points:
		if Vector2(float(p.x), float(p.y)).distance_to(uv) < tol:
			return p.id
	return ""


## How many entities use a point.
func _uses(pid: String) -> int:
	var n := 0
	for id in _ents:
		if pid in _ents[id].pts:
			n += 1
	return n


## Rough size of the sketch, for reach and fallbacks.
func _extent() -> float:
	var m := 0.0
	for id in _pts:
		m = maxf(m, (_pts[id] as Vector2).length())
	return maxf(m, game.player.size if game != null else 1.0)


func _new_id(s: Dictionary, prefix: String) -> String:
	var used := {}
	for k in ["points", "entities", "constraints", "patterns", "links"]:
		for item in s.get(k, []):
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
	var mid: String = spot.get("mid", "")
	var on: String = spot.get("on", "")
	if mid != "" and _find(s, mid).get("kind", "") == "line":
		_con(s, "midpoint", [id, mid])
	elif on != "" and not _find(s, on).is_empty():
		_con(s, "point_on_line" if _find(s, on).kind == "line" else "point_on_circle", [id, on])
	return id


func _entity(id: String, kind: String, pts: Array) -> Dictionary:
	return {id = id, kind = kind, pts = pts, construction = construction_mode}


func _auto_hv(s: Dictionary, line_id: String, a: Vector2, b: Vector2) -> void:
	if absf(a.y - b.y) < 1e-12:
		_con(s, "horizontal", [line_id])
	elif absf(a.x - b.x) < 1e-12:
		_con(s, "vertical", [line_id])


func _ask_length(title: String, current: Variant, cb: Callable) -> void:
	var units: String = game.hud.units
	game.numpad.ask(title, Units.show(current, units) if current != null else "",
		"In %s, or an expression such as width / 10 using the part's variables." % units, cb)


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
		"dimension", "fillet", "chamfer":
			return true
		"move":
			return _picks.is_empty()
		"relation":
			var k := option()
			if k in ["fix", "horizontal", "vertical"]:
				return true
			if k in ["coincident", "midpoint"]:
				return _picks.is_empty()
			if k == "symmetric":
				return _picks.size() < 2
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
	if e.kind == "text":
		var best := INF
		for c in _polylines(e):
			best = minf(best, SG.distance(SG.poly(c), p))
		return best
	return SG.distance(_prim(e), p)


## Every outline of the entity (several for text, one for anything else).
func _polylines(e: Dictionary) -> Array:
	if e.kind != "text":
		return [_polyline(e)]
	var out := []
	var a := _p(e.pts[0])
	var h := float(e.r)
	for c in e.get("contours", []):
		var poly := PackedVector2Array()
		for q in c:
			poly.append(a + Vector2(float(q[0]), float(q[1])) * h)
		if poly.size() > 0:
			poly.append(poly[0])
		out.append(poly)
	return out


## The entity as one primitive for sketch_geom.gd.
func _prim(e: Dictionary) -> Dictionary:
	match e.kind:
		"line":
			return SG.seg(_p(e.pts[0]), _p(e.pts[1]))
		"circle":
			return SG.arc(_p(e.pts[0]), float(e.r), 0.0, TAU)
		"arc":
			var c := _p(e.pts[0])
			var s := _p(e.pts[1])
			return SG.arc(c, c.distance_to(s), (s - c).angle(), SG.sweep_of(c, s, _p(e.pts[2])))
	return SG.poly(_polyline(e))


func _w(uv: Vector2, lift := 0.0) -> Vector3:
	return _o + _x * uv.x + _y * uv.y + _n * lift


func _polyline(e: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	match e.kind:
		"line":
			out.append(_p(e.pts[0]))
			out.append(_p(e.pts[1]))
		"circle":
			var c := _p(e.pts[0])
			for i in 65:
				out.append(c + Vector2.from_angle(TAU * i / 64.0) * float(e.r))
		"arc":
			var c := _p(e.pts[0])
			out = _arc_points(c, _p(e.pts[1]), (_p(e.pts[2]) - c).angle())
		"ellipse":
			out = _ellipse_points(_p(e.pts[0]), _p(e.pts[1]), float(e.r))
		"spline":
			if _curves.has(e.id):
				return _curves[e.id]
			for p in e.pts:
				out.append(_p(p))
	return out


func _ellipse_points(c: Vector2, m: Vector2, r: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var a := m - c
	var b := Vector2(-a.y, a.x).normalized() * r
	for i in 97:
		var t := TAU * i / 96.0
		out.append(c + a * cos(t) + b * sin(t))
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
	if not _drag.is_empty():
		# Show the sketch as it would be after the move.
		var keep := [_pts, _fixed, _ents]
		_pts = {"o": Vector2.ZERO}
		_fixed = {}
		for p in _drag.points:
			_pts[p.id] = Vector2(float(p.x), float(p.y))
		_ents = {}
		for e in _drag.entities:
			_ents[e.id] = e
		_paint()
		_pts = keep[0]
		_fixed = keep[1]
		_ents = keep[2]
		return
	_paint()


func _paint() -> void:
	var im: ImmediateMesh = _lines.mesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	_fat.clear()
	var base := COLOR_DEFINED if defined() else COLOR_FREE
	_fill_mat.albedo_color = Color(base, 0.16) if defined() else Color(base, 0.2)
	var picked := {}
	for p in _picks:
		picked[p.id] = true
	for id in _ents:
		var e: Dictionary = _ents[id]
		var color := COLOR_CONSTRUCTION if e.get("construction", false) else base
		if picked.has(id) or (_hover.get("kind", "") == "entity" and _hover.id == id):
			color = COLOR_ACTIVE
		for poly in _polylines(e):
			_strip(im, poly, color, e.get("construction", false))
	# Points, the origin axes and the cursor.
	var d := _tol * 0.35
	for id in _pts:
		var c := COLOR_ACTIVE if (picked.has(id) or (_hover.get("kind", "") == "point" and _hover.id == id)) else base
		if id != "o":
			_cross(im, _pts[id], d, c)
			if _fixed.has(id):  # fixed (converted) points get a small square
				_box_marker(im, _pts[id], d * 0.7, c)
	_seg(im, Vector2.ZERO, Vector2(_tol * 3.0, 0), Color("ff5d5d"))
	_seg(im, Vector2.ZERO, Vector2(0, _tol * 3.0), Color("6ee06e"))
	if _valid:
		_rubber_band(im)
		_cross(im, _cursor, _tol * 0.6, COLOR_ACTIVE)
		if _snap_id != "" or _snap_mid != "" or _snap_on != "":
			_box_marker(im, _cursor, _tol * (0.5 if _snap_id != "" else 0.35), COLOR_ACTIVE)
	im.surface_end()
	for key in FAT:
		var node: MeshInstance3D = _fat_nodes.get(key)
		if node == null:
			node = MeshInstance3D.new()
			node.material_override = FatLines.material(Color(key), FAT[key] * preload("res://scripts/ui_theme.gd").ui_scale, true)
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(node)
			_fat_nodes[key] = node
		node.mesh = FatLines.mesh(PackedVector3Array(_fat.get(key, [])))
	_draw_grid()
	_draw_labels()


func _rubber_band(im: ImmediateMesh) -> void:
	var cm := construction_mode
	var cur := _cursor
	if not _picks.is_empty() and tool().id in ["move", "pattern_linear"] and _picks[0].has("from"):
		_seg(im, _picks[0].from, cur, COLOR_ACTIVE)
		return
	if _pending.is_empty():
		return
	var a: Vector2 = _pending[0].uv
	match tool().id:
		"line":
			_strip(im, PackedVector2Array([a, cur]), COLOR_ACTIVE, cm)
		"rect":
			_strip(im, PackedVector2Array([a, Vector2(cur.x, a.y), cur, Vector2(a.x, cur.y), a]), COLOR_ACTIVE, cm)
		"rect_centre":
			var h := (cur - a).abs()
			_strip(im, PackedVector2Array([a - h, a + Vector2(h.x, -h.y), a + h, a + Vector2(-h.x, h.y), a - h]), COLOR_ACTIVE, cm)
		"rect_3pt":
			if _pending.size() == 1:
				_strip(im, PackedVector2Array([a, cur]), COLOR_ACTIVE, cm)
			else:
				var b: Vector2 = _pending[1].uv
				var u := (b - a).normalized()
				var nrm := Vector2(-u.y, u.x) * (cur - b).dot(Vector2(-u.y, u.x))
				_strip(im, PackedVector2Array([a, b, b + nrm, a + nrm, a]), COLOR_ACTIVE, cm)
		"polygon":
			var pts := PackedVector2Array()
			for i in polygon_sides + 1:
				pts.append(a + (cur - a).rotated(TAU * i / polygon_sides))
			_strip(im, pts, COLOR_ACTIVE, cm)
		"slot":
			if _pending.size() == 1:
				_seg(im, a, cur, COLOR_ACTIVE)
			else:
				var b: Vector2 = _pending[1].uv
				var u := (b - a).normalized()
				var nrm := Vector2(-u.y, u.x)
				var r := absf((cur - a).dot(nrm))
				var pts := PackedVector2Array()
				for k in 17:
					pts.append(b + (nrm * r).rotated(-PI * k / 16.0))
				for k in 17:
					pts.append(a + (-nrm * r).rotated(-PI * k / 16.0))
				pts.append(b + nrm * r)
				_strip(im, pts, COLOR_ACTIVE, cm)
		"circle":
			var r := _snapped_radius(a, {id = _snap_id, uv = cur})
			_strip(im, _ring(a, r), COLOR_ACTIVE, cm)
		"circle_3pt":
			if _pending.size() == 1:
				_seg(im, a, cur, COLOR_ACTIVE)
			else:
				var c: Variant = SG.circumcentre(a, _pending[1].uv, cur)
				if c != null:
					_strip(im, _ring(c, (c as Vector2).distance_to(a)), COLOR_ACTIVE, cm)
		"arc":
			if _pending.size() == 1:
				_seg(im, a, cur, COLOR_ACTIVE)
			else:
				var s: Vector2 = _pending[1].uv
				var end_angle := (cur - a).angle()
				var ccw := fposmod(end_angle - (s - a).angle(), TAU) <= PI
				var pts := _arc_points(a, s, end_angle) if ccw else _arc_points(a, a + Vector2.from_angle(end_angle) * a.distance_to(s), (s - a).angle())
				_strip(im, pts, COLOR_ACTIVE, cm)
		"arc_3pt":
			if _pending.size() == 1:
				_seg(im, a, cur, COLOR_ACTIVE)
			else:
				var e: Vector2 = _pending[1].uv
				var c: Variant = SG.circumcentre(a, e, cur)
				if c != null:
					var cc: Vector2 = c
					var ccw := fposmod((cur - cc).angle() - (a - cc).angle(), TAU) < fposmod((e - cc).angle() - (a - cc).angle(), TAU)
					_strip(im, _arc_points(cc, a, (e - cc).angle()) if ccw else _arc_points(cc, e, (a - cc).angle()), COLOR_ACTIVE, cm)
		"arc_tangent":
			var t: Vector2 = _pending[0].dir
			var c: Variant = SG.tangent_centre(a, t, cur)
			if c == null:
				_seg(im, a, cur, COLOR_ACTIVE)
			else:
				var cc: Vector2 = c
				var left := (cc - a).dot(Vector2(-t.y, t.x)) > 0.0
				var end_on := cc + (cur - cc).normalized() * cc.distance_to(a)
				_strip(im, _arc_points(cc, a, (end_on - cc).angle()) if left else _arc_points(cc, end_on, (a - cc).angle()), COLOR_ACTIVE, cm)
		"ellipse":
			if _pending.size() == 1:
				_seg(im, a, cur, COLOR_ACTIVE)
			else:
				var m: Vector2 = _pending[1].uv
				var u := (m - a).normalized()
				_strip(im, _ellipse_points(a, m, absf((cur - a).dot(Vector2(-u.y, u.x)))), COLOR_ACTIVE, cm)
		"spline":
			var pts := []
			for p in _pending:
				pts.append(p.uv)
			var closing := _pending.size() >= 3 and cur.distance_to(a) < 1e-12
			if not closing:
				pts.append(cur)
			_strip(im, SG.preview_spline(pts, closing), COLOR_ACTIVE, cm)


func _ring(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 65:
		pts.append(c + Vector2.from_angle(TAU * i / 64.0) * r)
	return pts


func _seg(im: ImmediateMesh, a: Vector2, b: Vector2, color: Color) -> void:
	var key := color.to_html(false)
	if FAT.has(key):  # sketch geometry: solid lines of a fixed on-screen width
		if not _fat.has(key):
			_fat[key] = []
		_fat[key].append(_w(a))
		_fat[key].append(_w(b))
		return
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


func _box_marker(im: ImmediateMesh, p: Vector2, k: float, color: Color) -> void:
	_strip(im, PackedVector2Array([p + Vector2(-k, -k), p + Vector2(k, -k), p + Vector2(k, k), p + Vector2(-k, k),
		p + Vector2(-k, -k)]), color, false)


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
	# Each pattern: its count and spacing (or spread) beside its first copy.
	for p in sketch.get("patterns", []):
		var where := Vector2.ZERO
		var n := 0
		for id in _pts:
			if String(id).begins_with(String(p.id) + ".1."):
				where += _pts[id]
				n += 1
		if n == 0:
			continue
		var l := _label(shown)
		shown += 1
		l.position = _w(where / n + Vector2(0, _tol * 2.0))
		if p.kind == "circular":
			var total: Variant = p.get("total", TAU)
			l.text = "×%d · %s" % [int(p.count), String(total) if total is String else "%.0f°" % rad_to_deg(float(total))]
		else:
			l.text = "×%d · %s" % [int(p.count), String(p.spacing) if p.spacing is String else game.hud.length(float(p.spacing))]
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
			if refs.size() == 1 and _ents.has(refs[0]) and _ents[refs[0]].kind == "text":
				return _p(_ents[refs[0]].pts[0]) + Vector2(0, -_tol * 1.5)
			if refs.size() == 1 and _ents.has(refs[0]):
				var e: Dictionary = _ents[refs[0]]
				var a := _p(e.pts[0])
				var b := _p(e.pts[1])
				var side := (b - a).orthogonal().normalized() * _tol * 1.2
				return (a + b) / 2.0 + side
			if refs.size() == 2:
				var line_id: String = refs[1] if _ents.has(refs[1]) else (refs[0] if _ents.has(refs[0]) else "")
				if line_id != "":
					var other: String = refs[0] if line_id == refs[1] else refs[1]
					var p := _p(_ents[other].pts[0]) if _ents.has(other) else _p(other)
					var e: Dictionary = _ents[line_id]
					var foot := Geometry2D.get_closest_point_to_segment_uncapped(p, _p(e.pts[0]), _p(e.pts[1]))
					return (p + foot) / 2.0
				if _pts.has(refs[0]) and _pts.has(refs[1]):
					return (_p(refs[0]) + _p(refs[1])) / 2.0
		"diameter", "radius":
			if _ents.has(refs[0]):
				var e: Dictionary = _ents[refs[0]]
				var c0 := _p(e.pts[0])
				if e.kind == "circle":
					return c0 + Vector2(0.7071, 0.7071) * float(e.r)
				if e.kind == "ellipse":
					var a := (_p(e.pts[1]) - c0).normalized()
					return c0 + Vector2(-a.y, a.x) * float(e.r)
				var poly := _polyline(e)
				return poly[poly.size() >> 1]
		"angle":
			if _ents.has(refs[0]) and _ents.has(refs[1]):
				var e1: Dictionary = _ents[refs[0]]
				var e2: Dictionary = _ents[refs[1]]
				var x: Variant = SG.line_line(_p(e1.pts[0]), _p(e1.pts[1]), _p(e2.pts[0]), _p(e2.pts[1]))
				var m1 := (_p(e1.pts[0]) + _p(e1.pts[1])) / 2.0
				var m2 := (_p(e2.pts[0]) + _p(e2.pts[1])) / 2.0
				if x == null:
					return (m1 + m2) / 2.0
				return (x as Vector2) + (((m1 + m2) / 2.0) - (x as Vector2)) * 0.5
	return null


func _dimension_text(c: Dictionary) -> String:
	var prefix: String = {diameter = "⌀", radius = "R", hdistance = "↔ ", vdistance = "↕ ", angle = "∠ "}.get(c.kind, "")
	if c.kind == "distance" and c.refs.size() == 1 and _ents.has(c.refs[0]) and _ents[c.refs[0]].kind == "text":
		prefix = "H "
	if c.value is String:
		return prefix + String(c.value)
	if c.kind == "angle":
		return prefix + "%.1f°" % rad_to_deg(float(c.value))
	return prefix + game.hud.length(float(c.value))


func _aim_label() -> String:
	if tool().id == "convert":
		return "Aim at a model face and press to copy its edges"
	if not _valid:
		return "Aim at the sketch plane"
	var id: String = tool().id
	if not _pending.is_empty():
		var a: Vector2 = _pending[0].uv
		var cur := _cursor
		match id:
			"line":
				return "Line %s" % game.hud.length(a.distance_to(cur))
			"rect":
				return "%s × %s" % [game.hud.length(absf(cur.x - a.x)), game.hud.length(absf(cur.y - a.y))]
			"rect_centre":
				return "%s × %s" % [game.hud.length(2.0 * absf(cur.x - a.x)), game.hud.length(2.0 * absf(cur.y - a.y))]
			"rect_3pt", "slot":
				if _pending.size() == 1:
					return "%s %s" % ["Side" if id == "rect_3pt" else "Centres", game.hud.length(a.distance_to(cur))]
				var b: Vector2 = _pending[1].uv
				var u := (b - a).normalized()
				var w := absf((cur - (a if id == "slot" else b)).dot(Vector2(-u.y, u.x)))
				return "%s × %s" % [game.hud.length(a.distance_to(b) + (2.0 * w if id == "slot" else 0.0)), game.hud.length(w * (2.0 if id == "slot" else 1.0))]
			"polygon":
				return "%d sides · corners on ⌀ %s" % [polygon_sides, game.hud.length(2.0 * a.distance_to(cur))]
			"circle":
				return "⌀ %s" % game.hud.length(2.0 * _snapped_radius(a, {id = _snap_id, uv = cur}))
			"arc":
				return "R %s" % game.hud.length(a.distance_to(cur if _pending.size() == 1 else _pending[1].uv))
			"circle_3pt", "arc_3pt":
				if _pending.size() == 2:
					var c: Variant = SG.circumcentre(a, _pending[1].uv, cur)
					if c != null:
						return "R %s" % game.hud.length((c as Vector2).distance_to(a))
				return "Next point"
			"arc_tangent":
				var c: Variant = SG.tangent_centre(a, _pending[0].dir, cur)
				return "R %s" % game.hud.length((c as Vector2).distance_to(a)) if c != null else "Straight ahead"
			"ellipse":
				if _pending.size() == 1:
					return "Semi-axis %s" % game.hud.length(a.distance_to(cur))
				var u := ((_pending[1].uv as Vector2) - a).normalized()
				return "Semi-axes %s, %s" % [game.hud.length(a.distance_to(_pending[1].uv)), game.hud.length(absf((cur - a).dot(Vector2(-u.y, u.x))))]
			"spline":
				if _pending.size() >= 3 and cur.distance_to(a) < 1e-12:
					return "Close the spline"
				return "Spline point %d · %s finishes" % [_pending.size() + 1, Actions.prompt(&"secondary")]
	if not _picks.is_empty():
		match id:
			"move":
				return "%s by %s" % [option().capitalize(), game.hud.length((_cursor - (_picks[0].from as Vector2)).length())]
			"pattern_linear":
				return "Spacing %s" % game.hud.length((_cursor - (_picks[0].from as Vector2)).length())
			"pattern_circular":
				return "Centre"
	var what := ""
	if not _hover.is_empty():
		what = "origin" if _hover.id == "o" else ("point" if _hover.kind == "point" else String(KIND_NAMES.get(_ents[_hover.id].kind, "Entity")).to_lower())
	match id:
		"erase":
			if what != "":
				return "Delete " + what
		"relation":
			if what != "":
				return "%s · %s" % [option().capitalize(), what]
		"dimension":
			if not _picks.is_empty() and _picks[0].kind == "entity" and _hover.is_empty():
				return "Length"
			if what != "":
				return "Dimension " + what
		"trim":
			if what != "" and _hover.kind == "entity":
				return "Trim " + what
		"extend":
			if what == "line":
				return "Extend line"
		"split":
			if what in ["line", "arc", "circle"]:
				return "Split " + what + (" (second place)" if not _picks.is_empty() else "")
		"text":
			if what == "text":
				return "Change text"
			return "Text starts here"
		"fillet", "chamfer":
			if _hover.get("kind", "") == "point" and not _corner_lines(_hover.id).is_empty():
				var v: Variant = fillet_radius if id == "fillet" else chamfer_distance
				return "%s corner%s" % [id.capitalize(), "" if v == null else " · " + (game.hud.length(float(v)) if v is float else String(v))]
		"offset":
			if what != "" and _hover.kind == "entity":
				return "Offset %s%s" % [what, "" if offset_distance == null else " · " + (game.hud.length(float(offset_distance)) if offset_distance is float else String(offset_distance))]
		"pattern_linear", "pattern_circular":
			if what != "" and _hover.kind == "entity" and not _pattern_of(_hover.id).is_empty():
				return "Change this pattern"
			if what != "":
				return "%s %s" % [tool().name, what]
		"move", "construct":
			if what != "":
				return "%s %s" % [tool().name, what]
		"mirror":
			if what != "":
				return ("Mirror line: " if _picks.is_empty() else "Mirror ") + what
	if _snap_id == "o":
		return "Origin"
	if _snap_id != "":
		return "On point"
	if _snap_mid != "":
		return "Midpoint"
	if _snap_on != "":
		return "On " + String(KIND_NAMES.get(_ents[_snap_on].kind, "curve")).to_lower()
	return "%s, %s" % [game.hud.length(_cursor.x), game.hud.length(_cursor.y)]


## Swings the camera to look straight down the sketch plane's normal, with the plane's X axis
## pointing right and its Y axis up, like a desktop CAD tool's sketch view. When frame is true
## (editing a sketch), it centres on and zooms to the existing geometry; otherwise it centres on
## where the player was aiming.
func _enter_sketch_view(frame: bool) -> void:
	var p: Node3D = game.player
	var target := _plane_point_ahead()
	if frame and _pts.size() > 1:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for id in _pts:
			lo = lo.min(_pts[id])
			hi = hi.max(_pts[id])
		for e in sketch.entities:
			if e.kind in ["circle", "ellipse"]:
				var c := _p(e.pts[0])
				var r := float(e.r) if e.kind == "circle" else maxf(float(e.r), c.distance_to(_p(e.pts[1])))
				lo = lo.min(c - Vector2.ONE * r)
				hi = hi.max(c + Vector2.ONE * r)
		target = _w((lo + hi) / 2.0)
		var extent := maxf((hi - lo).length() / 2.0, 1e-4)
		# The view's half-height is about 3 player sizes at the sketch-view distance.
		p.set_size(extent * 1.3 / 3.0)
	p.lock_view(target, _x, _y, _n)


## Where the crosshair meets the plane, or the point on the plane nearest the eye if the player
## looks away from it or it is very far.
func _plane_point_ahead() -> Vector3:
	var p: Node3D = game.player
	var eye: Vector3 = p.eye_position()
	var dir: Vector3 = p.aim_direction()
	var nearest := eye - _n * (eye - _o).dot(_n)
	var denom := dir.dot(_n)
	if absf(denom) > 1e-6:
		var t := (_o - eye).dot(_n) / denom
		if t > 0.0 and t < 40.0 * float(p.size):
			return eye + dir * t
	return nearest


## Y in sketch mode: switch between the sketch view and free first-person look.
func toggle_view() -> void:
	var p: Node3D = game.player
	if p.view_lock:
		p.unlock_view()
		game.hud.toast("Free look: walk or fly around · %s returns to the sketch view" % Actions.prompt(&"normal_to"))
	else:
		p.lock_view(_plane_point_ahead(), _x, _y, _n)
		game.hud.toast("Sketch view")
