extends Node
## The tool set ("weapons"). Each tool has a primary action (RT / left click), a secondary action
## (LT / right click) and one context option cycled with LB / E. Tools act on the CAD document
## through the extension; the model view only draws.

signal changed  # the document changed; redraw it
signal tool_switched(index: int)

const TOOLS := [
	{id = "select", name = "Select", pri = "select feature", alt = "match my size to it", opt = []},
	{id = "push", name = "Push / Pull", pri = "push face out", alt = "pull face in", opt = ["snap step", "grid step", "fine step"]},
	{id = "box", name = "Box", pri = "place box", alt = "copy size from target", opt = ["add", "cut", "new body"]},
	{id = "cylinder", name = "Cylinder", pri = "place cylinder", alt = "copy size from target", opt = ["add", "cut", "new body"]},
	{id = "sphere", name = "Sphere", pri = "place sphere", alt = "copy size from target", opt = ["add", "cut", "new body"]},
	{id = "move", name = "Move", pri = "grab / drop", alt = "duplicate & grab", opt = []},
	{id = "measure", name = "Measure", pri = "set point", alt = "clear", opt = ["snap to corners", "free"]},
	{id = "delete", name = "Delete", pri = "delete target", alt = "undo", opt = []},
]
const PART_ONLY := ["push", "box", "cylinder", "sphere", "delete"]
const OPS := {"add": "add", "cut": "cut", "new body": "new-body"}

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


func tool() -> Dictionary:
	return TOOLS[index]


func option() -> String:
	var opts: Array = tool().opt
	return "" if opts.is_empty() else opts[options.get(tool().id, 0)]


func set_tool(i: int) -> void:
	if i < 0 or i >= TOOLS.size():
		return
	if not _grab.is_empty():
		_drop()
	index = i
	_push_hit = {}
	_hold_time = -1.0
	view.show_ghost("", Vector3.ZERO, {})
	view.clear_highlight()
	tool_switched.emit(i)


func cycle_option() -> void:
	var opts: Array = tool().opt
	if opts.is_empty():
		hud.toast("%s has no options" % tool().name)
		return
	var n: int = (options.get(tool().id, 0) + 1) % opts.size()
	options[tool().id] = n
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
					player.set_size(biggest / (1.75 * 1.6))  # the part fills a comfortable view
					hud.toast("Sized to %s" % hit.feature_name)
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
		"measure":
			if not primary:
				_measure_a = null
				_measure_b = null
				return
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
			if on_feature:
				var r: Dictionary = doc.delete_feature(hit.feature_id)
				hud.toast(r.message)
				if hit.feature_id == selected:
					selected = ""
				changed.emit()


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


func measure_text() -> String:
	if _measure_a == null or _measure_b == null:
		return ""
	var d: Vector3 = _measure_b - _measure_a
	# Report in CAD axes: X = x, Y = -z, Z = y.
	return "%s   ΔX %s  ΔY %s  ΔZ %s" % [hud.length(d.length()), hud.length(d.x), hud.length(-d.z), hud.length(d.y)]


func _update_preview(hit: Dictionary) -> void:
	var id: String = tool().id
	var label := ""
	view.show_ghost("", Vector3.ZERO, {})
	if not is_assembly:
		view.highlight_component(-1)
	var on_feature: bool = not hit.is_empty() and not hit.get("ground", false)
	match id:
		"select", "delete":
			if on_feature:
				label = ("Delete " if id == "delete" else "") + hit.get("component_name", hit.get("feature_name", ""))
		"push":
			var h: Dictionary = _push_hit if not _push_hit.is_empty() else hit
			if on_feature or not _push_hit.is_empty():
				if h.has("drive_label"):
					label = "%s · %s %s" % [h.get("feature_name", ""), h.drive_label, hud.length(h.drive_value)]
				else:
					label = "%s · no driving dimension" % h.get("feature_name", "")
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
		"measure":
			var sp: Variant = _snap_point(hit)
			if _measure_a != null and _measure_b == null and sp != null:
				var spv: Vector3 = sp
				label = hud.length(spv.distance_to(_measure_a))
			view.show_measure(_measure_a, _measure_b, sp, s_size())
	if id != "measure":
		view.show_measure(_measure_a, _measure_b, null, s_size())
	# Highlights: the face being pushed, or the feature/component under the crosshair.
	if is_assembly:
		view.highlight_component(hit.get("component", -1) if on_feature and id in ["select", "move"] else -1)
	elif id == "push" and (on_feature or not _push_hit.is_empty()):
		var h2: Dictionary = _push_hit if not _push_hit.is_empty() else hit
		view.highlight(h2.get("body", -1), "", h2.get("face", -1), s_size())
	elif on_feature and id in ["select", "move", "delete"]:
		view.highlight(hit.body, hit.feature_id, -1, s_size())
	elif selected != "" and not is_assembly:
		view.highlight(0, selected, -1, s_size())
	else:
		view.clear_highlight()
	hud.set_aim(label, on_feature)


func s_size() -> float:
	return player.size


func _dims_text(d: Dictionary) -> String:
	if d.has("w"):
		return "%s × %s × %s" % [hud.length(d.w), hud.length(d.d), hud.length(d.h)]
	if d.has("h"):
		return "⌀%s × %s" % [hud.length(d.r * 2.0), hud.length(d.h)]
	return "⌀%s" % hud.length(d.r * 2.0)
