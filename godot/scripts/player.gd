extends Node3D
## The player is the camera. Walks with gravity and collision against the exact CAD geometry,
## flies through walls, and changes size to zoom. Every speed, height and clip distance scales
## with size so movement feels the same at 0.1 mm and at 1 km.

signal size_changed(size: float)
signal growth_blocked  # walking: growing further would push the body into a part

const TALL := 1.75        # metres at 1:1
const EYE := 1.62
const MIN_SIZE := 0.0001 / TALL  # 0.1 mm tall
const MAX_SIZE := 1000.0 / TALL  # 1 km tall
const WALK_SPEED := 4.5
const SPRINT := 2.5
const GRAVITY := 22.0
const JUMP_SPEED := 5.1
const STEP := 0.45
const RADIUS := 0.3
const MOUSE_SENS := 0.0022
const STICK_LOOK := 3.2   # radians per second at full deflection
const PRECISION := 0.25

## Casts a ray against the model: Callable(origin: Vector3, dir: Vector3, max: float) -> Dictionary
var cast: Callable
var camera: Camera3D
var feet := Vector3(0, 0, 14)
var yaw := 0.0
var pitch := -0.12
var size := 1.0
var target_size := 1.0
var fly := false
var sprint_toggled := false
var precision := false
var input_enabled := true
## While a feature panel is open the player can still walk and look, but the D-pad, A and the
## size keys belong to the panel.
var limited := false
var look_from_touch := Vector2.ZERO
var move_from_touch := Vector2.ZERO
var touch_up := false
var touch_down := false

var _vy := 0.0
var _on_ground := true
var _jump_queued := false
var _grow_held := 0.0
var _shrink_held := 0.0
var _scale_hold := 0.0  # touch buttons: +1 grow, -1 shrink
var _blocked_at := -10000

## Sketch view: the camera looks straight down a plane's normal with the plane's X axis to the
## right and its Y axis up. Moving pans across the plane and size is the zoom (distance).
var view_lock := false
var _lock_target := Vector3.ZERO  # point on the plane at the centre of the view
var _lock_basis := Basis.IDENTITY  # columns: plane X, plane Y, plane normal
const LOCK_DISTANCE := 2.6        # camera distance from the plane, in player heights
const BLEND_TIME := 0.35
var _blend_from := Transform3D.IDENTITY
var _blend_t := 1.0


func _ready() -> void:
	camera = Camera3D.new()
	camera.fov = 72.0
	add_child(camera)
	camera.make_current()


func eye_position() -> Vector3:
	return feet + Vector3(0, EYE * size, 0)


func aim_direction() -> Vector3:
	return -camera.global_transform.basis.z


func snap_step() -> float:
	return grid_step() / 4.0


func grid_step() -> float:
	return pow(10.0, round(log(size) / log(10.0)))


func set_size(s: float) -> void:
	target_size = clampf(s, MIN_SIZE, MAX_SIZE)


func scale_by(k: float) -> void:
	set_size(target_size * k)


func hold_scale(direction: float) -> void:
	_scale_hold = direction


## Locks the view onto a plane (Godot-space axes), centred on target.
func lock_view(target: Vector3, xdir: Vector3, ydir: Vector3, normal: Vector3) -> void:
	_start_blend()
	view_lock = true
	_lock_basis = Basis(xdir.normalized(), ydir.normalized(), normal.normalized())
	_lock_target = target
	_sync_locked()


## Leaves the sketch view for free first-person look, flying where the camera is.
func unlock_view() -> void:
	if not view_lock:
		return
	view_lock = false
	fly = true
	var n := _lock_basis.z
	pitch = clampf(asin(clampf(-n.y, -1.0, 1.0)), -1.55, 1.55)
	if absf(n.y) < 0.999:
		yaw = atan2(n.x, n.z)
	_start_blend()


## Where the player stood and looked, to come back to after a sketch.
func pose() -> Dictionary:
	return {feet = feet, yaw = yaw, pitch = pitch, size = target_size, fly = fly}


func restore_pose(p: Dictionary) -> void:
	_start_blend()
	view_lock = false
	feet = p.feet
	yaw = p.yaw
	pitch = p.pitch
	fly = p.fly
	set_size(p.size)


func _start_blend() -> void:
	if camera != null and camera.is_inside_tree():
		_blend_from = camera.transform
		_blend_t = 0.0


