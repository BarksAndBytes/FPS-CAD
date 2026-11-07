extends Node3D
## Draws the model: shaded bodies, feature edges, highlights, placement ghosts and measure
## markers, inside the room (room.gd: the white room and the table the model stands on). Re-tessellates when the player's size changes enough that the mesh would
## look faceted (growing smaller) or wastefully dense (growing larger).

const COLOR_PART := Color("b7bfc8")  # a cool grey that reads against the white room and the wood
const COLOR_EDGE := Color("1c222a")
const COLOR_ACCENT := Color("ff8a3d")
const COLOR_MEASURE := Color("ffd166")
const COLOR_SKETCH := Color("1f6fd1")
const COLOR_SKETCH_BAD := Color("d64545")
const COLOR_CONSTRUCTION := Color("7d8794")
const COLOR_REF := Color("23917a")  # reference geometry: planes, axes, points
const COLOR_BBOX := Color("8a63d2")
const FatLines := preload("res://scripts/fat_lines.gd")

## CadPart or CadAssembly (untyped so a missing extension shows an error instead of a parse failure)
var doc: RefCounted
var is_assembly := false

var _body_mat := StandardMaterial3D.new()
var appearance := {}  # what set_appearance last applied
var _edge_mat := StandardMaterial3D.new()
var _hl_mat := StandardMaterial3D.new()
var _ghost_mat := StandardMaterial3D.new()
var _overlay_mat := StandardMaterial3D.new()
var _measure_mat := StandardMaterial3D.new()

var _bodies: Array[MeshInstance3D] = []
var _edges: Array[MeshInstance3D] = []
var _arrays: Array = []           # per body: surface arrays of the last mesh (part mode)
var _tri_faces: Array = []        # per body: PackedInt32Array
var _face_features: Array = []    # per body: PackedStringArray
var _components: Array[MeshInstance3D] = []  # assembly mode, one per placed component
var _component_nodes := {}  # component index -> [mesh instance, edge instance, transform]
var _mesh_size := -1.0

var _highlight := MeshInstance3D.new()
var _pick_lines := MeshInstance3D.new()   # edges picked for a fillet or chamfer, and the one aimed at
var _pick_faces := MeshInstance3D.new()   # faces picked for a shell
var _ghost := MeshInstance3D.new()
var room: Node3D  # room.gd
var _marker_a := MeshInstance3D.new()
var _marker_b := MeshInstance3D.new()
var _marker_snap := MeshInstance3D.new()
var _measure_line := MeshInstance3D.new()
var _hl_key := ""
var _sketch_mat: ShaderMaterial
var _sketch_bad_mat: ShaderMaterial
var _sketch_hl_mat: ShaderMaterial
var _sketch_constr_mat: ShaderMaterial
var _sketch_fill_mat := StandardMaterial3D.new()
var _plane_mat := StandardMaterial3D.new()
var _sketches := {}  # feature id -> Node3D holding lines, construction and fill (unused sketches)
var _sketch_lines := {}  # feature id -> the MeshInstance3D drawing its solid lines
var _sketch_ok := {}
var _plane := MeshInstance3D.new()
var _hl_sketch := ""
## Reference geometry from the last refresh (CadPart.reference_views, Godot space).
var references: Array = []
var _ref_holder := Node3D.new()
var _ref_lines := {}   # feature id -> MeshInstance3D of its outline (to highlight)
var _ref_mat: ShaderMaterial
var _ref_hl_mat: ShaderMaterial
var _ref_fill_mat := StandardMaterial3D.new()
var _hl_ref := ""
var _bbox := MeshInstance3D.new()
var _com := MeshInstance3D.new()
## A sketch being edited in sketch mode is drawn by the sketcher, not here.
var hidden_sketch := ""


