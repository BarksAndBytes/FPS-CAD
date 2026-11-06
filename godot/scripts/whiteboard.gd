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
## part's volume, area, mass and size; kind "notes" shows the player's own notes; kind "video"
## plays a video from a link. Every board stands on the floor at its feet, turned by yaw and
## scaled evenly by board_scale.
##
## Video: Godot plays Ogg Theora (.ogv) only, from a file, so the board downloads the link into
## user://videos (kept, so it plays again without downloading) and checks what arrived. Any other
## video (MP4, MOV, WebM, MKV, AVI…) is converted to Theora with FFmpeg, which ships beside the
## game on Windows (or is found on the PATH elsewhere), with progress on the board. What can't play
## (a failed download, a platform without FFmpeg, a file FFmpeg can't read) gets an error screen
## on the board saying why. Its sound fades with distance.
##
## A link to a web page plays the page's main video (find_page_video): the video the page declares
## (og:video, or a VideoObject's contentUrl), else its largest <video>, else a link to a video
## file. HLS and DASH playlists (.m3u8, .mpd) go straight to FFmpeg, which reads the stream.
## YouTube, Vimeo and the like are turned away: their pages hold no video file, and getting one
## would mean working around their stream protection and terms.

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
const VIDEO_DIR := "user://videos"
const VIDEO_LIMIT := 1024 * 1024 * 1024  # 1 GB
const CONVERT_HINT := "The whiteboard plays Ogg Theora (.ogv) videos. Convert one with:\nffmpeg -i video.mp4 -c:v libtheora -q:v 7 -c:a libvorbis video.ogv"
const MAX_WIDTH := 1280  # converted videos are scaled down to this: Theora decodes on the CPU
const USER_AGENT := "User-Agent: Mozilla/5.0 (compatible; FPS-CAD video board)"
## Sites that show their videos inside web pages, which the board can't display.
const VIDEO_SITES := ["youtube.com", "youtu.be", "vimeo.com", "twitch.tv", "tiktok.com", "dailymotion.com",
	"facebook.com", "instagram.com", "twitter.com", "x.com/"]

var active := false
var kind := "messages"     # "messages", "properties" or "notes"
var board_id := ""
var yaw := 0.0
var board_scale := 1.0
var notes: Array = []      # kind "notes": the player's notes, one per line
var video_url := ""        # kind "video"
var video_state := ""      # "", "ready", "loading", "converting", "playing", "paused" or "error"
var video_message := ""    # the error screen's reason
var _video: VideoStreamPlayer = null
var _video_back := ColorRect.new()
var _http: HTTPRequest = null
var _video_fitted := false
var _ff := {}              # the FFmpeg conversion running: {pid, stdio, stderr, src, out, part, out_text, err_text, duration, done_us}
static var _ffmpeg_path: Variant = null  # found once: the FFmpeg program, or "" if there is none
var _video_t := 0.0
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
	if kind == "video":
		d.url = video_url
	return d


# ---------- video ----------

## Why a link can't play, before downloading anything; "" when it might.
static func url_problem(url: String) -> String:
	var u := url.strip_edges().to_lower()
	if not (u.begins_with("https://") or u.begins_with("http://")):
		return "That isn't a web link: it should start with https://"
	for site in VIDEO_SITES:
		if site in u:
			return "%s streams its videos in a protected player, so the whiteboard can't take the video from the page. Link to a page with an ordinary video, or to the video file itself." % [
				String(site).trim_suffix("/")]
	return ""


## What the start of a downloaded file is: "theora" (plays as it is), "page" (a web page, never a
## video), or another kind that FFmpeg may convert: "mp4", "webm", "ogg" (Ogg without Theora),
## "other".
static func video_kind(head: PackedByteArray, content_type := "") -> String:
	var start := head.slice(0, 12).get_string_from_ascii()
	if start.begins_with("OggS"):
		for i in maxi(0, head.size() - 7):
			if head[i] == 0x80 and head.slice(i + 1, i + 7).get_string_from_ascii() == "theora":
				return "theora"
		return "ogg"
	if head.size() >= 8 and head.slice(4, 8).get_string_from_ascii() == "ftyp":
		return "mp4"
	if head.size() >= 4 and head[0] == 0x1A and head[1] == 0x45 and head[2] == 0xDF and head[3] == 0xA3:
		return "webm"
	if "text/html" in content_type.to_lower() or start.strip_edges().to_lower().begins_with("<"):
		return "page"
	return "other"


