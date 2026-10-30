extends Node3D
## The world around the model: a bright, clean white room with a skylight, and a wooden table at
## its centre whose top is the CAD ground (z = 0, Godot y = 0). The room grows with the player and
## fades into white haze, so it never feels walled in at any size; the table is sized to the model.
##
## The table and the floor are solid: cast() lets the player stand on them and bump into the
## table's edge and legs, and gives the tools something to aim at. The walls and ceiling only
## look solid; they always stay well beyond the player.

const TABLE_HEIGHT := 0.75     # floor to tabletop, metres
const TOP_THICKNESS := 0.045
const LEG := 0.075
const APRON := 0.22            # skirt boards under the top; also the depth of the table's edge
const MIN_TOP := Vector2(1.6, 0.9)
const WHITE := Color(0.95, 0.955, 0.965)

var top := Rect2(-0.8, -0.45, 1.6, 0.9)  # tabletop in Godot x / z
var _boxes: Array[AABB] = []             # solid parts: tabletop, legs, floor slab
var _table := Node3D.new()
var _floor := MeshInstance3D.new()
var _ceiling := MeshInstance3D.new()
var _skylight := MeshInstance3D.new()
var _walls: Array[MeshInstance3D] = []
var _sun := DirectionalLight3D.new()
var _env := Environment.new()
var _room_half := 40.0
var _room_height := 12.0


func _ready() -> void:
	var white := StandardMaterial3D.new()
	white.albedo_color = WHITE
	white.roughness = 0.92
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.93, 0.935, 0.945)
	floor_mat.roughness = 0.35
	floor_mat.metallic_specular = 0.6
	for m in [_floor, _ceiling]:
		var plane := PlaneMesh.new()
		plane.size = Vector2(2, 2)
		m.mesh = plane
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(m)
	_floor.material_override = floor_mat
	_ceiling.material_override = white
	_ceiling.rotation = Vector3(PI, 0, 0)  # face down
	for i in 4:
		var w := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(2, 2)
		w.mesh = q
		w.material_override = white
		w.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(w)
		_walls.append(w)
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(1, 1, 1)
	glow.emission_enabled = true
	glow.emission = Color(1, 1, 1)
	glow.emission_energy_multiplier = 2.0
	var sky := PlaneMesh.new()
	sky.size = Vector2(2, 2)
	_skylight.mesh = sky
	_skylight.material_override = glow
	_skylight.rotation = Vector3(PI, 0, 0)
	_skylight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_skylight)
	add_child(_table)

	# Soft daylight from the skylight, with shadows so parts sit on the table; a cool fill from
	# the side; bright white ambient like light bouncing off white walls.
	_sun.rotation = Vector3(deg_to_rad(-68), deg_to_rad(28), 0)
	_sun.light_energy = 0.75
	_sun.light_color = Color("fffaf2")
	_sun.shadow_enabled = true
	_sun.shadow_blur = 2.0
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	add_child(_sun)
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-25), deg_to_rad(215), 0)
	fill.light_energy = 0.22
	fill.light_color = Color("e4ecff")
	add_child(fill)

	_env.background_mode = Environment.BG_COLOR
	_env.background_color = WHITE
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.86, 0.88, 0.92)
	_env.ambient_light_energy = 0.62
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.tonemap_white = 5.0
	_env.fog_enabled = true
	_env.fog_light_color = WHITE
	_env.fog_density = 0.004
	_env.fog_sky_affect = 0.0
	_env.glow_enabled = true
	_env.glow_intensity = 0.35
	_env.glow_hdr_threshold = 1.4
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)
	fit_table(AABB(), [])