func _ready() -> void:
	_body_mat.albedo_color = COLOR_PART
	_body_mat.roughness = 0.82
	_body_mat.metallic = 0.04
	_edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_edge_mat.albedo_color = COLOR_EDGE
	for m in [_hl_mat, _ghost_mat, _overlay_mat]:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_hl_mat.albedo_color = Color(COLOR_ACCENT, 0.45)
	_ghost_mat.albedo_color = Color(COLOR_ACCENT, 0.25)
	_overlay_mat.albedo_color = Color(COLOR_ACCENT, 0.3)
	_measure_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_measure_mat.albedo_color = COLOR_MEASURE
	_measure_mat.no_depth_test = true
	_measure_mat.render_priority = 10
	_sketch_mat = FatLines.material(COLOR_SKETCH, 3.0, true)
	_sketch_bad_mat = FatLines.material(COLOR_SKETCH_BAD, 3.0, true)
	_sketch_hl_mat = FatLines.material(COLOR_ACCENT, 3.5, true)
	_sketch_constr_mat = FatLines.material(COLOR_CONSTRUCTION, 2.0, true)
	_sketch_fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sketch_fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_sketch_fill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_sketch_fill_mat.no_depth_test = true
	_sketch_fill_mat.render_priority = 6
	_sketch_fill_mat.albedo_color = Color(COLOR_SKETCH, 0.18)
	_plane_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_plane_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_plane_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_plane_mat.albedo_color = Color(COLOR_SKETCH, 0.16)
	_plane_mat.vertex_color_use_as_albedo = false
	_plane.mesh = ImmediateMesh.new()
	_plane.material_override = _plane_mat
	_plane.visible = false
	add_child(_plane)
	_ref_mat = FatLines.material(COLOR_REF, 2.5, true)  # seen through parts, like sketches
	_ref_hl_mat = FatLines.material(COLOR_ACCENT, 3.5, true)
	_ref_fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ref_fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ref_fill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ref_fill_mat.albedo_color = Color(COLOR_REF, 0.12)
	_ref_fill_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	add_child(_ref_holder)
	for n in [_bbox, _com]:
		n.visible = false
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(n)
	_bbox.material_override = FatLines.material(COLOR_BBOX, 2.5, true)
	_com.material_override = FatLines.material(COLOR_BBOX, 3.5, true)

	room = preload("res://scripts/room.gd").new()
	add_child(room)

	_highlight.material_override = _hl_mat
	_pick_lines.material_override = FatLines.material(COLOR_ACCENT, 5.0, true)
	_pick_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_pick_lines)
	_pick_faces.material_override = _overlay_mat
	_pick_faces.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_pick_faces)
	_ghost.material_override = _ghost_mat
	for n in [_highlight, _ghost, _marker_a, _marker_b, _marker_snap, _measure_line]:
		n.visible = false
		add_child(n)
	var dot := SphereMesh.new()
	dot.radius = 1.0
	dot.height = 2.0
	for n in [_marker_a, _marker_b, _marker_snap]:
		n.mesh = dot
		n.material_override = _measure_mat
	_measure_line.mesh = ImmediateMesh.new()
	_measure_line.material_override = _measure_mat


## Makes the part look like its material (CadPart.material_info): colour, metal or not, shine
## and, for glass and clear plastics, see-through. {} goes back to the plain modelling grey.
func set_appearance(info: Dictionary) -> void:
	var col := Color(String(info.get("color", ""))) if String(info.get("color", "")).begins_with("#") else COLOR_PART
	var opacity := clampf(float(info.get("opacity", 1.0)), 0.15, 1.0)
	_body_mat.albedo_color = Color(col, opacity)
	# Full metal reflects only its surroundings, and the room is plain white: keep some colour.
	_body_mat.metallic = minf(float(info.get("metallic", 0.04)), 0.75)
	_body_mat.roughness = clampf(float(info.get("roughness", 0.82)), 0.08, 1.0)
	_body_mat.metallic_specular = 0.6 if float(info.get("metallic", 0.0)) > 0.5 else 0.5
	_body_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS if opacity < 0.99 else BaseMaterial3D.TRANSPARENCY_DISABLED
	appearance = info


