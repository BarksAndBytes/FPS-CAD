extends ProjectedScreen
## Lets phones cast to a video board. Each video board has a ProjectedDlnaRenderer (the
## ProjectedPlayer addon, addons/projected_player) that makes it a TV in phone apps which cast to
## DLNA TVs (BubbleUPnP, Web Video Caster…). The renderer drives the board through this screen.
##
## The board already downloads, converts and keeps videos (whiteboard.gd), so this screen
## plays_links(): the renderer hands it the phone's link as is, and the board's own progress
## ("Downloading…", "Converting…") and errors are passed back to the phone.

var board: Node3D  # whiteboard.gd
var title := ""  # what the phone app calls the video
var on_play := Callable()  # boards.gd: saves the layout once a cast starts
var _link := ""


func _ready() -> void:
	pass  # the board draws the video itself: no viewport or backend here


func plays_links() -> bool:
	return true


func load_source(source: String) -> bool:
	_link = source
	return true


func play() -> void:
	board.play_url(_link, title)
	if on_play.is_valid():
		on_play.call()


func pause() -> void:
	board.pause_video()


func resume() -> void:
	board.resume_video()


func stop() -> void:
	if board.video_url != "":
		board.set_video(board.video_url)


func can_seek() -> bool:
	return board.video_state == "playing" or board.video_state == "paused"


func seek(seconds: float) -> void:
	board.seek_video(seconds)


func get_source() -> String:
	return board.video_url


func get_playback_position() -> float:
	return board.video_position()


func get_last_error() -> String:
	return board.video_message


func get_duration() -> float:
	return board.video_length()


func set_volume(linear: float) -> void:
	board.cast_volume = clampf(linear, 0.0, 1.0)


func get_state_name() -> String:
	match board.video_state:
		"loading", "copying", "converting":
			return "loading"
		"playing":
			return "playing"
		"paused":
			return "paused"
		"error":
			return "error"
	return "idle"