## Why downloaded bytes can't play without converting; "" for an Ogg Theora video.
static func video_problem(head: PackedByteArray, content_type := "") -> String:
	match video_kind(head, content_type):
		"theora":
			return ""
		"ogg":
			return "That's an Ogg file without Theora video (sound only, or another video format).\n\n" + CONVERT_HINT
		"mp4":
			return "That's an MP4 / MOV video, which the whiteboard can't decode itself.\n\n" + CONVERT_HINT
		"webm":
			return "That's a WebM / MKV video, which the whiteboard can't decode itself.\n\n" + CONVERT_HINT
		"page":
			return "That link is a web page, not a video file.\n\n" + CONVERT_HINT
	return "That file isn't a video the whiteboard can play.\n\n" + CONVERT_HINT


## The FFmpeg program that converts videos: beside the game (Windows builds ship it), else on the
## PATH. "" when there is none (Android).
static func ffmpeg_path() -> String:
	if _ffmpeg_path != null:
		return _ffmpeg_path
	_ffmpeg_path = ""
	if OS.has_feature("android") or OS.has_feature("web"):
		return ""
	var exe := "ffmpeg.exe" if OS.has_feature("windows") else "ffmpeg"
	var beside := OS.get_executable_path().get_base_dir().path_join(exe)
	for candidate in [beside, exe]:
		if candidate == beside and not FileAccess.file_exists(beside):
			continue
		var out := []
		if OS.execute(candidate, ["-hide_banner", "-encoders"], out, true) == 0 and "libtheora" in "".join(out):
			_ffmpeg_path = candidate
			break
	return _ffmpeg_path


## The FFmpeg arguments that turn src into an Ogg Theora video at out (at most MAX_WIDTH wide).
static func convert_args(src: String, out: String) -> PackedStringArray:
	var web := PackedStringArray(["-user_agent", USER_AGENT.trim_prefix("User-Agent: ")]) if src.begins_with("http") else PackedStringArray()
	return web + PackedStringArray(["-hide_banner", "-nostdin", "-y", "-i", src,
		"-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=w='min(%d,iw)':h=-2" % MAX_WIDTH,
		"-c:v", "libtheora", "-q:v", "7", "-c:a", "libvorbis", "-q:a", "4",
		"-progress", "pipe:1", "-nostats", "-f", "ogg", out])


## Where a link's video is kept once downloaded.
static func cached_path(url: String) -> String:
	return "%s/%s.ogv" % [VIDEO_DIR, url.strip_edges().md5_text()]


## Shows a link without playing it (a board coming back from a saved part).
func set_video(url: String) -> void:
	video_url = url.strip_edges()
	_stop_video()
	if video_url == "":
		video_state = ""
		set_card("VIDEO", "No video yet", "Aim here with the Video board tool and press the primary button to give it a link to a .ogv video file.")
	else:
		video_state = "ready"
		set_card("VIDEO", "Ready to play", video_url, INK)


## Downloads (unless kept from before) and plays the video at url.
func play_url(url: String) -> void:
	video_url = url.strip_edges()
	_stop_video()
	var problem := url_problem(video_url)
	if problem != "":
		_video_error(problem)
		return
	var path := cached_path(video_url)
	if FileAccess.file_exists(path):
		_start_video(path)
		return
	if is_stream(video_url):
		_convert(video_url, path, "That stream couldn't be read.", false)
		return
	_download(video_url, path, false)