## Called every frame with the camera so the room and tessellation follow the player.
func follow(camera_pos: Vector3, size: float) -> void:
	room.follow(camera_pos, size)
	if _mesh_size < 0.0 or size / _mesh_size > 4.0 or _mesh_size / size > 4.0:
		refresh(size)


## Rebuilds every display mesh from the document at a deflection suited to the player's size.
func refresh(size: float = -1.0) -> void:
	if size > 0.0:
		_mesh_size = size
	var defl := clampf(0.0015 * _mesh_size, 2e-7, 0.5)
	for n in _bodies + _edges + _components:
		n.queue_free()
	for id in _sketches:
		_sketches[id].queue_free()
	_sketches.clear()
	_sketch_lines.clear()
	_sketch_ok.clear()
	_bodies.clear()
	_edges.clear()
	_components.clear()
	_component_nodes.clear()
	_arrays.clear()
	_tri_faces.clear()
	_face_features.clear()
	_hl_key = ""
	_highlight.visible = false
	for c in _ref_holder.get_children():
		c.queue_free()
	_ref_lines.clear()
	references = []
	if doc == null:
		return
	if is_assembly:
		_refresh_assembly(defl)
		return
	for b in doc.body_count():
		var mesh: ArrayMesh = doc.build_mesh(b, defl)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _body_mat
		add_child(mi)
		_bodies.append(mi)
		_arrays.append(mesh.surface_get_arrays(0) if mesh.get_surface_count() > 0 else [])
		_tri_faces.append(doc.triangle_faces(b))
		_face_features.append(doc.face_feature_ids(b))
		_edges.append(_make_edges(doc.build_edges(b, defl)))
	_refresh_sketches()
	_refresh_references()


## Unused sketches show as lines in the world (used ones hide, as in most CAD tools).
func _refresh_sketches() -> void:
	if not doc.has_method("sketch_views"):
		return
	for v in doc.sketch_views():
		if v.consumed or v.id == hidden_sketch:
			continue
		var segs: PackedVector3Array = v.segments
		var constr: PackedVector3Array = v.construction
		if segs.size() < 2 and constr.size() < 2:
			continue
		var holder := Node3D.new()
		add_child(holder)
		var good: bool = v.ok and v.regions > 0
		var lines := MeshInstance3D.new()
		lines.mesh = FatLines.mesh(segs)
		lines.material_override = _sketch_mat if good else _sketch_bad_mat
		lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(lines)
		var dashes := MeshInstance3D.new()
		dashes.mesh = FatLines.mesh(FatLines.dashed(constr, 0.012 * maxf(_mesh_size, 1e-4)))
		dashes.material_override = _sketch_constr_mat
		dashes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(dashes)
		var fill: PackedVector3Array = v.get("fill", PackedVector3Array())
		if fill.size() >= 3:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = fill
			var fm := ArrayMesh.new()
			fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var shade := MeshInstance3D.new()
			shade.mesh = fm
			shade.material_override = _sketch_fill_mat
			shade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			holder.add_child(shade)
		_sketches[v.id] = holder
		_sketch_lines[v.id] = lines
		_sketch_ok[v.id] = good
	if _hl_sketch != "":
		var keep := _hl_sketch
		_hl_sketch = ""
		highlight_sketch(keep)


