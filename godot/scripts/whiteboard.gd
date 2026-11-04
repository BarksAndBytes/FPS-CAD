extends Node3D
## A whiteboard in the room that carries the game's messages, so the screen stays clear: the
## training objective or challenge card, the sketch or challenge status, the latest notices and
## the size / snap / position readout. It stands at 1:1 ("Whiteboards +" by Michael V, Sketchfab,
## CC BY 4.0): beside the table in free build and challenges, otherwise set down ahead of the
## player (main.gd and the training course decide where).
##
## The writing is a 2D layout drawn into a SubViewport and shown on a quad over the board's panel.
## When the board cannot be read (out of view, or too far away), hud.gd shows notices and the
## sketch status on screen as before.
##
## The same board also serves the boards the player adds (boards.gd): kind "properties" shows the
## part's volume, area, mass and size; kind "notes" shows the player's own notes. Every board
## stands on the floor at its feet, turned by yaw and scaled evenly by board_scale.

const UiTheme := preload("res://scripts/ui_theme.gd")
const MODEL := "res://models/whiteboard.glb"
## The panel's writing area in the model (metres): centre, the way right and up along it, size.
const PANEL_CENTRE := Vector3(0.022, 1.5085, 0.008)
const PANEL_RIGHT := Vector3(1, 0, 0)
const PANEL_UP := Vector3(0, 0.9853, -0.1694)
const PANEL_SIZE := Vector2(1.18, 0.72)
const TEX := Vector2i(1180, 720)  # pixels for the writing: 1 px per mm
## The solid part of the board, for walking into it (model space).
const BODY := AABB(Vector3(-0.71, 0.0, -0.1), Vector3(1.46, 1.9, 0.2))
const INK := Color("0f1a36")     # dark blue marker
const INK_SOFT := Color("2c3a5c")
const RED := Color("c0392b")
const GREEN := Color("23855a")
const NOTICES := 3
const NOTICE_LIFE := 12.0  # seconds a notice stays on the board

var active := false
var kind := "messages"     # "messages", "properties" or "notes"
var board_id := ""
var yaw := 0.0
var board_scale := 1.0
var notes: Array = []      # kind "notes": the player's notes, one per line
var _notes_box := VBoxContainer.new()
var _note_labels: Array[Label] = []
var _model: Node3D
var _view := SubViewport.new()
var _quad := MeshInstance3D.new()
var _kicker: Label
var _heading: Label
var _body: Label
var _status: Label
var _notices: Array[Label] = []
var _readout: Label
var _bar := ColorRect.new()
var _bar_back := ColorRect.new()
var _list: Array = []        # [{text, t}] newest first
var _dirty := true
var _redraw_t := 0.0
var _readable := false
var _glide_from := Transform3D.IDENTITY
var _glide_to := Transform3D.IDENTITY
var _glide_t := 1.0


func _ready() -> void:
	if ResourceLoader.exists(MODEL):
		var scene: PackedScene = load(MODEL)
		if scene != null:
			_model = scene.instantiate()
			add_child(_model)
	_build_writing()
	visible = false


# ---------- what it says ----------

## The card at the top: a small line (step count, timer), a heading and the text under it.
## progress: 0..1 draws a bar, < 0 hides it.
func set_card(kicker: String, heading: String, body: String, heading_color := INK, progress := -1.0) -> void:
	if kicker == _kicker.text and heading == _heading.text and body == _body.text and progress == _bar.get_meta("p", -2.0) \
			and heading_color == _heading.get_theme_color("font_color"):
		return
	_kicker.text = kicker
	_heading.text = heading
	_heading.add_theme_color_override("font_color", heading_color)
	_body.text = body
	_bar_back.visible = progress >= 0.0
	_bar.set_meta("p", progress)
	_bar.size.x = (TEX.x - 96) * clampf(progress, 0.0, 1.0)
	_dirty = true


func clear_card() -> void:
	set_card("", "", "")


## One line under the card: the sketch's state, a challenge's last comparison.
func set_status(text: String, color := INK_SOFT) -> void:
	if text == _status.text and color == _status.get_theme_color("font_color"):
		return
	_status.text = text
	_status.add_theme_color_override("font_color", color)
	_dirty = true


## A notice (what hud.toast shows): newest at the top, older ones fade and go.
func post(text: String) -> void:
	if text == "":
		return
	if not _list.is_empty() and _list[0].text == text:
		_list[0].t = 0.0
	else:
		_list.push_front({text = text, t = 0.0})
		if _list.size() > NOTICES:
			_list.resize(NOTICES)
	_dirty = true


func set_readout(text: String) -> void:
	if text != _readout.text:
		_readout.text = text
		_dirty = true