## Fetches url into path + ".part"; from_page: url was found on the page the player linked.
func _download(url: String, path: String, from_page: bool) -> void:
	DirAccess.make_dir_recursive_absolute(VIDEO_DIR)
	_http = HTTPRequest.new()
	_http.max_redirects = 8
	_http.body_size_limit = VIDEO_LIMIT
	_http.download_chunk_size = 262144
	_http.download_file = ProjectSettings.globalize_path(path + ".part")
	add_child(_http)
	_http.request_completed.connect(_on_video_downloaded.bind(path, url, from_page))
	var err := _http.request(url, [USER_AGENT])
	if err != OK:
		_video_error("The download could not start (error %d)." % err)
		return
	video_state = "loading"
	set_card("VIDEO", "Downloading…", url, INK, 0.0)


## HLS and DASH playlists: FFmpeg reads these itself, segment by segment.
static func is_stream(url: String) -> bool:
	var u := url.to_lower().get_slice("?", 0).get_slice("#", 0)
	return u.ends_with(".m3u8") or u.ends_with(".mpd")


## The main video on a web page, as an absolute link, or "". In order: the video the page
## declares (og:video / twitter:player:stream when it is a file or a stream, a VideoObject's
## contentUrl), the largest <video> (its src or first <source>), a link to a video file.
static func find_page_video(html: String, page_url: String) -> String:
	var base := page_url
	var bm := RegEx.create_from_string("(?is)<base\\s[^>]*href\\s*=\\s*[\"']([^\"']+)").search(html)
	if bm != null:
		base = resolve_url(page_url, _unescape(bm.get_string(1)))
	var found: Array = []  # [url, score]
	var meta := RegEx.create_from_string("(?is)<meta\\s[^>]*>")
	var declared := ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"]
	for m in meta.search_all(html):
		var a := _attributes(m.get_string())
		var key := String(a.get("property", a.get("name", ""))).to_lower()
		var content := String(a.get("content", ""))
		if key in declared and content != "":
			var u := resolve_url(base, content)
			if _video_file(u):
				found.append([u, 3000000000 - declared.find(key)])
	for m in RegEx.create_from_string("(?s)\"contentUrl\"\\s*:\\s*\"([^\"]+)\"").search_all(html):
		var u := resolve_url(base, m.get_string(1).replace("\\/", "/"))
		if _video_file(u):
			found.append([u, 2000000000])
	var order := 0
	for m in RegEx.create_from_string("(?is)<video\\b([^>]*)>(.*?)</video>").search_all(html):
		order += 1
		var a := _attributes("<video " + m.get_string(1) + ">")
		var src := String(a.get("src", ""))
		if src == "":
			for s in RegEx.create_from_string("(?is)<source\\b[^>]*>").search_all(m.get_string(2)):
				var sa := _attributes(s.get_string())
				var t := String(sa.get("type", "")).to_lower()
				if String(sa.get("src", "")) != "" and (t == "" or t.begins_with("video/") or "mpegurl" in t or "dash" in t):
					src = sa.src
					break
		if src == "" or src.begins_with("blob:") or src.begins_with("data:"):
			continue
		var area := int(String(a.get("width", "0")).to_int()) * int(String(a.get("height", "0")).to_int())
		found.append([resolve_url(base, src), 1000000000 + mini(area, 99999999) * 2 - order])
	for m in RegEx.create_from_string("(?is)href\\s*=\\s*[\"']([^\"']+)[\"']").search_all(html):
		var u := resolve_url(base, _unescape(m.get_string(1)))
		if _video_file(u, true):
			found.append([u, 1])
			break
	if found.is_empty():
		return ""
	found.sort_custom(func(x, y): return int(x[1]) > int(y[1]))
	return found[0][0]


## True for a link that looks like a video file or a stream (not a page). strict: by its extension
## only (links in the page text); otherwise anything but an obvious page counts.
static func _video_file(url: String, strict := false) -> bool:
	var u := url.to_lower().get_slice("?", 0).get_slice("#", 0)
	if not (u.begins_with("http://") or u.begins_with("https://")):
		return false
	for ext in [".mp4", ".m4v", ".mov", ".webm", ".mkv", ".ogv", ".ogg", ".avi", ".m3u8", ".mpd"]:
		if u.ends_with(ext):
			return true
	if strict:
		return false
	for site in VIDEO_SITES:
		if site in u:
			return true  # kept, so the board can say why it can't play
	return not (u.ends_with(".html") or u.ends_with(".htm") or u.ends_with(".php") or "/embed/" in u or u.ends_with("/"))