## Planes as tinted squares with an outline, axes as dashed lines, points as small crosses and
## coordinate systems as red / green / blue arrows, each with its name.
func _refresh_references() -> void:
	if not doc.has_method("reference_views"):
		return
	references = doc.reference_views()
	for v in references:
		if not v.ok:
			continue
		var o: Vector3 = v.origin
		var s: float = v.size
		var lines := PackedVector3Array()
		var tag_at := o
		match String(v.kind):
			"plane":
				var x: Vector3 = v.xdir * s
				var y: Vector3 = v.ydir * s
				var corners := [o - x - y, o + x - y, o + x + y, o - x + y]
				for i in 4:
					lines.append(corners[i])
					lines.append(corners[(i + 1) % 4])
				var fill := MeshInstance3D.new()
				var arrays := []
				arrays.resize(Mesh.ARRAY_MAX)
				arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]])
				var fm := ArrayMesh.new()
				fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				fill.mesh = fm
				fill.material_override = _ref_fill_mat
				fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				_ref_holder.add_child(fill)
				tag_at = corners[3]
			"axis":
				var d: Vector3 = v.xdir * s
				lines = FatLines.dashed(PackedVector3Array([o - d, o + d]), s * 0.06)
				tag_at = o + d
			"point":
				for a in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
					lines.append(o - a * s)
					lines.append(o + a * s)
			"csys":
				for pair in [[v.xdir, Color("e04848")], [v.ydir, Color("3fb950")], [v.normal, Color("3d7be0")]]:
					var arm := MeshInstance3D.new()
					arm.mesh = FatLines.mesh(PackedVector3Array([o, o + (pair[0] as Vector3) * s]))
					arm.material_override = FatLines.material(pair[1], 3.0, true)
					arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					_ref_holder.add_child(arm)
				lines.append(o)
				lines.append(o)
		var mi := MeshInstance3D.new()
		mi.mesh = FatLines.mesh(lines)
		mi.material_override = _ref_hl_mat if v.id == _hl_ref else _ref_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ref_holder.add_child(mi)
		_ref_lines[v.id] = mi
		var tag := Label3D.new()
		tag.text = v.name
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.fixed_size = true
		tag.pixel_size = 0.0007
		tag.font_size = 30
		tag.no_depth_test = true
		tag.outline_size = 8
		tag.modulate = COLOR_REF.darkened(0.3)
		tag.outline_modulate = Color(1, 1, 1, 0.85)
		tag.position = tag_at
		_ref_holder.add_child(tag)


## The reference under a ray: a plane hit inside its square, or an axis or point passing within
## the pick tolerance (radians of view). {id, kind, distance, point} or {}.
func pick_reference(origin: Vector3, dir: Vector3, max_distance: float, tolerance := 0.02) -> Dictionary:
	var best := {}
	for v in references:
		if not v.ok:
			continue
		var o: Vector3 = v.origin
		var s: float = v.size
		var t := INF
		match String(v.kind):
			"plane", "csys":
				var n: Vector3 = v.normal
				var den := dir.dot(n)
				if absf(den) > 1e-6:
					var tt := (o - origin).dot(n) / den
					var at := origin + dir * tt
					var half := s if v.kind == "plane" else s * 0.5
					if tt > 0.0 and absf((at - o).dot(v.xdir)) <= half and absf((at - o).dot(v.ydir)) <= half:
						t = tt
			"axis":
				var d: Vector3 = v.xdir
				var w := origin - o
				var b := dir.dot(d)
				var den := 1.0 - b * b
				if den > 1e-9:
					var tt := (b * w.dot(d) - w.dot(dir)) / den
					var u := clampf(w.dot(d) + b * tt, -s, s)
					var on_ray := origin + dir * tt
					if tt > 0.0 and on_ray.distance_to(o + d * u) < tolerance * tt:
						t = tt
			"point":
				var tt := (o - origin).dot(dir)
				if tt > 0.0 and (origin + dir * tt).distance_to(o) < maxf(tolerance * tt, s):
					t = tt
		if t < max_distance and (best.is_empty() or t < best.distance):
			best = {id = v.id, kind = v.kind, distance = t, point = origin + dir * t, name = v.name}
	return best


## Outlines one reference in the accent colour ("" for none).
func highlight_reference(id: String) -> void:
	if id == _hl_ref:
		return
	if _ref_lines.has(_hl_ref):
		_ref_lines[_hl_ref].material_override = _ref_mat
	_hl_ref = id
	if _ref_lines.has(id):
		_ref_lines[id].material_override = _ref_hl_mat