## Whether the player can read the board right now: in view, facing them, big enough on screen.
func readable() -> bool:
	return active and visible and _readable


# ---------- where it stands ----------

## Stands the board on the floor at feet, its writing facing toward look_at (both Godot space).
## glide: move there over half a second instead of at once.
func place(feet: Vector3, look_at: Vector3, glide := false) -> void:
	set_pose(feet, facing(feet, look_at), board_scale, glide)


## The yaw that turns a board standing at feet to face toward look_at.
static func facing(feet: Vector3, look_at: Vector3) -> float:
	var d := look_at - feet
	d.y = 0.0
	return atan2(d.x, d.z) if d.length() > 1e-6 else 0.0


## Stands the board on the floor at feet (Godot space), turned by yaw_angle and scaled evenly by
## s about its feet, so it stays standing on the floor at any size.
func set_pose(feet: Vector3, yaw_angle: float, s: float, glide := false) -> void:
	yaw = yaw_angle
	board_scale = s
	var to := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s), feet)
	if glide and visible:
		_glide_from = transform
		_glide_to = to
		_glide_t = 0.0
	else:
		transform = to
		_glide_t = 1.0
	active = true
	visible = true


func hide_board() -> void:
	active = false
	visible = false


## A ray against the board's body, like room.cast: {hit, point, normal, distance, env} or {}.
func cast(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	if not active:
		return {}
	var inv := global_transform.affine_inverse()
	var o: Vector3 = inv * origin
	var dv: Vector3 = inv.basis * dir
	if BODY.has_point(o):
		return {}
	var inv_d := Vector3(1.0 / dv.x if dv.x != 0.0 else INF, 1.0 / dv.y if dv.y != 0.0 else INF, 1.0 / dv.z if dv.z != 0.0 else INF)
	var t1 := (BODY.position - o) * inv_d
	var t2 := (BODY.end - o) * inv_d
	var tmin := Vector3(minf(t1.x, t2.x), minf(t1.y, t2.y), minf(t1.z, t2.z))
	var tmax := Vector3(maxf(t1.x, t2.x), maxf(t1.y, t2.y), maxf(t1.z, t2.z))
	var t_in := maxf(tmin.x, maxf(tmin.y, tmin.z))
	var t_out := minf(tmax.x, minf(tmax.y, tmax.z))
	if t_in > t_out or t_in < 0.0 or t_in > max_distance:
		return {}
	var n := Vector3.ZERO
	if t_in == tmin.x:
		n = Vector3(-signf(dv.x), 0, 0)
	elif t_in == tmin.y:
		n = Vector3(0, -signf(dv.y), 0)
	else:
		n = Vector3(0, 0, -signf(dv.z))
	return {hit = true, env = true, point = origin + dir * t_in, normal = (global_transform.basis * n).normalized(),
		distance = t_in, feature_id = "", board = self}


func feet() -> Vector3:
	return _glide_to.origin if _glide_t < 1.0 else transform.origin


## The board as saved in the part file (views/boards.json).
func to_dict() -> Dictionary:
	var p := feet()
	var d := {id = board_id, kind = kind, position = [p.x, p.y, p.z], yaw = yaw, scale = board_scale}
	if kind == "notes":
		d.notes = notes.duplicate()
	return d


# ---------- notes ----------

func set_notes(lines: Array) -> void:
	notes = lines.duplicate()
	while _note_labels.size() < notes.size():
		var l := _ink(54, INK)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = TEX.x - 96
		_notes_box.add_child(l)
		_note_labels.append(l)
	for i in _note_labels.size():
		_note_labels[i].visible = i < notes.size()
		if i < notes.size():
			_note_labels[i].text = "•  " + String(notes[i])
	_dirty = true


## Which note is written at a point on the board (Godot space), or -1.
func note_at(point: Vector3) -> int:
	var px := writing_pixel(point)
	if px.x < 0.0:
		return -1
	for i in notes.size():
		var r := _note_labels[i].get_global_rect().grow(6.0)
		if px.y >= r.position.y and px.y <= r.end.y:
			return i
	return -1


## Where a point (Godot space) falls on the writing, in texture pixels; (-1, -1) off the panel.
func writing_pixel(point: Vector3) -> Vector2:
	var local: Vector3 = global_transform.affine_inverse() * point - PANEL_CENTRE
	var u := local.dot(PANEL_RIGHT) / PANEL_SIZE.x + 0.5
	var v := 0.5 - local.dot(PANEL_UP.normalized()) / PANEL_SIZE.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return Vector2(-1, -1)
	return Vector2(u * TEX.x, v * TEX.y)


# ---------- every frame ----------

func _process(dt: float) -> void:
	if not active:
		return
	if _glide_t < 1.0:
		_glide_t = minf(1.0, _glide_t + dt / 0.5)
		transform = _glide_from.interpolate_with(_glide_to, ease(_glide_t, -2.0))
	# Notices age and fade; the board redraws at most ten times a second.
	var fading := false
	for i in range(_list.size() - 1, -1, -1):
		_list[i].t += dt
		if _list[i].t > NOTICE_LIFE:
			_list.remove_at(i)
			_dirty = true
		elif _list[i].t > NOTICE_LIFE - 2.0:
			fading = true
	_redraw_t -= dt
	if (_dirty or fading) and _redraw_t <= 0.0:
		_redraw_t = 0.1
		_dirty = false
		_lay_out()
		_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	_readable = _visible_to_camera()


func _visible_to_camera() -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	var c: Vector3 = global_transform * PANEL_CENTRE
	var n: Vector3 = (global_transform.basis * PANEL_RIGHT.cross(PANEL_UP)).normalized()
	if (cam.global_position - c).dot(n) <= 0.0:
		return false  # seen from behind
	var top: Vector3 = global_transform * (PANEL_CENTRE + PANEL_UP * PANEL_SIZE.y / 2.0)
	var bottom: Vector3 = global_transform * (PANEL_CENTRE - PANEL_UP * PANEL_SIZE.y / 2.0)
	if cam.is_position_behind(top) or cam.is_position_behind(bottom):
		return false
	var a := cam.unproject_position(top)
	var b := cam.unproject_position(bottom)
	var screen := get_viewport().get_visible_rect().size
	var mid := (a + b) / 2.0
	if mid.x < 0.0 or mid.y < 0.0 or mid.x > screen.x or mid.y > screen.y:
		return false
	return a.distance_to(b) > screen.y * 0.22  # the writing is big enough to read


# ---------- drawing ----------

func _build_writing() -> void:
	_view.size = TEX
	_view.transparent_bg = true
	_view.disable_3d = true
	_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_view)
	var margin := MarginContainer.new()
	margin.size = Vector2(TEX)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	margin.add_theme_constant_override("margin_top", 36)
	margin.add_theme_constant_override("margin_bottom", 30)
	_view.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)
	_kicker = _ink(30, RED, true)
	_heading = _ink(60, INK, true)
	_body = _ink(38 if kind == "messages" else 50, INK)  # the player's boards have room to spare
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size.x = TEX.x - 96
	for l in [_kicker, _heading, _body]:
		col.add_child(l)
	var bar_holder := Control.new()
	bar_holder.custom_minimum_size = Vector2(0, 8)
	col.add_child(bar_holder)
	_bar_back.color = Color(INK, 0.15)
	_bar_back.size = Vector2(TEX.x - 96, 8)
	_bar_back.visible = false
	bar_holder.add_child(_bar_back)
	_bar.color = GREEN
	_bar.size = Vector2(0, 8)
	_bar_back.add_child(_bar)
	_status = _ink(36, INK_SOFT, true)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = TEX.x - 96
	col.add_child(_status)
	_notes_box.add_theme_constant_override("separation", 10)
	col.add_child(_notes_box)
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(gap)
	for i in NOTICES:
		var l := _ink(38 if i == 0 else 30, INK)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = TEX.x - 96
		col.add_child(l)
		_notices.append(l)
	_readout = _ink(26, INK_SOFT)
	col.add_child(_readout)

	var quad := QuadMesh.new()
	quad.size = PANEL_SIZE
	_quad.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _view.get_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # ink stays dark whatever the light
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_quad.material_override = mat
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var normal := PANEL_RIGHT.cross(PANEL_UP).normalized()
	_quad.transform = Transform3D(Basis(PANEL_RIGHT, PANEL_UP, normal), PANEL_CENTRE + normal * 0.004)
	add_child(_quad)


func _ink(size: int, color: Color, display := false) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	var f: Font = UiTheme.display_font if display else UiTheme.body_font
	if f != null:
		l.add_theme_font_override("font", f)
	return l


func _lay_out() -> void:
	for i in NOTICES:
		var l := _notices[i]
		if i < _list.size():
			var age: float = _list[i].t
			l.text = ("✎ " if i == 0 and age < 4.0 else "") + String(_list[i].text)
			l.modulate.a = clampf((NOTICE_LIFE - age) / 2.0, 0.0, 1.0) * (1.0 if i == 0 else 0.7)
			l.visible = true
		else:
			l.visible = false
	_kicker.visible = _kicker.text != ""
	_heading.visible = _heading.text != ""
	_body.visible = _body.text != ""
	_status.visible = _status.text != ""


## The writing as it would be read, for tests.
func text_lines() -> Array:
	var out := [_kicker.text, _heading.text, _body.text, _status.text]
	for e in _list:
		out.append(e.text)
	out.append(_readout.text)
	return out
