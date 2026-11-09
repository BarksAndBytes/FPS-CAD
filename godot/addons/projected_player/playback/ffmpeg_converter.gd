class_name FfmpegConverter
extends RefCounted

## Converts a video (an http(s) link or a local file) to Ogg Theora with the FFmpeg program, in
## the background, so TheoraBackend can play it. Call start(), then poll() every frame until it
## returns DONE or FAILED.
##
## For links, FFmpeg may only use network protocols (no file:, pipe: and so on), so a playlist
## from the network cannot make it read files on this device.

enum { RUNNING, DONE, FAILED }

## Wider videos are scaled down to this, which keeps converting quick.
const MAX_WIDTH := 1280
const MAX_WIDTH_MOBILE := 854
const NETWORK_PROTOCOLS := "http,https,tcp,tls,crypto"

## Seconds of video converted so far, and the whole length (0 until FFmpeg reports it).
var done_seconds := 0.0
var duration := 0.0
## Why it failed, when poll() returned FAILED.
var error := ""
var output := ""

var _pid := -1
var _stdio: FileAccess
var _stderr: FileAccess
var _out_text := ""
var _err_text := ""
var _result := RUNNING


## Fraction converted, 0 to 1 (0 while the length is unknown).
func progress() -> float:
	return clampf(done_seconds / duration, 0.0, 1.0) if duration > 0.0 else 0.0


## Starts FFmpeg (ffmpeg: the program) converting input to an .ogv at output. False, with
## error set, if it doesn't start.
func start(ffmpeg: String, input: String, output_path: String) -> bool:
	output = output_path
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var info := OS.execute_with_pipe(ffmpeg, args(input, output + ".part"), false)
	if info.is_empty():
		return _failed("FFmpeg didn't start (%s)" % ffmpeg)
	_pid = int(info.pid)
	_stdio = info.stdio
	_stderr = info.stderr
	_result = RUNNING
	return true


## RUNNING, DONE (the video is at output) or FAILED (see error).
func poll() -> int:
	if _result != RUNNING:
		return _result
	_pump()
	if OS.is_process_running(_pid):
		return RUNNING
	_pump()
	var code := OS.get_process_exit_code(_pid)
	var part := output + ".part"
	if code != 0 or not FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
		return int(_failed(_describe_failure(code)))
	var problem := TheoraBackend.theora_problem(part)
	if problem != "":
		DirAccess.remove_absolute(part)
		return int(_failed("FFmpeg made no picture: the link may be sound only"))
	DirAccess.remove_absolute(output)
	DirAccess.rename_absolute(part, output)
	_result = DONE
	return _result


func cancel() -> void:
	if _result == RUNNING and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	if output != "":
		DirAccess.remove_absolute(output + ".part")
	_result = FAILED
	error = "cancelled"


## The FFmpeg arguments that turn input into Ogg Theora video with Vorbis sound at out.
static func args(input: String, out: String) -> PackedStringArray:
	var a := PackedStringArray(["-hide_banner", "-nostdin", "-y"])
	if input.begins_with("http://") or input.begins_with("https://"):
		a.append_array(["-protocol_whitelist", NETWORK_PROTOCOLS])
	var width := MAX_WIDTH_MOBILE if OS.has_feature("mobile") else MAX_WIDTH
	a.append_array(["-i", input, "-map", "0:v:0", "-map", "0:a:0?",
		"-vf", "scale=w='min(%d,iw)':h=-2" % width,
		"-c:v", "libtheora", "-q:v", "7", "-c:a", "libvorbis", "-q:a", "4",
		"-progress", "pipe:1", "-nostats", "-f", "ogg", out])
	return a


## The FFmpeg program to use: hint if it is one, else ffmpeg beside this program, else ffmpeg on
## the PATH. Only an FFmpeg with the Theora encoder counts. "" when there is none.
static func find_ffmpeg(hint := "") -> String:
	if OS.has_feature("web"):
		return ""
	var exe := "ffmpeg.exe" if OS.has_feature("windows") else "ffmpeg"
	var candidates := PackedStringArray()
	if hint != "":
		candidates.append(hint)
	var beside := OS.get_executable_path().get_base_dir().path_join(exe)
	if FileAccess.file_exists(beside):
		candidates.append(beside)
	candidates.append(exe)
	for candidate in candidates:
		var out := []
		if OS.execute(candidate, ["-hide_banner", "-encoders"], out, true) == 0 and "libtheora" in "".join(out):
			return candidate
	return ""


## Seconds from FFmpeg's "Duration: 00:01:02.50" log line, or 0.
static func parse_duration(log_text: String) -> float:
	var at := log_text.find("Duration: ")
	if at < 0:
		return 0.0
	var hms := log_text.substr(at + 10, 11).split(":")
	if hms.size() != 3 or not hms[0].is_valid_int():
		return 0.0
	return float(hms[0]) * 3600.0 + float(hms[1]) * 60.0 + float(hms[2])


func _pump() -> void:
	for pair in [[_stdio, true], [_stderr, false]]:
		var fa: FileAccess = pair[0]
		if fa == null:
			continue
		var chunk := fa.get_buffer(65536)
		if chunk.is_empty():
			continue
		if pair[1]:
			_out_text += chunk.get_string_from_utf8()
		else:
			_err_text += chunk.get_string_from_utf8()
	if duration <= 0.0:
		duration = parse_duration(_err_text)
	var key := _out_text.rfind("out_time_us=")
	if key >= 0:
		var end := _out_text.find("\n", key)
		if end > key:
			done_seconds = _out_text.substr(key + 12, end - key - 12).to_float() / 1000000.0
	if _out_text.length() > 20000:
		_out_text = _out_text.substr(_out_text.length() - 2000)
	if _err_text.length() > 40000:
		_err_text = _err_text.substr(0, 4000) + "\n…\n" + _err_text.substr(_err_text.length() - 4000)


func _describe_failure(code: int) -> String:
	var lines := _err_text.strip_edges().split("\n")
	var last := lines[lines.size() - 1].strip_edges() if not lines.is_empty() else ""
	if "Server returned 4" in _err_text or "Connection refused" in _err_text or "timed out" in _err_text.to_lower():
		return "couldn't download the video (%s)" % last
	if "Invalid data found" in _err_text:
		return "that link isn't a video FFmpeg can read"
	if "matches no streams" in _err_text:
		return "that video has no picture"
	return "FFmpeg stopped (exit code %d): %s" % [code, last]


func _failed(reason: String) -> bool:
	error = reason
	_result = FAILED
	return false