## Sizes the table to the model's footprint (Godot-space bounds) plus any points that must be on
## it (where the player starts), with room to spare.
func fit_table(bounds: AABB, keep: Array) -> void:
	var r := Rect2(-MIN_TOP / 2.0, MIN_TOP)
	if bounds.size != Vector3.ZERO:
		var foot := Rect2(bounds.position.x, bounds.position.z, bounds.size.x, bounds.size.z)
		var margin := maxf(0.15, 0.25 * maxf(foot.size.x, foot.size.y))
		r = r.merge(foot.grow(margin))
	for p in keep:
		if p is Vector3 and absf(p.y) < 0.1:  # standing on the table, not flying above it
			r = r.merge(Rect2(Vector2(p.x, p.z) - Vector2.ONE * 0.6, Vector2.ONE * 1.2))
	top = r
	_build_table()


func _build_table() -> void:
	for c in _table.get_children():
		c.queue_free()
	var wood := ShaderMaterial.new()
	wood.shader = load("res://scripts/wood.gdshader")
	var slab := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(top.size.x, TOP_THICKNESS, top.size.y)
	slab.mesh = box
	slab.material_override = wood
	slab.position = Vector3(top.get_center().x, -TOP_THICKNESS / 2.0, top.get_center().y)
	_table.add_child(slab)
	# Solid from the top down to the apron's lower edge, so the table's edge stops a walking body.
	var depth := TOP_THICKNESS + APRON
	_boxes = [AABB(Vector3(top.position.x, -depth, top.position.y), Vector3(top.size.x, depth, top.size.y))]
	var legs := ShaderMaterial.new()
	legs.shader = wood.shader
	legs.set_shader_parameter("light_wood", Color(0.62, 0.44, 0.28))
	legs.set_shader_parameter("dark_wood", Color(0.42, 0.27, 0.16))
	var leg_h := TABLE_HEIGHT - TOP_THICKNESS
	var inset := minf(0.12, 0.08 * minf(top.size.x, top.size.y)) + LEG / 2.0
	# The apron: boards just inside the legs' outer faces, along all four sides.
	var a0 := Vector2(top.position.x + inset - LEG / 2.0, top.position.y + inset - LEG / 2.0)
	var a1 := Vector2(top.end.x - inset + LEG / 2.0, top.end.y - inset + LEG / 2.0)
	var board := 0.022
	for spec in [[Vector3((a0.x + a1.x) / 2.0, 0, a0.y + board / 2.0), Vector3(a1.x - a0.x, APRON, board)],
			[Vector3((a0.x + a1.x) / 2.0, 0, a1.y - board / 2.0), Vector3(a1.x - a0.x, APRON, board)],
			[Vector3(a0.x + board / 2.0, 0, (a0.y + a1.y) / 2.0), Vector3(board, APRON, a1.y - a0.y)],
			[Vector3(a1.x - board / 2.0, 0, (a0.y + a1.y) / 2.0), Vector3(board, APRON, a1.y - a0.y)]]:
		var apron := MeshInstance3D.new()
		var ab := BoxMesh.new()
		ab.size = spec[1]
		apron.mesh = ab
		apron.material_override = legs
		apron.position = spec[0] + Vector3(0, -TOP_THICKNESS - APRON / 2.0, 0)
		_table.add_child(apron)
	# Big tables get legs along their edges too, every few metres.
	var nx := maxi(2, int(ceil(top.size.x / 3.0)) + 1)
	var nz := maxi(2, int(ceil(top.size.y / 3.0)) + 1)
	for ix in nx:
		for iz in nz:
			if ix != 0 and ix != nx - 1 and iz != 0 and iz != nz - 1:
				continue
			var x := lerpf(top.position.x + inset, top.end.x - inset, float(ix) / (nx - 1))
			var z := lerpf(top.position.y + inset, top.end.y - inset, float(iz) / (nz - 1))
			var leg := MeshInstance3D.new()
			var lb := BoxMesh.new()
			lb.size = Vector3(LEG, leg_h, LEG)
			leg.mesh = lb
			leg.material_override = legs
			leg.position = Vector3(x, -TOP_THICKNESS - leg_h / 2.0, z)
			_table.add_child(leg)
			_boxes.append(AABB(Vector3(x - LEG / 2.0, -TABLE_HEIGHT, z - LEG / 2.0), Vector3(LEG, leg_h, LEG)))
	# The floor, as a thick slab so nothing falls through it.
	_boxes.append(AABB(Vector3(-1e7, -TABLE_HEIGHT - 10.0, -1e7), Vector3(2e7, 10.0, 2e7)))


