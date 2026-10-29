extends Node3D
## Challenge mode: copy the target part. The target floats beside the build area as a hologram
## with its dimensions labelled; the player builds their copy in a blank part with the normal
## tools. After every change the core compares the two (CadPart.compare_to): the copy passes when
## it is the same solid, whatever its position, orientation or the steps that made it.
##
## Challenges come from the core (fpcad/Challenges.h), easiest first; finishing one unlocks the
## next. Progress and best times are kept in user://settings.cfg.

signal finished(choice: String)  # "next", "retry", "list", "title"

const UiTheme := preload("res://scripts/ui_theme.gd")
const SETTINGS := "user://settings.cfg"
const HOLO := Color(0.35, 0.78, 1.0)

var game: Node  # main.gd
var index := 0
var info := {}
var target: RefCounted  # CadPart holding the target
var offset := Vector3.ZERO  # where the target is shown, Godot space
var solved := false
var last := {}  # the latest comparison
var _t := 0.0
var _aabb := AABB()  # the target's bounds, before the offset

var _holo := Node3D.new()
var _layer := CanvasLayer.new()
var _card := PanelContainer.new()
var _count: Label
var _heading: Label
var _brief: Label
var _hint: Label
var _status: Label
var _end := PanelContainer.new()
var _end_title: Label
var _end_text: Label
var _next: Button


func _ready() -> void:
	add_child(_holo)
	_build_ui()


# ---------- progress ----------

static func unlocked() -> int:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	return int(cfg.get_value("challenges", "unlocked", 1))


static func best_time(id: String) -> float:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	return float(cfg.get_value("challenges", "best_" + id, -1.0))


static func time_text(seconds: float) -> String:
	var s := int(round(seconds))
	return "%d:%02d" % [s / 60, s % 60]


func _record(seconds: float) -> bool:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("challenges", "unlocked", maxi(int(cfg.get_value("challenges", "unlocked", 1)), index + 2))
	var key := "best_" + String(info.id)
	var prev := float(cfg.get_value("challenges", key, -1.0))
	var better := prev < 0.0 or seconds < prev
	if better:
		cfg.set_value("challenges", key, seconds)
	cfg.save(SETTINGS)
	return better


# ---------- the level ----------

## Loads challenge i: the target hologram, and where the player should stand.
func start(i: int) -> void:
	index = i
	target = ClassDB.instantiate(&"CadPart")
	info = target.make_challenge(i)
	target.rebuild()
	solved = false
	last = {}
	_t = 0.0
	_build_hologram()
	_count.text = "CHALLENGE  %d / %d" % [i + 1, int(info.count)]
	_heading.text = info.name
	_brief.text = info.brief
	_hint.text = "Hint: " + String(info.hint)
	_status.text = "Build your copy beside the hologram. Position and orientation don't matter."
	_status.add_theme_color_override("font_color", UiTheme.MUTED)
	_card.visible = true
	_end.visible = false


## A good player size and spawn for this target: the part about knee-to-waist height.
func spawn() -> Dictionary:
	var aabb := _target_aabb()
	var big := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var size := clampf(big / (0.45 * 1.75), 0.02, 2.0)
	return {feet = Vector3(offset.x / 2.0, 0.0, big * 2.2), yaw = 0.0, size = size}


func _target_aabb() -> AABB:
	return _aabb


func _build_hologram() -> void:
	for c in _holo.get_children():
		c.queue_free()
	var mesh: ArrayMesh = target.build_mesh(0, 0.0002)
	var aabb := mesh.get_aabb()
	_aabb = aabb
	var big := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	# To the left of the build area at the origin, with a clear gap.
	offset = Vector3(-(aabb.end.x) - big * 0.9 - 0.02, 0, -aabb.get_center().z)
	_holo.position = offset
	var body := MeshInstance3D.new()
	body.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(HOLO, 0.28)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = HOLO * 0.25
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	body.material_override = mat
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_holo.add_child(body)
	var edges := MeshInstance3D.new()
	var pts: PackedVector3Array = target.build_edges(0, 0.0002)
	if pts.size() >= 2:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pts
		var em := ArrayMesh.new()
		em.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		edges.mesh = em
	var emat := StandardMaterial3D.new()
	emat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	emat.albedo_color = HOLO
	edges.material_override = emat
	_holo.add_child(edges)
	_build_callouts(big)
	var tag := Label3D.new()
	tag.text = "TARGET"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.fixed_size = true
	tag.pixel_size = 0.0009 * UiTheme.ui_scale
	tag.font_size = 34
	tag.outline_size = 10
	tag.modulate = HOLO
	tag.position = Vector3(aabb.get_center().x, aabb.end.y + big * 0.25, aabb.get_center().z)
	_holo.add_child(tag)