## Attributes of one HTML tag, names lower-cased, entities in values undone.
static func _attributes(tag: String) -> Dictionary:
	var out := {}
	for m in RegEx.create_from_string("(?s)([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))").search_all(tag):
		var v := m.get_string(3) if m.get_string(3) != "" else (m.get_string(4) if m.get_string(4) != "" else m.get_string(5))
		out[m.get_string(1).to_lower()] = _unescape(v)
	return out


static func _unescape(s: String) -> String:
	return s.replace("&amp;", "&").replace("&#38;", "&").replace("&quot;", "\"").replace("&#39;", "'").replace("&#x2F;", "/").replace("&#47;", "/").strip_edges()


## rel made absolute against base (a page's address).
static func resolve_url(base: String, rel: String) -> String:
	var r := rel.strip_edges()
	if r.begins_with("http://") or r.begins_with("https://"):
		return r
	var scheme := base.get_slice("://", 0)
	if r.begins_with("//"):
		return scheme + ":" + r
	var rest := base.get_slice("://", 1)
	var host := rest.get_slice("/", 0)
	if r.begins_with("/"):
		return "%s://%s%s" % [scheme, host, r]
	var path := rest.substr(host.length()).get_slice("?", 0).get_slice("#", 0)
	var dir := path.substr(0, path.rfind("/") + 1) if path.contains("/") else "/"
	var parts: Array = []
	for seg in (dir + r).split("/"):
		if seg == "..":
			if not parts.is_empty():
				parts.pop_back()
		elif seg != ".":
			parts.append(seg)
	return "%s://%s%s" % [scheme, host, "/".join(parts)]


## Plays a video file that is already on this device (also used by the tests).
func play_file(path: String, url := "") -> void:
	video_url = url if url != "" else path
	_stop_video()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_video_error("The video file is missing.")
		return
	var head := f.get_buffer(4096)
	f.close()
	var kind := video_kind(head)
	if kind == "theora":
		_start_video(path)
	elif kind == "page":
		_video_error(video_problem(head))
	else:
		_convert(path, cached_path(video_url), video_problem(head), false)


## Converts src to Ogg Theora at out with FFmpeg in the background, then plays it. why: what the
## board says if it can't. remove_src: src was only downloaded for this.
func _convert(src: String, out: String, why: String, remove_src: bool) -> void:
	var ff := ffmpeg_path()
	if ff == "":
		if remove_src:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(src))
		var kind_line := why.replace(CONVERT_HINT, "").strip_edges() if CONVERT_HINT in why else "That video needs converting."
		_video_error(kind_line + "\n\nConverting it needs FFmpeg, which this version of the game doesn't have.\n\n" + CONVERT_HINT)
		return
	var part := out + ".part"
	var input := src if src.begins_with("http://") or src.begins_with("https://") else ProjectSettings.globalize_path(src)
	var info := OS.execute_with_pipe(ff, convert_args(input, ProjectSettings.globalize_path(part)), false)
	if info.is_empty():
		_video_error("FFmpeg didn't start.")
		return
	_ff = {pid = info.pid, stdio = info.stdio, stderr = info.stderr, src = src, out = out, part = part,
		remove_src = remove_src, out_text = "", err_text = "", duration = 0.0, done_us = 0.0}
	video_state = "converting"
	set_card("VIDEO", "Converting for the whiteboard…", video_url, INK, 0.0)