## The parts' bounding box as a wire box (CadPart.bounding_box), or {} to hide it.
func show_bbox(box: Dictionary) -> void:
	if box.is_empty() or not box.get("ok", false):
		_bbox.visible = false
		return
	var a: Vector3 = box.min
	var b: Vector3 = box.max
	var c := []
	for k in 8:
		c.append(Vector3(b.x if k & 1 else a.x, b.y if k & 2 else a.y, b.z if k & 4 else a.z))
	var lines := PackedVector3Array()
	for k in 8:
		for bit in [1, 2, 4]:
			if not (k & bit):
				lines.append(c[k])
				lines.append(c[k | bit])
	_bbox.mesh = FatLines.mesh(lines)
	_bbox.visible = true


## A marker at the centre of mass (size: arm length), or null to hide it.
func show_com(at: Variant, size: float) -> void:
	if at == null:
		_com.visible = false
		return
	var p: Vector3 = at
	var lines := PackedVector3Array()
	for a in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		lines.append(p - a * size)
		lines.append(p + a * size)
	_com.mesh = FatLines.mesh(lines)
	_com.visible = true


## Tints one sketch in the accent colour ("" for none).
func highlight_sketch(id: String) -> void:
	if id == _hl_sketch:
		return
	if _sketch_lines.has(_hl_sketch):
		_sketch_lines[_hl_sketch].material_override = _sketch_mat if _sketch_ok.get(_hl_sketch, true) else _sketch_bad_mat
	_hl_sketch = id
	if _sketch_lines.has(id):
		_sketch_lines[id].material_override = _sketch_hl_mat


## A translucent square showing a sketch plane (basis from CadPart.plane_basis), or none.
func show_plane(basis: Dictionary, half: float) -> void:
	if basis.is_empty():
		_plane.visible = false
		return
	var o: Vector3 = basis.origin
	var x: Vector3 = basis.xdir * half
	var y: Vector3 = basis.ydir * half
	var im: ImmediateMesh = _plane.mesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in [o - x - y, o + x - y, o + x + y, o - x - y, o + x + y, o - x + y]:
		im.surface_add_vertex(v)
	im.surface_end()
	_plane.visible = true


func _refresh_assembly(defl: float) -> void:
	var meshes := []
	var edges := []
	for p in doc.part_count():
		meshes.append(doc.part_mesh(p, defl))
		edges.append(doc.part_edges(p, defl))
	for i in doc.component_count():
		var c: Dictionary = doc.component(i)
		if c.part < 0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = meshes[c.part]
		mi.material_override = _body_mat
		mi.transform = c.transform
		add_child(mi)
		_components.append(mi)
		var e := _make_edges(edges[c.part])
		e.transform = c.transform
		_edges.append(e)
		_component_nodes[i] = [mi, e, c.transform]


func _make_edges(points: PackedVector3Array) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	if points.size() >= 2:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = points
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		mi.mesh = m
	mi.material_override = _edge_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## Highlights every face a feature owns (feature_id), or one face (face >= 0).
func highlight(body: int, feature_id: String, face: int, size: float) -> void:
	var key := "%d|%s|%d" % [body, feature_id, face]
	if key == _hl_key:
		return
	_hl_key = key
	if is_assembly or body < 0 or body >= _arrays.size() or _arrays[body].is_empty():
		_highlight.visible = false
		return
	var arr: Array = _arrays[body]
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var tri_faces: PackedInt32Array = _tri_faces[body]
	var face_features: PackedStringArray = _face_features[body]
	var out := PackedVector3Array()
	var lift := 0.002 * size
	for t in tri_faces.size():
		var f := tri_faces[t]
		var take: bool = f == face if face >= 0 else (f < face_features.size() and face_features[f] == feature_id)
		if not take:
			continue
		for k in 3:
			var vi := idx[t * 3 + k]
			out.append(verts[vi] + normals[vi] * lift)
	if out.is_empty():
		_highlight.visible = false
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_highlight.mesh = m
	_highlight.visible = true


