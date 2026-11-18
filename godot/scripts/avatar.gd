extends Node3D
## Another player in a multiplayer game (net.gd): a body and head in their colour, scaled to the
## size they have grown or shrunk to, with their name above them and a dot where they are aiming,
## so players can point things out. Moves smoothly between the poses that arrive ten times a second.

const EYE := 1.70  # player.gd: eye height at 1:1
const SMOOTH := 12.0

var _body := MeshInstance3D.new()
var _head := MeshInstance3D.new()
var _nose := MeshInstance3D.new()
var _label := Label3D.new()
var _dot := MeshInstance3D.new()
var _mat := StandardMaterial3D.new()
var _feet := Vector3.ZERO
var _yaw := 0.0
var _pitch := 0.0
var _size := 1.0
var _aim := Vector3.ZERO
var _has_pose := false


func _ready() -> void:
	_mat.albedo_color = Color.WHITE
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.22
	capsule.height = 1.3
	_body.mesh = capsule
	_body.position = Vector3(0, 0.65, 0)
	var sphere := SphereMesh.new()
	sphere.radius = 0.16
	sphere.height = 0.32
	_head.mesh = sphere
	_head.position = Vector3(0, EYE - 0.02, 0)
	var visor := BoxMesh.new()
	visor.size = Vector3(0.22, 0.07, 0.08)
	_nose.mesh = visor
	_nose.position = Vector3(0, 0, -0.14)  # the way they face
	_head.add_child(_nose)
	for m in [_body, _head, _nose]:
		m.material_override = _mat
	add_child(_body)
	add_child(_head)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0015
	_label.font_size = 26
	_label.outline_size = 8
	_label.position = Vector3(0, EYE + 0.35, 0)
	add_child(_label)
	var dot := SphereMesh.new()
	dot.radius = 0.5
	dot.height = 1.0
	_dot.mesh = dot
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.no_depth_test = true
	_dot.material_override = glow
	_dot.visible = false
	_dot.top_level = true
	add_child(_dot)
	visible = false


func set_player(player_name: String, color: Color) -> void:
	_label.text = player_name
	_mat.albedo_color = color
	(_dot.material_override as StandardMaterial3D).albedo_color = color


## A new pose: where their feet are, which way they look, their size, and what they aim at
## (null when nothing).
func set_pose(feet: Vector3, yaw: float, pitch: float, size: float, aim: Variant) -> void:
	_feet = feet
	_yaw = yaw
	_pitch = pitch
	_size = maxf(size, 0.00001)
	_dot.visible = aim is Vector3
	if aim is Vector3:
		_aim = aim
	if not _has_pose:
		_has_pose = true
		visible = true
		_place(1.0)


func _process(dt: float) -> void:
	if _has_pose:
		_place(1.0 - exp(-SMOOTH * dt))


func _place(k: float) -> void:
	var s := lerpf(scale.x, _size, k) if scale.x > 0.0 else _size
	scale = Vector3.ONE * s
	position = position.lerp(_feet, k)
	rotation.y = lerp_angle(rotation.y, _yaw, k)
	_head.rotation.x = lerp_angle(_head.rotation.x, _pitch, k)
	if _dot.visible:
		_dot.global_position = _dot.global_position.lerp(_aim, k) if k < 1.0 else _aim
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		var d := cam.global_position.distance_to(_aim) if cam != null else 1.0
		_dot.scale = Vector3.ONE * maxf(d * 0.008, 0.000001)  # the same size on screen however far
