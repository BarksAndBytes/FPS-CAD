extends Node
## The tool set ("weapons"). Each tool has a primary action (RT / left click), a secondary action
## (LT / right click) and one context option cycled with LB / E. Tools act on the CAD document
## through the extension; the model view only draws.

signal changed  # the document changed; redraw it
signal tool_switched(index: int)
signal sketch_requested(plane: Dictionary, plane_name: String, edit_id: String)
signal feature_requested(type: String, sketch_id: String, op: String)
signal reference_requested(type: String, params: Dictionary)  # main.gd opens the panel when it has sizes
signal board_tool(id: String, primary: bool)  # main.gd hands it to boards.gd
signal picked_feature_requested(type: String, base: Dictionary, op: String)  # fillet, chamfer, hole, shell

## How the tool wheel groups the tools: single tools and groups on the inner ring, a group's
## tools branching out from it (tool_wheel.gd). Entries are tool ids or [group name, description,
## [tool ids]].
const Units := preload("res://scripts/units.gd")

const WHEEL := [
	"select",
	"sketch",
	["Solids", "Turn a sketch into a solid: extrude, revolve, sweep, loft", ["extrude", "revolve", "sweep", "loft"]],
	["Finish", "Round, bevel, drill, hollow and draft: fillet, chamfer, hole, shell, draft", ["fillet", "chamfer", "hole", "shell", "draft"]],
	["Repeat", "Copy features in rows, around an axis, or mirrored", ["linear_pattern", "circular_pattern", "mirror"]],
	["Bodies", "Whole bodies: combine, subtract, split, delete", ["combine", "split", "delete_body"]],
	["Modify", "Change what is there: push/pull faces, move, delete", ["push", "move", "delete"]],
	["Primitives", "Place ready-made shapes", ["box", "cylinder", "sphere"]],
	["Reference", "Planes, axes, points and coordinate systems to build from", ["ref_plane", "ref_axis", "ref_point", "ref_csys"]],
	["Measure", "Distances, angles, areas, the bounding box, mass properties, section view, interference",
		["measure", "bbox", "mass", "section", "interference"]],
	["Boards", "Whiteboards in the room: part properties, your notes; carry, turn and resize them",
		["board_props", "board_notes", "board_video", "board_arrange"]],
]
const TOOLS := [
	{id = "select", name = "Select", pri = "select feature", alt = "match my size to it", opt = []},
	{id = "sketch", name = "Sketch", pri = "sketch on this face or plane", alt = "edit the sketch you aim at",
		opt = ["aimed face", "Top plane", "Front plane", "Right plane"]},
	{id = "extrude", name = "Extrude", pri = "extrude the sketch", alt = "extrude as a cut", opt = []},
	{id = "revolve", name = "Revolve", pri = "revolve the sketch", alt = "revolve as a cut", opt = []},
	{id = "sweep", name = "Sweep", pri = "sweep the sketch along a path", alt = "sweep as a cut", opt = []},
	{id = "loft", name = "Loft", pri = "loft the sketch to another", alt = "loft as a cut", opt = []},
	{id = "fillet", name = "Fillet", pri = "pick / unpick the edge you aim at", alt = "round the picked edges", opt = []},
	{id = "chamfer", name = "Chamfer", pri = "pick / unpick the edge you aim at", alt = "bevel the picked edges", opt = []},
	{id = "hole", name = "Hole", pri = "place a hole (snapped)", alt = "place it exactly where you aim", opt = []},
	{id = "shell", name = "Shell", pri = "pick / unpick a face to leave open", alt = "hollow the part", opt = []},
	{id = "draft", name = "Draft", pri = "pick / unpick a face to draft", alt = "draft from the flat face you aim at", opt = []},
	{id = "linear_pattern", name = "Linear pattern", pri = "pick / unpick a feature", alt = "repeat in rows (along the edge you aim at)", opt = []},
	{id = "circular_pattern", name = "Circular pattern", pri = "pick / unpick a feature", alt = "repeat around the axis you aim at", opt = []},
	{id = "mirror", name = "Mirror", pri = "pick / unpick a feature (none: the whole part)", alt = "mirror in the face or plane you aim at", opt = []},
	{id = "combine", name = "Combine bodies", pri = "pick / unpick a body (the first is kept)", alt = "combine, subtract or intersect them", opt = []},
	{id = "split", name = "Split body", pri = "pick the body to split", alt = "split it with the face or plane you aim at", opt = []},
	{id = "delete_body", name = "Delete body", pri = "delete the body you aim at", alt = "undo", opt = []},
	{id = "repick", name = "Re-pick", pri = "pick the face it should use", alt = "cancel", opt = []},
	{id = "push", name = "Push / Pull", pri = "push face out", alt = "pull face in", opt = ["snap step", "grid step", "fine step"]},
	{id = "measure", name = "Measure", pri = "set point / measure what you aim at", alt = "clear",
		opt = ["snap to corners", "free", "face or edge", "angle"]},
	{id = "section", name = "Section view", pri = "cut the part here (walk into it)", alt = "show the whole part",
		opt = ["facing me", "Front plane", "Right plane", "Top plane", "aimed face"]},
	{id = "interference", name = "Interference", pri = "check where bodies overlap", alt = "hide", opt = []},
	{id = "delete", name = "Delete", pri = "delete target", alt = "undo", opt = []},
	{id = "box", name = "Box", pri = "place box", alt = "copy size from target", opt = ["add", "cut", "new body"]},
	{id = "cylinder", name = "Cylinder", pri = "place cylinder", alt = "copy size from target", opt = ["add", "cut", "new body"]},
	{id = "sphere", name = "Sphere", pri = "place sphere", alt = "copy size from target", opt = ["add", "cut", "new body"]},
	{id = "move", name = "Move", pri = "grab / drop", alt = "duplicate & grab", opt = []},
	{id = "ref_plane", name = "Plane", pri = "pick what it is built from", alt = "start again",
		opt = ["offset", "at an angle", "through three points", "midway"]},
	{id = "ref_axis", name = "Axis", pri = "pick what it is built from", alt = "start again",
		opt = ["edge or cylinder", "through two points", "where two planes meet"]},
	{id = "ref_point", name = "Point", pri = "place a point", alt = "start again",
		opt = ["on a corner", "face centre", "at the crosshair"]},
	{id = "ref_csys", name = "Coordinate system", pri = "place on a face (corner snaps)", alt = "start again", opt = []},
	{id = "bbox", name = "Bounding box", pri = "show the size on the board", alt = "hide", opt = []},
	{id = "mass", name = "Mass properties", pri = "show volume, mass and centre of mass", alt = "hide", opt = []},
	{id = "board_props", name = "Properties board", pri = "set up a board of the part's properties", alt = "remove the board you aim at", opt = []},
	{id = "board_notes", name = "Notes board", pri = "add a note (here, or to the board you aim at)", alt = "edit the note you aim at", opt = []},
	{id = "board_video", name = "Video board", pri = "set up a video board / play or pause the one you aim at", alt = "choose its video: a link, a downloaded video or a file", opt = []},
	{id = "board_arrange", name = "Arrange boards", pri = "pick up / set down a board", alt = "put it back / remove the board you aim at", opt = []},
]
const PART_ONLY := ["section", "interference", "repick", "fillet", "chamfer", "hole", "shell", "draft", "linear_pattern", "circular_pattern", "mirror",
	"combine", "split", "delete_body", "push", "box", "cylinder", "sphere", "delete", "sketch", "extrude", "revolve", "sweep", "loft",
	"ref_plane", "ref_axis", "ref_point", "ref_csys", "bbox", "mass", "board_props", "board_notes", "board_video", "board_arrange"]
