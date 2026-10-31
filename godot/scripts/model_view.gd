extends Node3D
## Draws the model: shaded bodies, feature edges, highlights, placement ghosts and measure
## markers, inside the room (room.gd: the white room and the table the model stands on). Re-tessellates when the player's size changes enough that the mesh would
## look faceted (growing smaller) or wastefully dense (growing larger).

const COLOR_PART := Color("b7bfc8")  # a cool grey that reads against the white room and the wood
const COLOR_EDGE := Color("1c222a")
const COLOR_ACCENT := Color("ff8a3d")
const COLOR_MEASURE := Color("ffd166")
const COLOR_SKETCH := Color("5aa9ff")
const COLOR_SKETCH_BAD := Color("e0775f")

## CadPart or CadAssembly (untyped so a missing extension shows an error instead of a parse failure)
var doc: RefCounted
var is_assembly := false

var _body_mat := StandardMaterial3D.new()
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
var _ghost := MeshInstance3D.new()
var room: Node3D  # room.gd
var _marker_a := MeshInstance3D.new()
var _marker_b := MeshInstance3D.new()
var _marker_snap := MeshInstance3D.new()
var _measure_line := MeshInstance3D.new()
var _hl_key := ""
var _sketch_mat := StandardMaterial3D.new()
var _sketch_bad_mat := StandardMaterial3D.new()
var _sketch_hl_mat := StandardMaterial3D.new()
var _plane_mat := StandardMaterial3D.new()
var _sketches := {}  # feature id -> MeshInstance3D (unused sketches only)
var _sketch_ok := {}
var _plane := MeshInstance3D.new()
var _hl_sketch := ""
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
	for pair in [[_sketch_mat, COLOR_SKETCH], [_sketch_bad_mat, COLOR_SKETCH_BAD], [_sketch_hl_mat, COLOR_ACCENT]]:
		var m: StandardMaterial3D = pair[0]
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = pair[1]
		m.no_depth_test = true
		m.render_priority = 8
	_plane_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_plane_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_plane_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_plane_mat.albedo_color = Color(COLOR_SKETCH, 0.16)
	_plane_mat.vertex_color_use_as_albedo = false
	_plane.mesh = ImmediateMesh.new()
	_plane.material_override = _plane_mat
	_plane.visible = false
	add_child(_plane)

	room = preload("res://scripts/room.gd").new()
	add_child(room)

	_highlight.material_override = _hl_mat
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


## Unused sketches show as lines in the world (used ones hide, as in most CAD tools).
func _refresh_sketches() -> void:
	if not doc.has_method("sketch_views"):
		return
	for v in doc.sketch_views():
		if v.consumed or v.id == hidden_sketch:
			continue
		var pts: PackedVector3Array = v.segments
		pts.append_array(v.construction)
		if pts.size() < 2:
			continue
		var mi := _make_edges(pts)
		var good: bool = v.ok and v.regions > 0
		mi.material_override = _sketch_mat if good else _sketch_bad_mat
		_sketches[v.id] = mi
		_sketch_ok[v.id] = good
	if _hl_sketch != "":
		var keep := _hl_sketch
		_hl_sketch = ""
		highlight_sketch(keep)


## Tints one sketch in the accent colour ("" for none).
func highlight_sketch(id: String) -> void:
	if id == _hl_sketch:
		return
	if _sketches.has(_hl_sketch):
		_sketches[_hl_sketch].material_override = _sketch_mat if _sketch_ok.get(_hl_sketch, true) else _sketch_bad_mat
	_hl_sketch = id
	if _sketches.has(id):
		_sketches[id].material_override = _sketch_hl_mat


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