## Reads FFmpeg's progress (key=value lines on stdout; the duration from its log on stderr) and
## finishes when it stops.
func _poll_convert() -> void:
	for pair in [["stdio", "out_text"], ["stderr", "err_text"]]:
		var fa: FileAccess = _ff[pair[0]]
		if fa == null:
			continue
		var chunk := fa.get_buffer(65536)
		if not chunk.is_empty():
			_ff[pair[1]] += chunk.get_string_from_utf8()
	var err: String = _ff.err_text
	if _ff.duration <= 0.0:
		var at := err.find("Duration: ")
		if at >= 0:
			var hms := err.substr(at + 10, 11).split(":")
			if hms.size() == 3:
				_ff.duration = float(hms[0]) * 3600.0 + float(hms[1]) * 60.0 + float(hms[2])
	var out: String = _ff.out_text
	var key := out.rfind("out_time_us=")
	if key < 0:
		key = out.rfind("out_time_ms=")  # older FFmpeg: also microseconds, despite the name
	if key >= 0:
		_ff.done_us = out.substr(key + 12, out.find("\n", key) - key - 12).to_float()
	if len(err) > 20000:
		_ff.err_text = err.substr(err.length() - 4000)
	if len(out) > 20000:
		_ff.out_text = out.substr(out.length() - 2000)
	var p: float = clampf(_ff.done_us / 1e6 / _ff.duration, 0.0, 1.0) if _ff.duration > 0.0 else 0.0
	set_card("VIDEO", "Converting for the whiteboard…", "%s\n\n%d%%" % [video_url, roundi(p * 100.0)], INK, p)
	if OS.is_process_running(int(_ff.pid)):
		return
	var code := OS.get_process_exit_code(int(_ff.pid))
	var ff := _ff
	_ff = {}
	if ff.remove_src:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ff.src))
	var f := FileAccess.open(ff.part, FileAccess.READ)
	var head := f.get_buffer(4096) if f != null else PackedByteArray()
	if f != null:
		f.close()
	if code != 0 or video_kind(head) != "theora":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ff.part))
		var lines := String(ff.err_text).strip_edges().split("\n")
		var last := lines[lines.size() - 1].strip_edges() if not lines.is_empty() else ""
		_video_error("FFmpeg couldn't convert this file (exit code %d).%s" % [code, "\n" + last if last != "" else ""])
		return
	DirAccess.rename_absolute(ProjectSettings.globalize_path(ff.part), ProjectSettings.globalize_path(ff.out))
	_start_video(ff.out)


func _cancel_convert() -> void:
	if _ff.is_empty():
		return
	if OS.is_process_running(int(_ff.pid)):
		OS.kill(int(_ff.pid))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_ff.part))
	if _ff.remove_src:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_ff.src))
	_ff = {}


func _exit_tree() -> void:
	_cancel_convert()


## The primary button on the board: pause, carry on, or (re)load.
func toggle_video() -> void:
	match video_state:
		"playing":
			_video.paused = true
			video_state = "paused"
		"paused":
			_video.paused = false
			video_state = "playing"
		"loading", "converting":
			pass
		_:
			if video_url != "":
				play_url(video_url)


func _on_video_downloaded(result: int, code: int, headers: PackedStringArray, _body: PackedByteArray, path: String,
		url: String, from_page: bool) -> void:
	var part := path + ".part"
	if _http != null:
		_http.queue_free()
		_http = null
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part))
		var why := "The server answered HTTP %d%s." % [code, " (not found)" if code == 404 else ""]
		match result:
			HTTPRequest.RESULT_SUCCESS:
				pass
			HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
				why = "The video is over 1 GB, too big to download here."
			HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CONNECTION_ERROR:
				why = "Couldn't reach the server. Check the link and the connection."
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
				why = "The secure connection to the server failed."
			HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
				why = "The link redirects too many times."
			_:
				why = "The download failed (error %d)." % result
		_video_error(why)
		return
	var content_type := ""
	for h in headers:
		if h.to_lower().begins_with("content-type:"):
			content_type = h.substr(13).strip_edges()
	var f := FileAccess.open(part, FileAccess.READ)
	var head := f.get_buffer(4096) if f != null else PackedByteArray()
	if f != null:
		f.close()
	var kind := video_kind(head, content_type)
	if kind == "theora":
		DirAccess.rename_absolute(ProjectSettings.globalize_path(part), ProjectSettings.globalize_path(path))
		_start_video(path)
		return
	if kind == "page":
		var html := ""
		var pf := FileAccess.open(part, FileAccess.READ)
		if pf != null:
			html = pf.get_buffer(mini(pf.get_length(), 4 * 1048576)).get_string_from_utf8()
			pf.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part))
		if from_page:
			_video_error("The video link on that page led to another page, not a video.")
			return
		var found := find_page_video(html, url)
		if found == "":
			_video_error("Couldn't find a video on that page. Pages whose video appears only through scripts or a protected player can't be used: link the video file itself.")
			return
		var problem := url_problem(found)
		if problem != "":
			_video_error("The video on that page is from " + problem.get_slice(" streams", 0) + ", which streams its videos in a protected player, so the whiteboard can't play it.")
			return
		if is_stream(found):
			_convert(found, path, "The stream on that page couldn't be read.", false)
			return
		_download(found, path, true)
		return
	var src := path.get_basename() + ".src"
	DirAccess.rename_absolute(ProjectSettings.globalize_path(part), ProjectSettings.globalize_path(src))
	_convert(src, path, video_problem(head, content_type), true)