const BOARD_TOOLS := ["board_props", "board_notes", "board_video", "board_arrange"]
const REF_TOOLS := ["ref_plane", "ref_axis", "ref_point", "ref_csys"]
const FEATURE_TOOLS := ["extrude", "revolve", "sweep", "loft"]
const PICK_TOOLS := ["fillet", "chamfer", "hole", "shell", "draft", "linear_pattern", "circular_pattern", "mirror",
	"combine", "split", "delete_body"]
const FEATURE_PICK_TOOLS := ["linear_pattern", "circular_pattern", "mirror"]
const OPS := {"add": "add", "cut": "cut", "new body": "new-body"}
const STANDARD_PLANES := {"Top plane": "top", "Front plane": "front", "Right plane": "right"}

var doc: RefCounted  # CadPart or CadAssembly
var is_assembly := false
var view: Node3D     # model_view.gd
var player: Node3D   # player.gd
var hud: CanvasLayer # hud.gd

var index := 0
var options := {}          # tool id -> option index
var selected := ""         # feature id (part) or component id (assembly)
var aim := {}              # the current crosshair hit
var _place_dims := {}      # tool id -> copied dimensions
var _push_hit := {}
var _hold_time := -1.0
var _hold_primary := true
var _grab := {}            # {id, plane_y, last} while moving
var _measure_a: Variant = null
var _measure_b: Variant = null
var _ref_picks: Array = []   # what a reference is built from, picked so far
var _show_bbox := false
var _show_mass := false
var _bbox_cache := {}
var _com_cache: Variant = null
var _measure_info := ""       # face or edge / angle readout
var _angle_first := {}        # the first pick of an angle measurement
var _clashes: Array = []      # interference results shown
var _picks: Array = []        # fillet/chamfer: edge_near results; shell: {ref, body, face}
var _hover_edge := {}
var repair := {}  # {id, name, type} while a failed feature's references are picked again


func tool() -> Dictionary:
	return TOOLS[index]


## The wheel's tree for tool_wheel.gd; tool values are TOOLS indices.
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
	var i := index_of(id)
	return {name = TOOLS[i].name, pri = TOOLS[i].pri, alt = TOOLS[i].alt, value = i}


func index_of(id: String) -> int:
	for i in TOOLS.size():
		if TOOLS[i].id == id:
			return i
	return -1


func set_tool_id(id: String) -> void:
	set_tool(index_of(id))


func option() -> String:
	var opts: Array = tool().opt
	return "" if opts.is_empty() else opts[options.get(tool().id, 0)]


## Clears all per-document state; called when a new mode or document starts.
func reset() -> void:
	_grab = {}
	_push_hit = {}
	_hold_time = -1.0
	_measure_a = null
	_measure_b = null
	_ref_picks = []
	_picks = []
	_measure_info = ""
	_clashes = []
	_show_bbox = false
	_show_mass = false
	_place_dims = {}
	options = {}
	selected = ""
	aim = {}
	set_tool(0)


func set_tool(i: int) -> void:
	if i < 0 or i >= TOOLS.size():
		return
	if not _grab.is_empty():
		_drop()
	index = i
	_push_hit = {}
	_hold_time = -1.0
	_ref_picks = []
	_picks = []
	_hover_edge = {}
	_angle_first = {}
	repair = {}
	view.show_picks([], [])
	view.highlight_reference("")
	view.show_ghost("", Vector3.ZERO, {})
	view.show_plane({}, 0.0)
	view.highlight_sketch("")
	view.clear_highlight()
	tool_switched.emit(i)


func cycle_option() -> void:
	var opts: Array = tool().opt
	if opts.is_empty():
		hud.toast("%s has no options" % tool().name)
		return
	var n: int = (options.get(tool().id, 0) + 1) % opts.size()
	options[tool().id] = n
	_ref_picks = []
	hud.toast("%s: %s" % [tool().name, opts[n]])


func press(primary: bool) -> void:
	if is_assembly and tool().id in PART_ONLY:
		hud.toast("Open a part to use %s" % tool().name)
		return
	_act(primary, false)
	if tool().id == "push" and not _push_hit.is_empty():
		_hold_time = 0.0
		_hold_primary = primary


func release() -> void:
	_hold_time = -1.0
	_push_hit = {}


## Called every frame with the crosshair hit.
func update(hit: Dictionary, dt: float) -> void:
	aim = hit
	if _hold_time >= 0.0:
		_hold_time += dt
		if _hold_time > 0.3:
			_hold_time = 0.22  # repeat every 80 ms after the first 300 ms
			_act(_hold_primary, true)
	if not _grab.is_empty():
		_update_grab()
	_update_preview(hit)


func step() -> float:
	var s: float = player.snap_step()
	if tool().id == "push":
		match option():
			"grid step": return player.grid_step()
			"fine step": return s / 10.0
	return s


func snapped_xz(p: Vector3) -> Vector3:
	var s: float = player.snap_step()
	return Vector3(snappedf(p.x, s), p.y, snappedf(p.z, s))


func place_dims(id: String) -> Dictionary:
	if _place_dims.has(id):
		return _place_dims[id]
	var g: float = player.grid_step()
	match id:
		"box": return {w = g, d = g, h = g}
		"cylinder": return {r = g / 2.0, h = g}
	return {r = g / 2.0}


## Where a new primitive's base centre goes for this hit: on top faces, flush against sides.
func place_base(hit: Dictionary, id: String) -> Vector3:
	var d := place_dims(id)
	var n: Vector3 = hit.normal
	var p: Vector3 = hit.point
	var h: float = d.get("h", d.get("r", 0.5) * 2.0)
	var half_w: float = d.get("w", d.get("r", 0.5) * 2.0) / 2.0
	var half_d: float = d.get("d", d.get("r", 0.5) * 2.0) / 2.0
	if n.y > 0.5:
		var b := snapped_xz(p)
		b.y = p.y
		return b
	if n.y < -0.5:
		var b := snapped_xz(p)
		b.y = p.y - h
		return b
	var s: float = player.snap_step()
	var b := Vector3(p.x + n.x * half_w, maxf(0.0, snappedf(p.y - h / 2.0, s)), p.z + n.z * half_d)
	if absf(n.x) > absf(n.z):
		b.z = snappedf(b.z, s)
	else:
		b.x = snappedf(b.x, s)
	return b


