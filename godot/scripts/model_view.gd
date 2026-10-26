extends Node3D
## Draws the model: shaded bodies, feature edges, the ground grid, highlights, placement ghosts
## and measure markers. Re-tessellates when the player's size changes enough that the mesh would
## look faceted (growing smaller) or wastefully dense (growing larger).

const COLOR_PART := Color("d8d2c6")
const COLOR_EDGE := Color("1c222a")
const COLOR_ACCENT := Color("ff8a3d")
const COLOR_MEASURE := Color("ffd166")
const SKY := Color("3a4553")

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
var _ground := MeshInstance3D.new()
var _grid_mat := ShaderMaterial.new()
var _marker_a := MeshInstance3D.new()
var _marker_b := MeshInstance3D.new()
var _marker_snap := MeshInstance3D.new()
var _measure_line := MeshInstance3D.new()
var _env := Environment.new()
var _hl_key := ""


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

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-55), deg_to_rad(30), 0)
	light.light_energy = 0.9
	light.light_color = Color("fff0dc")
	add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-20), deg_to_rad(210), 0)
	fill.light_energy = 0.25
	fill.light_color = Color("bfd2ff")
	add_child(fill)

	_env.background_mode = Environment.BG_COLOR
	_env.background_color = SKY
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color("8a96a8")
	_env.ambient_light_energy = 0.9
	_env.fog_enabled = true
	_env.fog_light_color = SKY
	_env.fog_density = 0.012
	_env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

	_grid_mat.shader = load("res://scripts/grid.gdshader")
	var plane := PlaneMesh.new()
	plane.size = Vector2(40000, 40000)
	_ground.mesh = plane
	_ground.material_override = _grid_mat
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ground)

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


## Called every frame with the camera so the grid, fog and tessellation follow the player.
func follow(camera_pos: Vector3, size: float) -> void:
	_ground.position = Vector3(camera_pos.x, 0, camera_pos.z)
	var grid := pow(10.0, round(log(size) / log(10.0)))
	var fog := 0.012 / maxf(size, 0.12)
	_grid_mat.set_shader_parameter("minor", grid)
	_grid_mat.set_shader_parameter("fog_density", fog)
	_env.fog_density = fog * 0.6
	if _mesh_size < 0.0 or size / _mesh_size > 4.0 or _mesh_size / size > 4.0:
		refresh(size)


## Rebuilds every display mesh from the document at a deflection suited to the player's size.
func refresh(size: float = -1.0) -> void:
	if size > 0.0:
		_mesh_size = size
	var defl := clampf(0.0015 * _mesh_size, 2e-7, 0.5)
	for n in _bodies + _edges + _components:
		n.queue_free()
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
		var take := f == face if face >= 0 else (f < face_features.size() and face_features[f] == feature_id)
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