func _start_video(path: String) -> void:
	var stream := VideoStreamTheora.new()
	stream.file = path
	_video.stream = stream
	_video.paused = false
	_video.play()
	_video_fitted = false
	_video_t = 0.0
	video_state = "playing"
	video_message = ""
	_video.visible = true
	_video_back.visible = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _stop_video() -> void:
	_cancel_convert()
	if _http != null:
		_http.cancel_request()
		_http.queue_free()
		_http = null
	if _video != null:
		_video.stop()
		_video.stream = null
		_video.visible = false
	_video_back.visible = false
	_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	_dirty = true


func _video_error(message: String) -> void:
	_stop_video()
	video_state = "error"
	video_message = message
	set_card("VIDEO", "Can't play this video", "%s\n\n%s" % [message, video_url], RED)


func _video_live() -> bool:
	return _video != null and _video.visible


func _update_video(dt: float) -> void:
	if video_state == "converting" and not _ff.is_empty():
		_poll_convert()
		return
	if video_state == "loading" and _http != null:
		var total := _http.get_body_size()
		var got := _http.get_downloaded_bytes()
		var mb := "%.1f MB" % (got / 1048576.0) if total <= 0 else "%.1f of %.1f MB" % [got / 1048576.0, total / 1048576.0]
		set_card("VIDEO", "Downloading…", "%s\n\n%s" % [video_url, mb], INK, float(got) / total if total > 0 else 0.0)
		return
	if video_state != "playing" and video_state != "paused":
		return
	var tex := _video.get_video_texture()
	var size := tex.get_size() if tex != null else Vector2.ZERO
	if not _video_fitted and size.x > 0.0 and size.y > 0.0:
		# Letterbox: the whole picture, as large as the board allows, centred.
		var k := minf(TEX.x / size.x, TEX.y / size.y)
		_video.size = size * k
		_video.position = (Vector2(TEX) - size * k) / 2.0
		_video_fitted = true
	if video_state == "playing":
		_video_t += dt
		if _video_t > 3.0 and not _video_fitted:
			_video_error("The video downloaded but could not be decoded.")
			return
	# The sound fades with distance: full within 3 board heights, silent past 20.
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var d := cam.global_position.distance_to(global_transform * PANEL_CENTRE) / maxf(board_scale, 0.01)
		var loud := clampf(1.0 - (d - 3.0) / 17.0, 0.0, 1.0)
		_video.volume_db = linear_to_db(maxf(loud, 0.0001))


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
		if not _video_live():
			_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	if kind == "video":
		_update_video(dt)
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
	# The player's boards have room for bigger writing; properties run to nine lines.
	_body = _ink({"messages": 38, "properties": 42, "video": 38}.get(kind, 50), INK)
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
	if kind == "video":
		_video_back.color = Color(0.02, 0.02, 0.03)
		_video_back.size = Vector2(TEX)
		_video_back.visible = false
		_view.add_child(_video_back)
		_video = VideoStreamPlayer.new()
		_video.expand = true
		_video.loop = true
		_video.visible = false
		_view.add_child(_video)

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