func _act(primary: bool, repeat: bool) -> void:
	var hit := aim
	var on_feature: bool = not hit.is_empty() and not hit.get("ground", false) and hit.get("feature_id", "") != ""
	match tool().id:
		"select":
			if primary:
				selected = _target_id(hit)
				hud.toast("%s selected" % hit.get("component_name", hit.get("feature_name", "")) if selected != "" else "Selection cleared")
				hud.show_feature(selected)
			elif on_feature and not is_assembly:
				var dims: Dictionary = doc.feature_dims(hit.feature_id)
				var biggest := 0.0
				for v in dims.values():
					biggest = maxf(biggest, float(v))
				if biggest > 0.0:
					player.set_size(biggest / (player.TALL * 1.6))  # the part fills a comfortable view
					hud.toast("Sized to %s" % hit.feature_name)
		"sketch":
			if primary:
				var pick := _sketch_plane(hit, on_feature)
				if pick.is_empty():
					hud.toast("That face is curved. Aim at a flat face, or pick a plane with %s" % Actions.prompt(&"context_wheel"))
					return
				sketch_requested.emit(pick.plane, pick.name, "")
			else:
				var s := _aimed_sketch(true)
				if s.is_empty():
					hud.toast("Aim at a sketch's lines to edit it")
					return
				sketch_requested.emit({}, "", s.feature_id)
		"extrude", "revolve", "sweep", "loft":
			var sid := _feature_sketch()
			if sid == "":
				hud.toast("Draw a sketch first: pick Sketch from the wheel")
				return
			feature_requested.emit(tool().id, sid, "add" if primary else "cut")
		"push":
			if not repeat:
				if not on_feature:
					hud.toast("Aim at a face of a part")
					return
				_push_hit = hit
				doc.checkpoint()
			var r: Dictionary = doc.push_pull(_push_hit, step() if primary else -step())
			if not r.ok:
				if not repeat:
					doc.drop_checkpoint()
				hud.toast(r.message)
				_hold_time = -1.0
				return
			Input.start_joy_vibration(0, 0.15, 0.0, 0.04)  # a tick per snap step
			changed.emit()
		"box", "cylinder", "sphere":
			var id: String = tool().id
			if primary:
				if hit.is_empty():
					return
				var new_id: String = doc.add_primitive(id, place_base(hit, id), place_dims(id), OPS[option()])
				if new_id == "":
					hud.toast("That %s would break the model" % id)
				else:
					changed.emit()
			else:
				if on_feature:
					var d: Dictionary = doc.feature_dims(hit.feature_id)
					if id == "box" and d.has("w"):
						_place_dims[id] = {w = d.w, d = d.get("d", d.w), h = d.get("h", d.w)}
					elif d.has("r") or d.has("w"):
						var r: float = d.get("r", minf(d.get("w", 1.0), d.get("d", 1.0)) / 2.0)
						_place_dims[id] = {r = r, h = d.get("h", r * 2.0)}
					hud.toast("Size copied from %s" % hit.feature_name)
				else:
					_place_dims.erase(id)
					hud.toast("Size back to auto")
		"move":
			if not _grab.is_empty():
				if primary:
					_drop()
				else:
					_cancel_grab()
				return
			var id := _target_id(hit)
			if id == "":
				return
			if is_assembly:
				_grab = {id = id, plane_y = hit.point.y, last = hit.point, component = hit.component, offset = Vector3.ZERO}
				if not primary:
					hud.toast("Duplicating components arrives with assembly editing")
				return
			if primary:
				doc.checkpoint()
				_grab = {id = id, plane_y = hit.point.y, last = hit.point}
			else:
				var copy: String = doc.duplicate_feature(id, Vector3(step() * 4.0, 0, 0))
				if copy == "":
					hud.toast("That feature cannot be duplicated")
					return
				changed.emit()
				_grab = {id = copy, plane_y = hit.point.y, last = hit.point}
		"fillet", "chamfer", "hole", "shell", "draft":
			_act_pick(primary, hit, on_feature)
		"linear_pattern", "circular_pattern", "mirror":
			_act_repeat(primary, hit, on_feature)
		"combine", "split", "delete_body":
			_act_bodies(primary, hit, on_feature)
		"repick":
			_act_repick(primary, hit, on_feature)
		"ref_plane", "ref_axis", "ref_point", "ref_csys":
			_act_reference(primary, hit)
		"board_props", "board_notes", "board_video", "board_arrange":
			board_tool.emit(tool().id, primary)
		"section":
			if not primary:
				doc.set_section({})
				hud.toast("Whole part shown")
				changed.emit()
				return
			var plane := _section_plane(hit)
			if plane.is_empty():
				hud.toast("Aim at a flat face for its plane, or pick another option with %s" % Actions.prompt(&"context_wheel"))
				return
			doc.set_section(plane)
			hud.toast("Section view · walk into the cut · %s shows the whole part" % Actions.prompt(&"secondary"))
			changed.emit()
		"interference":
			if not primary:
				_clashes = []
				view.show_com(null, 0.0)
				return
			_clashes = doc.interference()
			if doc.body_count() < 2:
				hud.toast("Interference needs two bodies or more")
			elif _clashes.is_empty():
				hud.toast("No interference: the %d bodies do not overlap" % doc.body_count())
			else:
				var parts := []
				for x in _clashes:
					parts.append("bodies %d and %d overlap by %s" % [int(x.a) + 1, int(x.b) + 1, Units.volume_text(float(x.volume), hud.units)])
				hud.toast("Interference: " + "; ".join(parts))
		"bbox":
			_show_bbox = primary
			if primary:
				var b: Dictionary = doc.bounding_box()
				_bbox_cache = b
				if not b.get("ok", false):
					hud.toast("Nothing to measure yet")
					_show_bbox = false
				else:
					var sz: Vector3 = b.size
					hud.toast("Bounding box  %s × %s × %s  (X × Y × Z)" % [hud.length(sz.x), hud.length(sz.y), hud.length(sz.z)])
		"mass":
			_show_mass = primary
			if primary:
				var m: Dictionary = doc.mass_properties()
				_com_cache = m.centre_of_mass
				if float(m.volume) <= 0.0:
					hud.toast("Nothing to weigh yet")
					_show_mass = false
				else:
					var c: Vector3 = m.centre_of_mass
					hud.toast(mass_summary(m, hud.units, hud.length(c.x), hud.length(-c.z), hud.length(c.y), doc.get_mass_units()))
		"measure":
			if not primary:
				_measure_a = null
				_measure_b = null
				_measure_info = ""
				_angle_first = {}
				return
			if option() in ["face or edge", "angle"]:
				_measure_pick(hit)
				return
			_measure_info = ""
			var p: Variant = _snap_point(hit)
			if p == null:
				return
			if _measure_a == null or _measure_b != null:
				_measure_a = p
				_measure_b = null
			else:
				_measure_b = p
		"delete":
			if not primary:
				if doc.undo():
					changed.emit()
				return
			var target: String = hit.feature_id if on_feature else ""
			if target == "":
				target = _aimed_sketch(false).get("feature_id", "")
			if target != "":
				var r: Dictionary = doc.delete_feature(target)
				hud.toast(r.message)
				if target == selected:
					selected = ""
				changed.emit()