func _sync_locked() -> void:
	var eye := _lock_target + _lock_basis.z * LOCK_DISTANCE * EYE * size
	feet = eye - Vector3(0, EYE * size, 0)


func _pan(delta: Vector2) -> void:
	_lock_target += (_lock_basis.x * delta.x + _lock_basis.y * delta.y) * size


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and view_lock:
		_pan(Vector2(event.relative.x, -event.relative.y) * 0.0035 * (PRECISION if precision else 1.0))
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look(event.relative * MOUSE_SENS * (PRECISION if precision else 1.0))
	elif event is InputEventMouseButton and event.pressed and not limited:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			scale_by(1.15)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scale_by(1.0 / 1.15)


func _look(delta: Vector2) -> void:
	yaw -= delta.x
	pitch = clampf(pitch - delta.y, -1.55, 1.55)


func _process(dt: float) -> void:
	dt = minf(dt, 0.05)
	if input_enabled:
		_read_actions(dt)
	_update_size(dt)
	global_position = Vector3.ZERO
	var want: Transform3D
	if view_lock:
		_move_locked(dt)
		_sync_locked()
		want = Transform3D(_lock_basis, eye_position())
	else:
		_move(dt)
		want = Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0)), eye_position())
	if _blend_t < 1.0:
		_blend_t = minf(1.0, _blend_t + dt / BLEND_TIME)
		var k := ease(_blend_t, -2.0)  # ease in and out
		want = _blend_from.interpolate_with(want, k)
	camera.transform = want


## Sketch view: left stick / WASD pan across the plane, the right stick pans finely.
func _move_locked(dt: float) -> void:
	if not input_enabled:
		return
	var mv := Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward") + move_from_touch
	var fine := Input.get_vector(&"look_left", &"look_right", &"look_down", &"look_up") * 0.4
	var touch := Vector2(-look_from_touch.x, look_from_touch.y) * 0.6 / maxf(dt, 1e-3)
	look_from_touch = Vector2.ZERO
	var sprinting: bool = sprint_toggled or Input.is_action_pressed(&"sprint_hold")
	var speed := 1.6 * (SPRINT if sprinting else 1.0) * (PRECISION if precision else 1.0)
	_pan((mv.limit_length(1.0) + fine + touch) * speed * dt)


func _read_actions(dt: float) -> void:
	if view_lock:
		_read_size_actions(dt)  # the sticks pan in _move_locked
		return
	# Stick look with a squared response curve for fine aiming near the centre.
	var stick := Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	stick = stick.normalized() * pow(stick.length(), 2.0) if stick.length() > 0.0 else stick
	var k := STICK_LOOK * dt * (PRECISION if precision else 1.0)
	_look(stick * k + look_from_touch)
	look_from_touch = Vector2.ZERO
	if limited:
		return
	if Input.is_action_just_pressed(&"toggle_fly"):
		fly = not fly
	if Input.is_action_just_pressed(&"sprint_toggle"):
		sprint_toggled = not sprint_toggled
	if Input.is_action_just_pressed(&"precision_aim"):
		precision = not precision
	if Input.is_action_just_pressed(&"jump") and not fly:
		_jump_queued = true
	_read_size_actions(dt)


func _read_size_actions(dt: float) -> void:
	if Input.is_action_just_pressed(&"precision_aim") and view_lock:
		precision = not precision
	if Input.is_action_just_pressed(&"reset_size"):
		set_size(1.0)
	# D-pad / keys: a tap doubles or halves, holding scales smoothly.
	_grow_held = _held(&"grow", _grow_held, dt, 2.0)
	_shrink_held = _held(&"shrink", _shrink_held, dt, 0.5)


func _held(action: StringName, held: float, dt: float, tap_factor: float) -> float:
	if Input.is_action_just_pressed(action):
		scale_by(tap_factor)
		return 0.0
	if Input.is_action_pressed(action):
		held += dt
		if held > 0.35:
			scale_by(pow(tap_factor, dt * 1.6))
		return held
	return 0.0


func _update_size(dt: float) -> void:
	if _scale_hold != 0.0:
		scale_by(exp(1.4 * dt * _scale_hold))
	if target_size > size * 1.0001 and not fly and not view_lock:
		var room := room_to_grow()
		if target_size > room:
			target_size = maxf(room, size)  # never shrink the player because of it
			if Time.get_ticks_msec() - _blocked_at > 1200:
				_blocked_at = Time.get_ticks_msec()
				growth_blocked.emit()
	var before := size
	var a := log(size)
	var b := log(target_size)
	size = exp(a + (b - a) * (1.0 - exp(-dt * 9.0)))
	camera.near = maxf(1e-6, 0.02 * size)
	camera.far = clampf(6000.0 * size, 80.0, 30000.0)
	if absf(size - before) > before * 1e-4:
		size_changed.emit(size)