func _build_callouts(big: float) -> void:
	var im := ImmediateMesh.new()
	var lines := MeshInstance3D.new()
	lines.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color("ffd166")
	mat.no_depth_test = true
	mat.render_priority = 10
	lines.material_override = mat
	_holo.add_child(lines)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var tick := big * 0.03
	for c in info.callouts:
		var a: Vector3 = c.a
		var b: Vector3 = c.b
		im.surface_add_vertex(a)
		im.surface_add_vertex(b)
		# Small end ticks, square to the line, so the extent reads clearly.
		var dir := (b - a).normalized()
		var side := dir.cross(Vector3.UP)
		if side.length() < 0.1:
			side = dir.cross(Vector3.RIGHT)
		side = side.normalized() * tick
		for p in [a, b]:
			im.surface_add_vertex(p - side)
			im.surface_add_vertex(p + side)
		var l := Label3D.new()
		l.text = c.text
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.fixed_size = true
		l.no_depth_test = true
		l.pixel_size = 0.0008 * UiTheme.ui_scale
		l.font_size = 30
		l.outline_size = 10
		l.modulate = Color("ffd166")
		l.outline_modulate = Color(0, 0, 0, 0.85)
		l.render_priority = 30
		l.outline_render_priority = 29
		l.position = (a + b) / 2.0
		_holo.add_child(l)
	im.surface_end()


# ---------- checking ----------

## Called by main.gd whenever the player's part changes.
func on_model_changed() -> void:
	if solved or target == null or game.doc == null or game.is_assembly:
		return
	if game.dialog.visible or game.sketcher.active:
		return  # judge finished features only, not previews
	last = game.doc.compare_to(target)
	if last.get("match", false):
		_complete()
		return
	var msg: String = last.get("message", "")
	if last.get("empty", false):
		msg = "Build your copy beside the hologram. Position and orientation don't matter."
	_status.text = msg
	_status.add_theme_color_override("font_color", Color("e0a35f") if last.get("mirrored", false) else UiTheme.FG)


func _complete() -> void:
	solved = true
	var better := _record(_t)
	_card.visible = false
	_end.visible = true
	var last_one: bool = index + 1 >= int(info.count)
	_end_title.text = "MATCHED" if not last_one else "ALL CHALLENGES DONE"
	var best := best_time(String(info.id))
	_end_text.text = "%s copied in %s%s." % [info.name, time_text(_t), "  ·  new best" if better else "  ·  best %s" % time_text(best)]
	if last_one:
		_end_text.text += "\nThat was the last one. Free build and New part are open for anything you like."
	_next.visible = not last_one
	Input.start_joy_vibration(0, 0.4, 0.6, 0.25)
	UiTheme.keep_focus(_end, _next if not last_one else null)


func _process(dt: float) -> void:
	if target == null:
		return
	if not solved and not game.modal_open():
		_t += dt
	var blocked: bool = game.hud.menu_open or game.hud.panel_open or game.cmap.visible or game.numpad.visible
	_card.visible = not solved and not blocked
	if _card.visible:
		_count.text = "CHALLENGE  %d / %d   ·   %s" % [index + 1, int(info.count), time_text(_t)]


## A ray against the hologram, for measuring the target. Hits carry no feature, so modelling
## tools ignore them; snap_vertices lets Measure snap to the target's corners.
func pick(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	if target == null:
		return {}
	var hit: Dictionary = target.pick(origin - offset, dir, max_distance)
	if hit.is_empty():
		return {}
	var verts := PackedVector3Array()
	for v in target.face_vertices(hit.body, hit.face):
		verts.append(v + offset)
	return {hit = true, target = true, point = hit.point + offset, normal = hit.normal, distance = hit.distance,
		feature_id = "", feature_name = "Target", snap_vertices = verts}


func is_open_card() -> bool:
	return _end.visible


func keep_focus() -> void:
	if _end.visible:
		UiTheme.keep_focus(_end, _next if _next.visible else null)


# ---------- interface ----------

func _build_ui() -> void:
	_layer.layer = 2
	add_child(_layer)
	var top := CenterContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_top = 16
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(top)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.custom_minimum_size = Vector2(minf(600, maxf(320, get_viewport().get_visible_rect().size.x - 640)), 0)
	top.add_child(_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_card.add_child(col)
	_count = UiTheme.title("", 14, UiTheme.ACCENT)
	_heading = UiTheme.title("", 24)
	_brief = UiTheme.text("", 16)
	_hint = UiTheme.text("", 13, UiTheme.MUTED)
	_status = UiTheme.text("", 15)
	for l in [_brief, _hint, _status]:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for n in [_count, _heading, _brief, _hint, _status]:
		col.add_child(n)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(centre)
	centre.add_child(_end)
	var end_col := VBoxContainer.new()
	end_col.add_theme_constant_override("separation", 12)
	end_col.custom_minimum_size = Vector2(440, 0)
	_end.add_child(end_col)
	_end_title = UiTheme.title("MATCHED", 34, UiTheme.ACCENT)
	end_col.add_child(_end_title)
	_end_text = UiTheme.text("", 17, UiTheme.MUTED)
	_end_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	end_col.add_child(_end_text)
	for spec in [["next", "Next challenge"], ["retry", "Play this one again"], ["list", "Challenge list"], ["title", "Title screen"]]:
		var b := Button.new()
		b.text = spec[1]
		b.custom_minimum_size = Vector2(0, 50)
		var id: String = spec[0]
		b.pressed.connect(_on_end_choice.bind(id))
		end_col.add_child(b)
		if id == "next":
			_next = b
	_end.visible = false
	_card.visible = false


func _on_end_choice(id: String) -> void:
	_end.visible = false
	finished.emit(id)
