extends Node3D
## The world around the model: a bright, clean white room with a skylight. The room grows with the
## player and fades into white haze, so it never feels walled in at any size.
##
## Free build and challenges put a wooden table in the middle ("Old Wooden Table" by carlcapu9,
## Sketchfab, CC BY 4.0), 4 ft by 2 ft and 75 cm high, whose top is the CAD ground (z = 0, Godot
## y = 0). Without the table (training, new parts, assemblies) the room floor is the CAD ground.
##
## The table and the floor are solid: cast() lets the player stand on them and bump into the
## table's edge and legs, and gives the tools something to aim at. The walls and ceiling only
## look solid; they always stay well beyond the player.

const TABLE_HEIGHT := 0.75     # floor to tabletop, metres
const TABLE_TOP := Vector2(1.22, 0.61)  # 4 ft long by 2 ft deep
const WHITE := Color(0.95, 0.955, 0.965)
const TABLE_MODEL := "res://models/old_wooden_table.glb"  # textures reduced for phones
## Where the model's legs are, as fractions of its length (x) and depth (z), and how far below its
## top the top board and apron reach, as a fraction of its height; measured from the mesh.
const MODEL_LEGS_X := [Vector2(0.0238, 0.0632), Vector2(0.9387, 0.9781)]
const MODEL_LEGS_Z := [Vector2(0.047, 0.136), Vector2(0.850, 0.939)]
const MODEL_EDGE_DEPTH := 0.176

var top := Rect2(-TABLE_TOP / 2.0, TABLE_TOP)  # tabletop in Godot x / z
var has_table := false
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
	set_table(false)


## Puts the table in the room (free build, challenges) or takes it away (the room floor is
## then the CAD ground).
func set_table(on: bool) -> void:
	for c in _table.get_children():
		c.queue_free()
	_boxes = []
	has_table = on and ResourceLoader.exists(TABLE_MODEL) and _build_model_table()
	_boxes.append(AABB(Vector3(-1e7, floor_y() - 10.0, -1e7), Vector3(2e7, 10.0, 2e7)))  # the floor


## The wooden table model, fitted to the tabletop rectangle with its top at y = 0.
func _build_model_table() -> bool:
	var scene: PackedScene = load(TABLE_MODEL)
	if scene == null:
		return false
	top = Rect2(-TABLE_TOP / 2.0, TABLE_TOP)
	var holder := Node3D.new()
	_table.add_child(holder)
	var inst := scene.instantiate()
	holder.add_child(inst)
	var box := _meshes_aabb(inst)
	if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
		holder.queue_free()
		return false
	var k := Vector3(top.size.x / box.size.x, TABLE_HEIGHT / box.size.y, top.size.y / box.size.z)
	holder.scale = k
	holder.position = Vector3(top.get_center().x - box.get_center().x * k.x, -box.end.y * k.y,
		top.get_center().y - box.get_center().z * k.z)
	# Collision: the top board and apron as one block, and the four legs.
	var depth := MODEL_EDGE_DEPTH * TABLE_HEIGHT
	_boxes = [AABB(Vector3(top.position.x, -depth, top.position.y), Vector3(top.size.x, depth, top.size.y))]
	for lx in MODEL_LEGS_X:
		for lz in MODEL_LEGS_Z:
			var x0: float = top.position.x + lx.x * top.size.x
			var z0: float = top.position.y + lz.x * top.size.y
			_boxes.append(AABB(Vector3(x0, -TABLE_HEIGHT, z0),
				Vector3((lx.y - lx.x) * top.size.x, TABLE_HEIGHT - depth, (lz.y - lz.x) * top.size.y)))
	return true


## Bounds of every mesh under node, in node's parent's space (node's own transform included).
func _meshes_aabb(node: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [[node, (node as Node3D).transform if node is Node3D else Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var t: Transform3D = item[1]
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var b: AABB = t * (n as MeshInstance3D).mesh.get_aabb()
			out = b if first else out.merge(b)
			first = false
		for c in n.get_children():
			var ct: Transform3D = t * ((c as Node3D).transform if c is Node3D else Transform3D.IDENTITY)
			stack.append([c, ct])
	return out


## Every frame: the room keeps its walls far beyond the player, the haze and the shadow range
## follow their size.
func follow(camera_pos: Vector3, size: float) -> void:
	_room_half = maxf(40.0, 40.0 * size)
	_room_height = maxf(12.0, 9.0 * size)
	var c := Vector3.ZERO
	var fy := floor_y()
	var ceil_y := fy + _room_height
	_floor.position = Vector3(c.x, fy, c.z)
	_floor.scale = Vector3(_room_half, 1, _room_half)
	_ceiling.position = Vector3(c.x, ceil_y, c.z)
	_ceiling.scale = Vector3(_room_half, 1, _room_half)
	_skylight.position = Vector3(c.x, ceil_y - 0.01 * _room_height, c.z)
	_skylight.scale = Vector3(_room_half * 0.32, 1, _room_half * 0.2)
	var mid := fy + _room_height / 2.0
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


## Height of the room floor: below the table, or the CAD ground itself when there is no table.
func floor_y() -> float:
	return -TABLE_HEIGHT if has_table else 0.0


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