## The finishing tools: pick edges or faces with the primary action, then make the feature from
## them with the secondary one (the hole is placed straight away).
func _act_pick(primary: bool, hit: Dictionary, on_feature: bool) -> void:
	var id: String = tool().id
	match id:
		"fillet", "chamfer":
			if primary:
				var e := _edge_at(hit)
				if e.is_empty():
					hud.toast("Aim at an edge of the part")
					return
				var i := _pick_index(e)
				if i >= 0:
					_picks.remove_at(i)
				else:
					_picks.append(e)
				hud.toast("%d edge%s picked · %s to %s them" % [_picks.size(), "" if _picks.size() == 1 else "s",
					Actions.prompt(&"secondary"), "round" if id == "fillet" else "bevel"])
			else:
				if _picks.is_empty():
					var e := _edge_at(hit)
					if e.is_empty():
						hud.toast("Pick edges first: aim at one and press %s" % Actions.prompt(&"primary"))
						return
					_picks.append(e)
				var probes := []
				for e in _picks:
					probes.append(e.probe)
				_picks = []
				view.show_picks([], [])
				picked_feature_requested.emit(id, {picks = probes}, "")
		"hole":
			if not on_feature:
				hud.toast("Aim at a face of the part")
				return
			var ref: Dictionary = doc.face_ref(hit)
			var p: Vector3 = hit.point
			if primary:
				p = snap_on_face(p, hit.normal, player.snap_step())
			picked_feature_requested.emit("hole", {point = doc.cad_point(p), normal = ref.normal}, "cut")
		"shell", "draft":
			var what := "open" if id == "shell" else "to draft"
			if primary:
				if not on_feature:
					hud.toast("Aim at a face of the part")
					return
				for i in _picks.size():
					if _picks[i].body == hit.body and _picks[i].face == hit.face:
						_picks.remove_at(i)
						hud.toast("%d face%s %s" % [_picks.size(), "" if _picks.size() == 1 else "s", what])
						return
				_picks.append({ref = doc.face_ref(hit), body = hit.body, face = hit.face})
				hud.toast("%d face%s %s · %s to %s" % [_picks.size(), "" if _picks.size() == 1 else "s", what, Actions.prompt(&"secondary"),
					"hollow the part" if id == "shell" else "draft them from the flat face you aim at"])
			else:
				var refs := []
				for f in _picks:
					refs.append(f.ref)
				if id == "draft":
					if refs.is_empty():
						hud.toast("Pick the faces to draft first: aim at each and press %s" % Actions.prompt(&"primary"))
						return
					if not on_feature or doc.plane_from_hit(hit).is_empty():
						hud.toast("Aim at a flat face to draft from (the neutral plane), then press %s" % Actions.prompt(&"secondary"))
						return
				var base := {faces = refs}
				if id == "draft":
					base.neutral = doc.face_ref(hit)
				_picks = []
				view.show_picks([], [])
				picked_feature_requested.emit(id, base, "")


## Linear and circular patterns and mirror: the primary action picks features, the secondary
## opens the panel with what is aimed at as the direction, axis or plane.
func _act_repeat(primary: bool, hit: Dictionary, on_feature: bool) -> void:
	var id: String = tool().id
	if primary:
		if not on_feature:
			hud.toast("Aim at a feature of the part")
			return
		var fid: String = hit.feature_id
		var at := _picks.find(fid)
		if at >= 0:
			_picks.remove_at(at)
		else:
			_picks.append(fid)
		hud.toast("%d feature%s picked%s · %s to %s" % [_picks.size(), "" if _picks.size() == 1 else "s",
			"" if _picks.is_empty() else " (" + ", ".join(_picks.map(func(f): return _feature_name(f))) + ")",
			Actions.prompt(&"secondary"), "mirror" if id == "mirror" else "repeat"])
		return
	var feats: Array = _picks.duplicate()
	if feats.is_empty() and id != "mirror":
		hud.toast("Pick the features to repeat first: aim at each and press %s" % Actions.prompt(&"primary"))
		return
	var base := {features = feats}
	match id:
		"linear_pattern":
			base.kind = "linear"
			var e: PackedVector3Array = doc.straight_edge_near(hit, 0.3 * player.size) if on_feature else PackedVector3Array()
			if e.size() >= 2:
				var on := Geometry3D.get_closest_point_to_segment(hit.point, e[0], e[1])
				base.dir_edge = {edge = {probe = doc.cad_point(on)}}
		"circular_pattern":
			base.kind = "circular"
			var ax: Variant = _axis_ref(hit)
			if ax != null:
				base.axis_aimed = ax
		"mirror":
			var pl: Variant = _plane_ref(hit)
			if pl is Dictionary:
				base.plane_aimed = pl
	_picks = []
	picked_feature_requested.emit("pattern" if id != "mirror" else "mirror", base, "")


## Combine, split and delete whole bodies. A body is remembered by a face on it.
func _act_bodies(primary: bool, hit: Dictionary, on_feature: bool) -> void:
	var id: String = tool().id
	if id == "delete_body":
		if not primary:
			if doc.undo():
				changed.emit()
			return
		if not on_feature:
			hud.toast("Aim at the body to delete")
			return
		doc.checkpoint()
		var r: Dictionary = doc.insert_feature("body", "", {kind = "delete", target = doc.face_ref(hit)})
		if not r.get("ok", false):
			doc.undo()
			hud.toast(String(r.get("message", "That body cannot be deleted")))
			return
		hud.toast("Body %d deleted (%s undoes)" % [int(hit.body) + 1, Actions.prompt(&"secondary")])
		changed.emit()
		return
	if primary:
		if not on_feature:
			hud.toast("Aim at a body")
			return
		if id == "split":
			_picks = [{ref = doc.face_ref(hit), body = hit.body}]
			hud.toast("Body %d picked · aim at a flat face or plane and press %s to split it" % [int(hit.body) + 1, Actions.prompt(&"secondary")])
			return
		for i in _picks.size():
			if _picks[i].body == hit.body:
				_picks.remove_at(i)
				hud.toast("%d bod%s picked" % [_picks.size(), "y" if _picks.size() == 1 else "ies"])
				return
		_picks.append({ref = doc.face_ref(hit), body = hit.body})
		hud.toast("%d bod%s picked%s · %s to combine them" % [_picks.size(), "y" if _picks.size() == 1 else "ies",
			" (the first is kept)" if _picks.size() == 1 else "", Actions.prompt(&"secondary")])
		return
	if id == "split":
		if _picks.is_empty():
			hud.toast("Pick the body to split first: aim at it and press %s" % Actions.prompt(&"primary"))
			return
		var base := {kind = "split", target = _picks[0].ref}
		var pl: Variant = _plane_ref(hit)
		if pl is Dictionary:
			base.plane_aimed = pl
		_picks = []
		picked_feature_requested.emit("body", base, "")
		return
	if _picks.size() < 2:
		hud.toast("Pick two bodies or more first: aim at each and press %s" % Actions.prompt(&"primary"))
		return
	var tools_refs := []
	for i in range(1, _picks.size()):
		tools_refs.append(_picks[i].ref)
	var target: Dictionary = _picks[0].ref
	_picks = []
	picked_feature_requested.emit("body", {kind = "combine", target = target, tools = tools_refs}, "")


