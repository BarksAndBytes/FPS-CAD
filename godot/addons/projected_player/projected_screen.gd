class_name ProjectedScreen
extends Node3D

## Plays video onto one surface of a mesh, such as a 3D whiteboard.
## Set target_mesh, then call load_source() and play(). A ProjectedReceiver
## can drive this node over the network.

signal playback_finished

## The mesh that displays the video. Its UVs decide how the video is mapped.
@export var target_mesh: MeshInstance3D
@export var surface_index := 0
## Render resolution of the video texture.
@export var resolution := Vector2i(1920, 1080)

var backend: PlaybackBackend
var _viewport: SubViewport


func _ready() -> void:
	_viewport = SubViewport.new()
	_viewport.size = resolution
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	backend = _create_backend()
	backend.attach(_viewport)
	backend.finished.connect(func() -> void: playback_finished.emit())

	if target_mesh == null:
		push_warning("ProjectedScreen '%s' has no target_mesh, so video will not be visible." % name)
		return

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = _viewport.get_texture()
	target_mesh.set_surface_override_material(surface_index, material)


## Override in a subclass to use a different playback engine.
func _create_backend() -> PlaybackBackend:
	return TheoraBackend.new()


func load_source(source: String) -> bool:
	return backend.load(source)


func play() -> void:
	backend.play()


func pause() -> void:
	backend.pause()


func resume() -> void:
	backend.resume()


func stop() -> void:
	backend.stop()


func can_seek() -> bool:
	return backend.supports_seek()


func seek(seconds: float) -> void:
	backend.seek(seconds)


func get_source() -> String:
	return backend.source


## Seconds into the current video. (Not get_position(): that is Node3D's position in space.)
func get_playback_position() -> float:
	return backend.get_position()


## Why the last load_source() failed, or "".
func get_last_error() -> String:
	return backend.last_error


func get_duration() -> float:
	return backend.get_duration()


## Sound level, 0 (silent) to 1 (full).
func set_volume(linear: float) -> void:
	backend.set_volume(linear)


## True for a screen that fetches and plays links itself, such as one wrapping a player with its
## own downloader. A ProjectedDlnaRenderer then hands it the phone's link as is (load_source(link)
## and play()) instead of converting it first, and reads its progress from get_state_name(),
## which may then also return "loading" (fetching or converting) and "error" (see
## get_last_error()).
func plays_links() -> bool:
	return false


func get_state_name() -> String:
	match backend.state:
		PlaybackBackend.State.PLAYING:
			return "playing"
		PlaybackBackend.State.PAUSED:
			return "paused"
		_:
			return "idle"
