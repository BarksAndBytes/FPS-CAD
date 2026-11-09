class_name PlaybackBackend
extends RefCounted

## Base class for playback engines used by ProjectedScreen.
## Subclass this to add formats or sources. For example, an FFmpeg-based
## GDExtension could play MP4 and HLS, which Godot's built-in player cannot.

signal finished

enum State { IDLE, PLAYING, PAUSED }

var state: State = State.IDLE
var source := ""
## Why the last load() failed, for the receiver's error message. Empty after a good load.
var last_error := ""


## Create child nodes under the given parent (a SubViewport).
func attach(_parent: Node) -> void:
	pass


## Prepare a source for playback. Returns false if this backend cannot play it, with the
## reason in last_error.
func load(_source: String) -> bool:
	return false


func play() -> void:
	pass


func pause() -> void:
	pass


func resume() -> void:
	pass


func stop() -> void:
	pass


## Whether seek() works. Receivers refuse seek requests when this is false.
## Implementations should ignore pause() unless PLAYING and resume() unless PAUSED, so the
## state never claims playback that isn't happening.
func supports_seek() -> bool:
	return false


func seek(_seconds: float) -> void:
	pass


func get_position() -> float:
	return 0.0


func get_duration() -> float:
	return 0.0


## Sound level, 0 (silent) to 1 (full). Backends without sound may ignore it.
func set_volume(_linear: float) -> void:
	pass