## Starts picking again what a failed feature uses: its own picking tool, or Re-pick for a face.
func start_repair(f: Dictionary) -> void:
	var t: String = f.type
	var tool_for := {fillet = "fillet", chamfer = "chamfer", shell = "shell", draft = "draft", hole = "hole", mirror = "mirror"}
	var id: String = tool_for.get(t, "repick")
	if t == "pattern":
		id = "circular_pattern" if f.params.get("kind", "") == "circular" else "linear_pattern"
	elif t == "body":
		id = "split" if f.params.get("kind", "") == "split" else "combine"
	set_tool_id(id)
	repair = {id = f.id, name = f.name, type = t}
	var how := {
		fillet = "pick its edges, then %s", chamfer = "pick its edges, then %s", shell = "pick the open faces, then %s",
		draft = "pick the faces, then %s on the neutral face", hole = "aim where it goes and press %s",
		pattern = "pick the features, then %s", mirror = "pick the features, then %s on the plane",
		body = "pick the bodies, then %s"}
	var verb: String = how.get(t, "aim at the face it should use and press %s")
	hud.toast("Re-pick for %s: " % f.name + verb % Actions.prompt(&"secondary" if t not in ["hole"] and how.has(t) else &"primary"))


func _act_repick(primary: bool, hit: Dictionary, on_feature: bool) -> void:
	if not primary:
		repair = {}
		hud.toast("Re-pick cancelled")
		set_tool_id("select")
		return
	if repair.is_empty():
		hud.toast("Pick a failed feature in the model panel and press Re-pick")
		return
	if not on_feature:
		hud.toast("Aim at a face of the part")
		return
	var ref: Dictionary = doc.face_ref(hit)
	var base := {}
	match String(repair.type):
		"extrude":
			if doc.plane_from_hit(hit).is_empty():
				hud.toast("Up to face needs a flat face")
				return
			base = {face = ref, end = "up_to_face"}
		"face_offset":
			base = ref.duplicate()
			if not ref.has("role"):
				base.role = null
		"plane":
			if doc.plane_from_hit(hit).is_empty():
				hud.toast("Aim at a flat face")
				return
			base = {base = {face = ref}}
		_:
			hud.toast("%s cannot be re-picked here: edit it or delete it" % repair.name)
			return
	picked_feature_requested.emit(String(repair.type), base, "")


func _feature_name(fid: String) -> String:
	for f in doc.get_features():
		if f.id == fid:
			return f.name
	return fid


## Snaps a point on a face to the grid in the face's own directions (not along its normal).
static func snap_on_face(p: Vector3, n: Vector3, s: float) -> Vector3:
	var out := p
	if absf(n.x) < 0.9:
		out.x = snappedf(p.x, s)
	if absf(n.y) < 0.9:
		out.y = snappedf(p.y, s)
	if absf(n.z) < 0.9:
		out.z = snappedf(p.z, s)
	return out


## The model edge nearest the crosshair, within a reach that grows with the player.
func _edge_at(hit: Dictionary) -> Dictionary:
	if hit.is_empty() or hit.get("ground", false) or is_assembly:
		return {}
	var e: Dictionary = doc.edge_near(hit.point, 0.06 * player.size)
	return e if e.get("ok", false) else {}


func _pick_index(e: Dictionary) -> int:
	var a: Array = e.probe
	for i in _picks.size():
		var b: Array = _picks[i].probe
		if Vector3(a[0], a[1], a[2]).distance_to(Vector3(b[0], b[1], b[2])) < 1e-6:
			return i
	return -1


## The plane a new sketch goes on: the aimed flat face, the ground (Top plane), or the standard
## plane chosen with the tool option. Empty when the aimed face is not flat.
func _sketch_plane(hit: Dictionary, on_feature: bool) -> Dictionary:
	var opt := option()
	if STANDARD_PLANES.has(opt):
		var sp: Dictionary = doc.standard_plane(STANDARD_PLANES[opt])
		return {plane = sp.plane, name = sp.name}
	var ref := _aimed_reference(hit, ["plane", "csys"])
	if not ref.is_empty():
		var rp: Dictionary = doc.reference_plane(ref.id)
		if not rp.is_empty():
			var pl: Dictionary = rp.plane
			pl["ref"] = String(ref.id)  # the sketch stays on the plane when it moves
			return {plane = pl, name = rp.name}
	if on_feature:
		var fp: Dictionary = doc.plane_from_hit(hit)
		return {} if fp.is_empty() else {plane = fp.plane, name = fp.name}
	var top: Dictionary = doc.standard_plane("top")
	return {plane = top.plane, name = top.name}


## The part changed (main.gd): keep the bounding box and centre of mass shown up to date.
func model_changed() -> void:
	if is_assembly or doc == null:
		return
	if _show_bbox:
		_bbox_cache = doc.bounding_box()
	if _show_mass:
		_com_cache = doc.mass_properties().centre_of_mass


## The reference (of the given kinds) under the crosshair, if nearer than the model.
func _aimed_reference(hit: Dictionary, kinds: Array) -> Dictionary:
	if is_assembly or doc == null:
		return {}
	var r: Dictionary = view.pick_reference(player.eye_position(), player.aim_direction(), player.camera.far)
	if r.is_empty() or not (r.kind in kinds):
		return {}
	if not hit.is_empty() and not hit.get("ground", false) and float(hit.get("distance", INF)) < float(r.distance) - 1e-6:
		return {}
	return r


## A plane for building references from what is aimed at: a reference plane, a flat face, or
## (the ground) the Top plane. {} when the face is curved.
func _plane_ref(hit: Dictionary) -> Variant:
	var ref := _aimed_reference(hit, ["plane", "csys"])
	if not ref.is_empty():
		return {feature = ref.id}
	if hit.is_empty() or hit.get("ground", false) or hit.get("feature_id", "") == "":
		return "top"
	if doc.plane_from_hit(hit).is_empty():
		return null
	return {face = doc.face_ref(hit)}


## An axis from what is aimed at: a reference axis, a round face's axis, or the nearest straight
## edge of the aimed face.
func _axis_ref(hit: Dictionary) -> Variant:
	var ref := _aimed_reference(hit, ["axis"])
	if not ref.is_empty():
		return {feature = ref.id}
	if hit.is_empty() or hit.get("ground", false) or hit.get("feature_id", "") == "":
		return null
	if doc.is_cylinder(hit):
		return {cylinder = doc.face_ref(hit)}
	var e: PackedVector3Array = doc.straight_edge_near(hit, 0.3 * player.size)
	if e.size() < 2:
		return null
	var on := Geometry3D.get_closest_point_to_segment(hit.point, e[0], e[1])
	return {edge = {probe = doc.cad_point(on)}}


## A point from what is aimed at: a reference point, or the aimed face's corner nearest the
## crosshair.
func _point_ref(hit: Dictionary) -> Variant:
	var ref := _aimed_reference(hit, ["point", "csys"])
	if not ref.is_empty():
		return {feature = ref.id}
	if hit.is_empty() or hit.get("ground", false) or hit.get("feature_id", "") == "":
		return null
	var p: Variant = _snap_point(hit)
	if p == null or (p as Vector3).distance_to(hit.point) < 1e-12:
		return null  # no corner near
	return {vertex = {probe = doc.cad_point(p)}}