func _move(dt: float) -> void:
	var mv := Vector2.ZERO
	if input_enabled:
		mv = Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward") + move_from_touch
	mv = mv.limit_length(1.0)
	var sprinting: bool = sprint_toggled or Input.is_action_pressed(&"sprint_hold")
	var speed := WALK_SPEED * size * (SPRINT if sprinting else 1.0)
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	if fly:
		var look := -camera.global_transform.basis.z
		var up := 0.0
		if input_enabled and not limited:
			up = float(Input.is_action_pressed(&"jump") or touch_up) - float(Input.is_action_pressed(&"crouch") or touch_down)
		feet += (look * mv.y + right * mv.x + Vector3.UP * up) * speed * dt
		_vy = 0.0
		_jump_queued = false
		return
	if mv.length() < 0.1:
		sprint_toggled = false  # letting go of the stick ends a toggled sprint
	var step := (fwd * mv.y + right * mv.x) * speed * dt
	if step.x != 0.0 and not _blocked(Vector3(signf(step.x), 0, 0), absf(step.x)):
		feet.x += step.x
	if step.z != 0.0 and not _blocked(Vector3(0, 0, signf(step.z)), absf(step.z)):
		feet.z += step.z
	if (_jump_queued or touch_up) and _on_ground:
		_vy = JUMP_SPEED * size
	_jump_queued = false
	_vy -= GRAVITY * size * dt
	feet.y += _vy * dt
	var floor_y := _floor_at(feet + Vector3(0, STEP * size, 0))
	if feet.y <= floor_y:
		feet.y = floor_y
		_vy = 0.0
		_on_ground = true
	else:
		_on_ground = feet.y - floor_y < 0.02 * size and _vy <= 0.0


## The largest size the walking player can grow to here without its body entering a part: the
## head stays under the nearest ceiling and the body clear of nearby walls. Faces seen from
## inside a part do not count, as in _blocked, so a player already inside one is not trapped.
func room_to_grow() -> float:
	if not cast.is_valid():
		return MAX_SIZE
	var limit := MAX_SIZE
	var base := feet + Vector3(0, 0.02 * size, 0)
	var up: Dictionary = cast.call(base, Vector3.UP, TALL * target_size * 1.1 + 1e-6)
	if not up.is_empty() and up.normal.y < 0.0:
		limit = minf(limit, (up.distance + 0.02 * size) / (TALL * 1.03))
	# Walls, sampled at heights through the body the player would grow into.
	var height := TALL * minf(target_size, limit)
	for f in [0.35, 0.65, 0.95]:
		var o := feet + Vector3(0, maxf(height * f, STEP * size), 0)
		for i in 8:
			var dir := Vector3(cos(TAU * i / 8.0), 0, sin(TAU * i / 8.0))
			var hit: Dictionary = cast.call(o, dir, RADIUS * target_size * 1.2 + 1e-6)
			if not hit.is_empty() and hit.normal.dot(dir) < 0.0:
				limit = minf(limit, hit.distance / (RADIUS * 1.1))
	return maxf(limit, MIN_SIZE)


## The surface under probe: the model, the table or the room floor (all through cast).
func _floor_at(probe: Vector3) -> float:
	var y := -1e9  # the room floor always answers; this only guards a missing cast
	if not cast.is_valid():
		return 0.0
	var hit: Dictionary = cast.call(probe, Vector3.DOWN, 1e6)
	if not hit.is_empty() and hit.normal.y > 0.2:  # only surfaces facing up are floors
		y = hit.point.y
	return y


func _blocked(dir: Vector3, dist: float) -> bool:
	if not cast.is_valid():
		return false
	for h in [0.55, 1.45]:
		var o := feet + Vector3(0, h * size, 0)
		var hit: Dictionary = cast.call(o, dir, dist + RADIUS * size)
		# A face seen from inside a solid does not block, so a player inside a part can walk out.
		if not hit.is_empty() and hit.normal.dot(dir) < 0.0:
			return true
	return false