## Picks in progress: edges (polylines, Godot space) and faces ([body, face]) already chosen, and
## the edge under the crosshair (hover, may be empty). Nothing hides them all.
func show_picks(edges: Array, faces: Array, hover := PackedVector3Array()) -> void:
	var segs := PackedVector3Array()
	for poly in edges + [hover]:
		var pts: PackedVector3Array = poly
		for i in range(pts.size() - 1):
			segs.append(pts[i])
			segs.append(pts[i + 1])
	_pick_lines.visible = segs.size() >= 2
	if _pick_lines.visible:
		_pick_lines.mesh = FatLines.mesh(segs)
	var tris := PackedVector3Array()
	for bf in faces:
		tris.append_array(_face_triangles(int(bf[0]), int(bf[1]), 0.003 * _mesh_size if _mesh_size > 0.0 else 0.003))
	_pick_faces.visible = not tris.is_empty()
	if _pick_faces.visible:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = tris
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_pick_faces.mesh = m


## The triangles of one face of a body, lifted along their normals by lift.
func _face_triangles(body: int, face: int, lift: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if is_assembly or body < 0 or body >= _arrays.size() or _arrays[body].is_empty():
		return out
	var arr: Array = _arrays[body]
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var tri_faces: PackedInt32Array = _tri_faces[body]
	for t in tri_faces.size():
		if tri_faces[t] != face:
			continue
		for k in 3:
			var vi := idx[t * 3 + k]
			out.append(verts[vi] + normals[vi] * lift)
	return out


func clear_highlight() -> void:
	_hl_key = ""
	_highlight.visible = false


## Tints one placed component (assembly mode), or none with index -1.
func highlight_component(index: int) -> void:
	for i in _component_nodes:
		_component_nodes[i][0].material_overlay = _overlay_mat if i == index else null


## Shows a component shifted by offset while it is being carried, before the move is committed.
func preview_component_offset(index: int, offset: Vector3) -> void:
	if not _component_nodes.has(index):
		return
	var nodes: Array = _component_nodes[index]
	var t: Transform3D = nodes[2]
	t.origin += offset
	nodes[0].transform = t
	nodes[1].transform = t


## Shows a placement preview. kind: "box", "cylinder", "sphere" or "" to hide.
func show_ghost(kind: String, base: Vector3, dims: Dictionary) -> void:
	if kind == "":
		_ghost.visible = false
		return
	match kind:
		"box":
			var m := BoxMesh.new()
			m.size = Vector3(dims.w, dims.h, dims.d)
			_ghost.mesh = m
			_ghost.position = base + Vector3(0, dims.h / 2.0, 0)
		"cylinder":
			var m := CylinderMesh.new()
			m.top_radius = dims.r
			m.bottom_radius = dims.r
			m.height = dims.h
			_ghost.mesh = m
			_ghost.position = base + Vector3(0, dims.h / 2.0, 0)
		"sphere":
			var m := SphereMesh.new()
			m.radius = dims.r
			m.height = dims.r * 2.0
			_ghost.mesh = m
			_ghost.position = base + Vector3(0, dims.r, 0)
	_ghost.visible = true


## Measure markers: a, b may be null. snap is the point the crosshair would pick.
func show_measure(a: Variant, b: Variant, snap: Variant, size: float) -> void:
	var r := 0.035 * size
	_marker_a.visible = a != null
	_marker_b.visible = b != null
	_marker_snap.visible = snap != null
	if a != null:
		_marker_a.position = a
		_marker_a.scale = Vector3.ONE * r
	if b != null:
		_marker_b.position = b
		_marker_b.scale = Vector3.ONE * r
	if snap != null:
		_marker_snap.position = snap
		_marker_snap.scale = Vector3.ONE * r * 0.7
	var im: ImmediateMesh = _measure_line.mesh
	im.clear_surfaces()
	var end: Variant = b if b != null else snap
	if a != null and end != null:
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		im.surface_add_vertex(a)
		im.surface_add_vertex(end)
		im.surface_end()
		_measure_line.visible = true
	else:
		_measure_line.visible = false