## Builds the reference for the reference tools; multi-pick kinds collect picks first.
func _act_reference(primary: bool, hit: Dictionary) -> void:
	if not primary:
		_ref_picks = []
		hud.toast("%s: start again" % tool().name)
		return
	var id: String = tool().id
	var opt := option()
	var need := 1
	var pick: Variant = null
	var what := ""
	match id:
		"ref_plane":
			match opt:
				"offset":
					pick = _plane_ref(hit)
					what = "a flat face or a plane"
				"at an angle":
					if _ref_picks.is_empty():
						pick = _plane_ref(hit)
						what = "a flat face or a plane"
					else:
						pick = _axis_ref(hit)
						what = "an edge, a round face or an axis lying along that plane"
					need = 2
				"through three points":
					pick = _point_ref(hit)
					what = "a corner or a point"
					need = 3
				"midway":
					pick = _plane_ref(hit)
					what = "a flat face or a plane"
					need = 2
		"ref_axis":
			match opt:
				"edge or cylinder":
					pick = _axis_ref(hit)
					what = "a straight edge or a round face"
				"through two points":
					pick = _point_ref(hit)
					what = "a corner or a point"
					need = 2
				"where two planes meet":
					pick = _plane_ref(hit)
					what = "a flat face or a plane"
					need = 2
		"ref_point":
			match opt:
				"on a corner":
					pick = _point_ref(hit)
					what = "a corner of a part"
				"face centre":
					if not hit.is_empty() and not hit.get("ground", false) and hit.get("feature_id", "") != "":
						pick = {face = doc.face_ref(hit)}
					what = "a face"
				"at the crosshair":
					if not hit.is_empty():
						pick = {at = doc.cad_point(snapped_xz(hit.point) if hit.get("ground", false) else hit.point)}
					what = "the floor or a part"
		"ref_csys":
			if not hit.is_empty() and not hit.get("ground", false) and hit.get("feature_id", "") != "":
				var origin: Variant = _point_ref(hit)
				if origin == null:
					origin = {at = doc.cad_point(hit.point)}
				var z: Array = doc.face_ref(hit).normal
				var x := [1.0, 0.0, 0.0]
				var e: PackedVector3Array = doc.straight_edge_near(hit, 0.6 * player.size)
				if e.size() == 2:
					var a: Array = doc.cad_point(e[0])
					var b: Array = doc.cad_point(e[1])
					x = [b[0] - a[0], b[1] - a[1], b[2] - a[2]]
				pick = {origin = origin, z = z, x = x}
			what = "a face of a part"
	if pick == null:
		hud.toast("Aim at " + what)
		return
	_ref_picks.append(pick)
	if _ref_picks.size() < need:
		hud.toast("%s: now the next one (%d of %d)" % [tool().name, _ref_picks.size() + 1, need])
		return
	var picks := _ref_picks
	_ref_picks = []
	var type: String = {ref_plane = "plane", ref_axis = "axis", ref_point = "point", ref_csys = "csys"}[id]
	var params := {}
	match [id, opt]:
		["ref_plane", "offset"]:
			params = {kind = "offset", base = picks[0], distance = player.grid_step() / 2.0}
		["ref_plane", "at an angle"]:
			params = {kind = "angle", base = picks[0], axis = picks[1], angle = PI / 4.0}
		["ref_plane", "through three points"]:
			params = {kind = "points", points = picks}
		["ref_plane", "midway"]:
			params = {kind = "midplane", base = picks[0], other = picks[1]}
		["ref_axis", "edge or cylinder"]:
			params = {kind = "ref", ref = picks[0]}
		["ref_axis", "through two points"]:
			params = {kind = "points", points = picks}
		["ref_axis", "where two planes meet"]:
			params = {kind = "planes", base = picks[0], other = picks[1]}
		["ref_point", "on a corner"]:
			params = {kind = "ref", ref = picks[0]}
		["ref_point", "face centre"]:
			params = {kind = "centre", face = picks[0].face}
		["ref_point", "at the crosshair"]:
			var at: Array = picks[0].at
			params = {kind = "xyz", x = at[0], y = at[1], z = at[2]}
		_:
			params = picks[0]
	add_reference(type, params)


## Adds a reference feature; main.gd opens the feature panel for kinds with sizes (live, like
## Extrude) and calls insert_reference for the rest.
func add_reference(type: String, params: Dictionary) -> bool:
	if reference_requested.get_connections().size() > 0:
		reference_requested.emit(type, params)
		return true
	return insert_reference(type, params)


func insert_reference(type: String, params: Dictionary) -> bool:
	doc.checkpoint()
	var r: Dictionary = doc.insert_feature(type, "", params)
	if not r.get("ok", false):
		doc.undo()
		hud.toast(r.get("message", "That reference could not be made"))
		return false
	hud.toast("%s added" % r.get("name", type.capitalize()))
	changed.emit()
	return true


## The sketch whose lines or regions are under the crosshair.
func _aimed_sketch(include_used: bool) -> Dictionary:
	if is_assembly or doc == null:
		return {}
	return doc.pick_sketch(player.eye_position(), player.aim_direction(), player.camera.far, 0.02, include_used)


## The sketch a feature tool works on: the one aimed at, else the newest unused one.
func _feature_sketch() -> String:
	var s := _aimed_sketch(false)
	return s.feature_id if not s.is_empty() else doc.latest_unused_sketch()


func _target_id(hit: Dictionary) -> String:
	if hit.is_empty() or hit.get("ground", false):
		return ""
	return hit.get("component_id", hit.get("feature_id", ""))


## Moves the grabbed feature so it follows the crosshair across the plane it was grabbed on.
func _update_grab() -> void:
	var o: Vector3 = player.eye_position()
	var dir: Vector3 = player.aim_direction()
	if absf(dir.y) < 1e-4:
		return
	var t: float = (_grab.plane_y - o.y) / dir.y
	if t <= 0.0:
		return
	var p := o + dir * t
	var s: float = player.snap_step()
	var delta := Vector3(snappedf(p.x - _grab.last.x, s), 0, snappedf(p.z - _grab.last.z, s))
	if delta.length() < s * 0.5:
		return
	if is_assembly:
		_grab.offset += delta
		_grab.last += delta
		view.preview_component_offset(_grab.component, _grab.offset)
		return
	var r: Dictionary = doc.move_feature(_grab.id, delta)
	if r.ok:
		_grab.last += delta
		changed.emit()


func _drop() -> void:
	if is_assembly and _grab.has("component"):
		var c: Dictionary = doc.component(_grab.component)
		var t: Transform3D = c.transform
		t.origin += _grab.offset
		var r: Dictionary = doc.set_component_transform(_grab.id, t)
		hud.toast(r.message)
		_grab = {}
		changed.emit()
		return
	_grab = {}
	hud.toast("Dropped")