## Every frame: the room keeps its walls far beyond the player, the haze and the shadow range
## follow their size.
func follow(camera_pos: Vector3, size: float) -> void:
	var table_half := maxf(top.size.x, top.size.y) / 2.0
	_room_half = maxf(maxf(40.0, table_half * 4.0), 40.0 * size)
	_room_height = maxf(12.0, 9.0 * size)
	var c := Vector3(top.get_center().x, 0, top.get_center().y)
	var floor_y := -TABLE_HEIGHT
	var ceil_y := floor_y + _room_height
	_floor.position = Vector3(c.x, floor_y, c.z)
	_floor.scale = Vector3(_room_half, 1, _room_half)
	_ceiling.position = Vector3(c.x, ceil_y, c.z)
	_ceiling.scale = Vector3(_room_half, 1, _room_half)
	_skylight.position = Vector3(c.x, ceil_y - 0.01 * _room_height, c.z)
	_skylight.scale = Vector3(_room_half * 0.32, 1, _room_half * 0.2)
	var mid := floor_y + _room_height / 2.0
	var spots := [[Vector3(0, 0, -1), 0.0], [Vector3(0, 0, 1), PI], [Vector3(-1, 0, 0), PI / 2.0], [Vector3(1, 0, 0), -PI / 2.0]]
	for i in 4:
		var w := _walls[i]
		w.position = c + spots[i][0] * _room_half + Vector3(0, mid, 0)
		w.rotation = Vector3(0, spots[i][1], 0)
		w.scale = Vector3(_room_half, _room_height / 2.0, 1)
	# The far walls melt into the haze, so the room reads as almost boundless.
	_env.fog_density = 1.4 / _room_half
	_sun.directional_shadow_max_distance = clampf(30.0 * size, 3.0, 400.0)
	_sun.shadow_bias = 0.02 * size
	_sun.shadow_normal_bias = 1.0


## Height of the room floor.
func floor_y() -> float:
	return -TABLE_HEIGHT


## A ray against the table and the floor. Faces seen from inside a box do not count, like model
## faces, so a player inside the tabletop can still walk out. Returns the same fields as a model
## pick, plus env = true.
func cast(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var best := {}
	var best_t := max_distance
	var inv := Vector3(1.0 / dir.x if dir.x != 0.0 else INF, 1.0 / dir.y if dir.y != 0.0 else INF,
		1.0 / dir.z if dir.z != 0.0 else INF)
	for b in _boxes:
		if b.has_point(origin):
			continue
		var t1 := (b.position - origin) * inv
		var t2 := (b.end - origin) * inv
		var tmin := Vector3(minf(t1.x, t2.x), minf(t1.y, t2.y), minf(t1.z, t2.z))
		var tmax := Vector3(maxf(t1.x, t2.x), maxf(t1.y, t2.y), maxf(t1.z, t2.z))
		var t_enter := maxf(tmin.x, maxf(tmin.y, tmin.z))
		var t_exit := minf(tmax.x, minf(tmax.y, tmax.z))
		if t_enter > t_exit or t_enter < 0.0 or t_enter >= best_t:
			continue
		var n := Vector3.ZERO
		if t_enter == tmin.x:
			n = Vector3(-signf(dir.x), 0, 0)
		elif t_enter == tmin.y:
			n = Vector3(0, -signf(dir.y), 0)
		else:
			n = Vector3(0, 0, -signf(dir.z))
		best_t = t_enter
		best = {hit = true, env = true, point = origin + dir * t_enter, normal = n, distance = t_enter, feature_id = ""}
	return best
