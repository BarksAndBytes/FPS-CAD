class_name TheoraBackend
extends PlaybackBackend

## Default backend, built on Godot's VideoStreamPlayer.
## Plays local Ogg Theora (.ogv) files only, with seeking (Godot 4.4+). URLs and MP4 need
## another backend.

var _player: VideoStreamPlayer


func attach(parent: Node) -> void:
	_player = VideoStreamPlayer.new()
	_player.expand = true
	_player.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_player.finished.connect(_on_finished)
	parent.add_child(_player)


func load(path: String) -> bool:
	last_error = ""
	if path.get_extension().to_lower() != "ogv":
		return _fail("only .ogv (Ogg Theora) files can play, got: %s" % path.get_file())
	if not FileAccess.file_exists(path):
		return _fail("no such file: %s" % path)
	var problem := theora_problem(path)
	if problem != "":
		return _fail(problem)
	var stream := VideoStreamTheora.new()
	stream.file = path
	_player.stream = stream
	source = path
	state = State.IDLE
	return true


## Why a file isn't an Ogg Theora video, from its first bytes, or "" when it is.
static func theora_problem(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot read %s (error %d)" % [path.get_file(), FileAccess.get_open_error()]
	var head := f.get_buffer(65536)
	f.close()
	if head.size() < 4 or head.slice(0, 4).get_string_from_ascii() != "OggS":
		return "%s is not an Ogg file" % path.get_file()
	# A Theora stream's first header packet starts with 0x80 "theora".
	for i in maxi(0, head.size() - 7):
		if head[i] == 0x80 and head.slice(i + 1, i + 7).get_string_from_ascii() == "theora":
			return ""
	return "%s has no Theora video (it may be sound only)" % path.get_file()


func play() -> void:
	if _player.stream == null:
		push_warning("TheoraBackend: play() called before load().")
		return
	_player.paused = false
	_player.play()
	state = State.PLAYING


func pause() -> void:
	if state != State.PLAYING:
		return
	_player.paused = true
	state = State.PAUSED


func resume() -> void:
	if state != State.PAUSED:
		return
	_player.paused = false
	state = State.PLAYING


func stop() -> void:
	_player.stop()
	state = State.IDLE


## Godot 4.4 and later seek Theora by setting stream_position, playing or paused.
func supports_seek() -> bool:
	return _player.stream != null and state != State.IDLE


func seek(seconds: float) -> void:
	var length := get_duration()
	_player.stream_position = clampf(seconds, 0.0, length if length > 0.0 else seconds)


func get_position() -> float:
	return _player.stream_position if state != State.IDLE else 0.0


func get_duration() -> float:
	return _player.get_stream_length() if _player.stream != null else 0.0


func set_volume(linear: float) -> void:
	_player.volume = clampf(linear, 0.0, 1.0)


func _on_finished() -> void:
	state = State.IDLE
	finished.emit()


func _fail(reason: String) -> bool:
	last_error = reason
	push_warning("TheoraBackend: " + reason)
	return false