func _cancel_grab() -> void:
	if not is_assembly and doc.undo():
		changed.emit()
	if is_assembly:
		view.preview_component_offset(_grab.component, Vector3.ZERO)
	_grab = {}
	hud.toast("Move cancelled")


func _snap_point(hit: Dictionary) -> Variant:
	if hit.is_empty():
		return null
	var p: Vector3 = hit.point
	if option() == "free":
		return p
	var limit: float = 0.22 * player.size
	if hit.has("snap_vertices"):  # the challenge target, measured like a part
		var near_v: Variant = null
		for v in hit.snap_vertices:
			if v.distance_to(p) < limit and (near_v == null or v.distance_to(p) < near_v.distance_to(p)):
				near_v = v
		return near_v if near_v != null else p
	if hit.get("ground", false):
		var g := snapped_xz(p)
		return g if g.distance_to(p) < limit else p
	if is_assembly:
		return p
	var best: Variant = null
	for v in doc.face_vertices(hit.body, hit.face):
		if v.distance_to(p) < limit and (best == null or v.distance_to(p) < best.distance_to(p)):
			best = v
	return best if best != null else p


## Measures the face or edge aimed at (area, length, radius), or the angle between two picks.
func _measure_pick(hit: Dictionary) -> void:
	var m := _measured(hit)
	if m.is_empty():
		hud.toast("Aim at a face or an edge of the part")
		return
	_measure_a = null
	_measure_b = null
	if option() == "face or edge":
		_measure_info = m.text
		hud.toast(m.text)
		return
	if m.dir == null:
		hud.toast("%s has no direction to measure an angle from: pick a flat face, a straight edge or a round face's axis" % m.what)
		return
	if _angle_first.is_empty():
		_angle_first = m
		_measure_info = ""
		hud.toast("First: %s · now aim at the second and press %s" % [m.what, Actions.prompt(&"primary")])
		return
	var a: Vector3 = _angle_first.dir
	var b: Vector3 = m.dir
	var deg := rad_to_deg(acos(clampf(absf(a.dot(b)), 0.0, 1.0)))
	_measure_info = "Angle %.2f° (%.2f°) between %s and %s" % [deg, 180.0 - deg, _angle_first.what, m.what]
	hud.toast(_measure_info)
	_angle_first = {}


## What the crosshair is on, measured: {what, text, dir (a direction or null), points (edge)}.
func _measured(hit: Dictionary) -> Dictionary:
	if hit.is_empty() or hit.get("ground", false) or is_assembly or String(hit.get("feature_id", "")) == "":
		return {}
	var e: Dictionary = doc.edge_near(hit.point, 0.04 * player.size)
	if e.get("ok", false):
		var r := float(e.get("radius", 0.0))
		var pts: PackedVector3Array = e.points
		var text := "Edge length %s" % hud.length(float(e.length))
		var dir: Variant = null
		if r > 0.0:
			text += " · radius %s · diameter %s" % [hud.length(r), hud.length(2.0 * r)]
		elif pts.size() >= 2:
			dir = (pts[pts.size() - 1] - pts[0]).normalized()
		return {what = "an edge", text = text, dir = dir, points = pts}
	var f: Dictionary = doc.face_measure(hit)
	if not f.get("ok", false):
		return {}
	var text := "Face area %s" % Units.area_text(float(f.area), hud.units)
	var dir: Variant = null
	var what := "a face"
	match String(f.kind):
		"plane":
			dir = (f.normal as Vector3).normalized()
			what = "a flat face"
		"cylinder", "cone":
			text += " · radius %s · diameter %s" % [hud.length(float(f.radius)), hud.length(2.0 * float(f.radius))]
			dir = (f.axis as Vector3).normalized()
			what = "a round face's axis"
		"sphere":
			text += " · sphere radius %s" % hud.length(float(f.radius))
		"torus":
			text += " · tube radius %s · ring radius %s" % [hud.length(float(f.radius)), hud.length(float(f.radius2))]
	return {what = what, text = text, dir = dir, points = PackedVector3Array()}


## The section plane for the Section tool's option: through the crosshair facing the player,
## a standard plane, or the aimed flat face. The side the player stands on is cut away.
func _section_plane(hit: Dictionary) -> Dictionary:
	var eye: Vector3 = player.camera.global_position if player.get("camera") != null else Vector3.ZERO
	var opt := option()
	var origin := Vector3.ZERO
	var normal := Vector3.ZERO
	match opt:
		"facing me":
			if hit.is_empty():
				return {}
			origin = hit.point
			var look: Vector3 = hit.point - eye
			look.y = 0.0
			if look.length() < 1e-9:
				return {}
			normal = Vector3(signf(look.x), 0, 0) if absf(look.x) > absf(look.z) else Vector3(0, 0, signf(look.z))
			normal = -normal  # toward the player: their side is taken away
		"Front plane", "Right plane", "Top plane":
			var sp: Dictionary = doc.standard_plane(STANDARD_PLANES[opt])
			var basis: Dictionary = doc.plane_basis(sp.plane)
			origin = basis.origin
			normal = basis.normal
			if (eye - origin).dot(normal) < 0.0:
				normal = -normal
		"aimed face":
			if hit.is_empty() or hit.get("ground", false) or String(hit.get("feature_id", "")) == "":
				return {}
			if doc.plane_from_hit(hit).is_empty():
				return {}
			origin = hit.point
			normal = hit.normal
	return {origin = origin, normal = normal}


func measure_text() -> String:
	if _measure_info != "":
		return _measure_info
	if _measure_a == null or _measure_b == null:
		return ""
	var d: Vector3 = _measure_b - _measure_a
	# Report in CAD axes: X = x, Y = -z, Z = y.
	return "%s   ΔX %s  ΔY %s  ΔZ %s" % [hud.length(d.length()), hud.length(d.x), hud.length(-d.z), hud.length(d.y)]


func _update_preview(hit: Dictionary) -> void:
	var id: String = tool().id
	var label := ""
	view.show_ghost("", Vector3.ZERO, {})
	view.show_plane({}, 0.0)
	view.highlight_sketch("")
	if not is_assembly:
		view.highlight_component(-1)
	var on_feature: bool = not hit.is_empty() and not hit.get("ground", false) and not hit.get("target", false)
	var face_plane := false
	match id:
		"sketch":
			if not is_assembly:
				var opt := option()
				if STANDARD_PLANES.has(opt):
					var sp: Dictionary = doc.standard_plane(STANDARD_PLANES[opt])
					view.show_plane(doc.plane_basis(sp.plane), 3.0 * player.size)
					label = "New sketch on the %s plane" % sp.name
				elif on_feature:
					face_plane = true
					label = "New sketch on this face of %s" % hit.get("feature_name", "")
				else:
					var tp: Dictionary = doc.standard_plane("top")
					view.show_plane(doc.plane_basis(tp.plane), 3.0 * player.size)
					label = "New sketch on the Top plane"
				var aimed := _aimed_sketch(true)
				if not aimed.is_empty():
					label += "  ·  %s edit %s" % [Actions.prompt(&"secondary"), aimed.get("name", "sketch")]
		"extrude", "revolve", "sweep", "loft":
			if not is_assembly:
				var sid := _feature_sketch()
				view.highlight_sketch(sid)
				label = ("%s %s" % [tool().name, _sketch_name(sid)]) if sid != "" else "No sketch to use yet"
		"select", "delete":
			if on_feature:
				label = ("Delete " if id == "delete" else "") + hit.get("component_name", hit.get("feature_name", ""))
		"push":
			var h: Dictionary = _push_hit if not _push_hit.is_empty() else hit
			if on_feature or not _push_hit.is_empty():
				if h.has("drive_label"):
					label = "%s · %s %s" % [h.get("feature_name", ""), h.drive_label, hud.length(h.drive_value)]
				else:
					label = "%s · add or remove stock" % h.get("feature_name", "")
		"box", "cylinder", "sphere":
			if not hit.is_empty() and not is_assembly:
				var d := place_dims(id)
				view.show_ghost(id, place_base(hit, id), d)
				label = "Place " + _dims_text(d) + ("" if _place_dims.has(id) else " (auto)")
				if option() != "add":
					label += " · " + option()
		"move":
			if not _grab.is_empty():
				label = "Moving · %s drops · %s cancels" % [Actions.prompt(&"primary"), Actions.prompt(&"secondary")]
			elif on_feature:
				label = "Grab " + hit.get("component_name", hit.get("feature_name", ""))
		"ref_plane", "ref_axis", "ref_point", "ref_csys":
			var kinds: Array = ["plane", "csys"] if id == "ref_plane" else (["axis"] if id == "ref_axis" else ["point", "csys"])
			var rr := _aimed_reference(hit, kinds)
			view.highlight_reference(rr.get("id", ""))
			var step_txt := " (%d)" % (_ref_picks.size() + 1) if not _ref_picks.is_empty() else ""
			label = "%s · %s%s" % [tool().name, option() if option() != "" else "on this face", step_txt]
			if not rr.is_empty():
				label += " · " + String(rr.name)
			elif on_feature and id != "ref_point":
				face_plane = true
		"measure":
			if option() in ["face or edge", "angle"]:
				var mm := _measured(hit)
				view.show_picks([] if mm.is_empty() else [mm.points], [])
				if not mm.is_empty():
					label = mm.text.get_slice(" · ", 0) if option() == "angle" else mm.text
					face_plane = (mm.points as PackedVector3Array).is_empty()
				view.show_measure(null, null, null, s_size())
			else:
				var sp: Variant = _snap_point(hit)
				if _measure_a != null and _measure_b == null and sp != null:
					var spv: Vector3 = sp
					label = hud.length(spv.distance_to(_measure_a))
				view.show_measure(_measure_a, _measure_b, sp, s_size())
		"section":
			if not hit.is_empty():
				label = "Cut here (%s)" % option()
	if id != "measure":
		view.show_measure(_measure_a, _measure_b, null, s_size())
	if id == "interference" and not _clashes.is_empty():
		view.show_com(_clashes[0].centre, 0.15 * player.size)
	if id in PICK_TOOLS and not is_assembly:
		label = _pick_preview(id, hit, on_feature, label)
		face_plane = on_feature and id in ["hole", "shell", "draft"]
	if not (id in REF_TOOLS):
		view.highlight_reference("")
	if id == "sketch" and not is_assembly and option() == "aimed face":
		var sr := _aimed_reference(hit, ["plane", "csys"])
		view.highlight_reference(sr.get("id", ""))
		if not sr.is_empty():
			label = "New sketch on %s" % sr.name
			face_plane = false
	view.show_bbox(_bbox_cache if _show_bbox and id == "bbox" and not is_assembly else {})
	if _show_mass and id == "mass" and not is_assembly and _com_cache != null:
		view.show_com(_com_cache, 0.15 * player.size)
	elif not (id == "interference" and not _clashes.is_empty()):
		view.show_com(null, 0.0)
	# Highlights: the face being pushed, or the feature/component under the crosshair.
	if is_assembly:
		view.highlight_component(hit.get("component", -1) if on_feature and id in ["select", "move"] else -1)
	elif face_plane:
		view.highlight(hit.body, "", hit.face, s_size())
	elif id == "push" and (on_feature or not _push_hit.is_empty()):
		var h2: Dictionary = _push_hit if not _push_hit.is_empty() else hit
		view.highlight(h2.get("body", -1), "", h2.get("face", -1), s_size())
	elif on_feature and id in ["select", "move", "delete"] + FEATURE_PICK_TOOLS:
		view.highlight(hit.body, hit.feature_id, -1, s_size())
	elif selected != "" and not is_assembly:
		view.highlight(0, selected, -1, s_size())
	else:
		view.clear_highlight()
	hud.set_aim(label, on_feature)


## The Mass properties readout: volume, surface area and mass in the document's units, then the
## centre of mass (already formatted, X Y Z as the player sees them).
static func mass_summary(m: Dictionary, units: String, cx: String, cy: String, cz: String, mass_unit := "") -> String:
	return "Volume %s · area %s · mass %s · centre of mass X %s Y %s Z %s" % [
		Units.volume_text(float(m.volume), units), Units.area_text(float(m.area), units),
		Units.mass_text(float(m.mass), mass_unit), cx, cy, cz]


## Draws the picked edges and faces and the edge under the crosshair; returns the aim label.
func _pick_preview(id: String, hit: Dictionary, on_feature: bool, label: String) -> String:
	var edges := []
	var faces := []
	var hover := PackedVector3Array()
	match id:
		"fillet", "chamfer":
			for e in _picks:
				edges.append(e.points)
			var e := _edge_at(hit)
			if not e.is_empty():
				hover = e.points
				var r := float(e.get("radius", 0.0))
				label = "Edge · %s%s" % [hud.length(float(e.length)), (" · R %s" % hud.length(r)) if r > 0.0 else ""]
				if _pick_index(e) >= 0:
					label += " · picked"
		"shell", "draft":
			for f in _picks:
				faces.append([f.body, f.face])
			if on_feature:
				label = "Face · %d %s" % [_picks.size(), "open" if id == "shell" else "to draft"]
		"linear_pattern", "circular_pattern", "mirror":
			if on_feature:
				label = "%s%s · %d picked" % [hit.get("feature_name", ""), " (picked)" if hit.feature_id in _picks else "", _picks.size()]
		"combine", "split", "delete_body":
			if on_feature:
				var picked := _picks.any(func(b): return b.body == hit.body)
				label = "Body %d%s" % [int(hit.body) + 1, " (picked)" if picked else ""]
		"hole":
			if on_feature:
				label = "Hole here"
	view.show_picks(edges, faces, hover)
	return label


func _sketch_name(id: String) -> String:
	for v in doc.sketch_views():
		if v.id == id:
			return v.name
	return "sketch"


func s_size() -> float:
	return player.size


func _dims_text(d: Dictionary) -> String:
	if d.has("w"):
		return "%s × %s × %s" % [hud.length(d.w), hud.length(d.d), hud.length(d.h)]
	if d.has("h"):
		return "⌀%s × %s" % [hud.length(d.r * 2.0), hud.length(d.h)]
	return "⌀%s" % hud.length(d.r * 2.0)
