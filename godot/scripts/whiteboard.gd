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
const MAX_WIDTH_MOBILE := 854  # phones: 480p converts and plays smoothly
const MIN_SPLIT := 8.0  # seconds: shorter videos convert in one process
const BuildInfo := preload("res://scripts/build_info.gd")
## How the board names itself to web servers. Wikimedia (and others) turn away clients that don't
## say who they are and where to find out more, so: product/version (project link) engine/version.
const PROJECT_URL := "https://github.com/BarksAndBytes/FPS-CAD"
const RETRIES := 3        # a busy server (HTTP 429 / 503) is asked again up to this many times
const RETRY_MAX := 60.0   # seconds; a longer Retry-After gives up instead
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
var drawing_options := {hidden = true, dimensions = true}  # kind "drawing"
var _sheet_canvas: Control = null
var video_state := ""      # "", "ready", "loading", "copying", "converting", "playing", "paused" or "error"
var video_message := ""    # the error screen's reason
var video_title := ""      # what the library calls it: the page's title, else the file's name
var _copy := {}            # copying a file picked on Android into the videos folder: {src, dst, tmp, total, done}
var _video: VideoStreamPlayer = null
var _video_back := ColorRect.new()
var _http: HTTPRequest = null
var _video_fitted := false
var _retry_token := 0  # bumped when the board stops, so a waiting retry knows to give up
var _conv := {}            # the conversion running: src, out, part, input, phase ("probe", "single", "slices", "join")…
var _jobs: Array = []      # its FFmpeg processes: {pid, stdio, stderr, out_text, err_text, done_us, role}
static var _ffmpeg_path: Variant = null  # found once: the FFmpeg program, or "" if there is none
static var ffmpeg_note := ""  # why there is none: what was tried
static var workers_override := 0  # tests: slices at once regardless of the cores
static var last_split_problem := ""  # why the last split conversion fell back to one process
static var test_bad_join := false  # tests: make the join fail the way a build without concat does
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
	if kind == "drawing":
		d.hidden = drawing_options.hidden
		d.dimensions = drawing_options.dimensions
	return d


## Kind "drawing": shows a sheet from CadPart.drawing_sheet (millimetres, y up) on the board.
func set_sheet(sheet: Dictionary) -> void:
	if _sheet_canvas == null:
		return
	_sheet_canvas.sheet = sheet
	_sheet_canvas.queue_redraw()
	_dirty = true


class SheetCanvas extends Control:
	var sheet := {}
	var font: Font = null

	func _draw() -> void:
		if sheet.is_empty():
			return
		var w: float = sheet.width
		var h: float = sheet.height
		var k := minf((size.x - 40.0) / w, (size.y - 40.0) / h)
		var off := Vector2((size.x - w * k) / 2.0, (size.y - h * k) / 2.0)
		var to := func(p: Vector2) -> Vector2: return Vector2(off.x + p.x * k, size.y - off.y - p.y * k)
		var layers := [["border", Color("0f1a36"), 2.0], ["hidden", Color(0.06, 0.1, 0.21, 0.55), 1.0],
			["visible", Color("0f1a36"), 2.0], ["dimensions", Color("1f5fb4"), 1.0]]
		for layer in layers:
			var segs: PackedVector2Array = sheet.get(layer[0], PackedVector2Array())
			var pts := PackedVector2Array()
			for i in range(0, segs.size() - 1, 2):
				var a: Vector2 = to.call(segs[i])
				var b: Vector2 = to.call(segs[i + 1])
				if layer[0] == "hidden":
					# Dashes: 6 px on, 4 off.
					var d := a.distance_to(b)
					var t := 0.0
					while t < d:
						pts.append(a.lerp(b, t / d))
						pts.append(a.lerp(b, minf(t + 6.0, d) / d))
						t += 10.0
				else:
					pts.append(a)
					pts.append(b)
			if pts.size() >= 2:
				draw_multiline(pts, layer[1], layer[2])
		var f := font if font != null else ThemeDB.fallback_font
		for t in sheet.get("texts", []):
			var px := maxi(10, int(float(t.height) * k * 1.4))
			var p: Vector2 = to.call(t.position)
			var tw := f.get_string_size(String(t.text), HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
			draw_set_transform(p, -float(t.angle))
			draw_string(f, Vector2(-tw / 2.0, px * 0.35), String(t.text), HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color("0f1a36"))
			draw_set_transform(Vector2.ZERO)


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


## The FFmpeg program that converts videos: on Android the libffmpeg.so the APK ships in its
## native library folder (tools/build_ffmpeg.sh); on Windows ffmpeg.exe beside the game; else an
## ffmpeg on the PATH. "" when there is none.
static func ffmpeg_path() -> String:
	if _ffmpeg_path != null:
		return _ffmpeg_path
	_ffmpeg_path = ""
	if OS.has_feature("web"):
		return ""
	var candidates := []
	if OS.has_feature("android"):
		var part: Object = ClassDB.instantiate(&"CadPart") if ClassDB.class_exists(&"CadPart") else null
		var dir: String = part.native_library_dir() if part != null and part.has_method("native_library_dir") else ""
		if dir != "":
			candidates.append(dir.path_join("libffmpeg.so"))
	else:
		var exe := "ffmpeg.exe" if OS.has_feature("windows") else "ffmpeg"
		var beside := OS.get_executable_path().get_base_dir().path_join(exe)
		if FileAccess.file_exists(beside):
			candidates.append(beside)
		candidates.append(exe)
	var tried := PackedStringArray()
	for candidate in candidates:
		var out := []
		var code := OS.execute(candidate, ["-hide_banner", "-encoders"], out, true)
		if code == 0 and "libtheora" in "".join(out):
			_ffmpeg_path = candidate
			break
		var missing: bool = candidate.is_absolute_path() and not FileAccess.file_exists(candidate)
		tried.append("%s (%s)" % [candidate, "not there" if missing else "exit code %d" % code if code != 0 else "no Theora encoder"])
	ffmpeg_note = "" if _ffmpeg_path != "" else ("Looked for " + ", ".join(tried) if not tried.is_empty() else "No place to look on this platform")
	return _ffmpeg_path


## Where a link's video is kept once downloaded.
static func cached_path(url: String) -> String:
	return "%s/%s.ogv" % [VIDEO_DIR, url.strip_edges().md5_text()]


## Shows a link without playing it (a board coming back from a saved part).
func set_video(url: String) -> void:
	video_url = url.strip_edges()
	_stop_video()
	if video_url == "":
		video_state = ""
		set_card("VIDEO", "No video yet", "Aim here with the Video board tool to choose a video: a web link, one already downloaded, or a file on this device.")
	else:
		video_state = "ready"
		set_card("VIDEO", "Ready to play", video_url, INK)


## Downloads (unless kept from before) and plays the video at url.
func play_url(url: String, title := "") -> void:
	video_url = url.strip_edges()
	video_title = title
	_stop_video()
	if is_local(video_url):
		_play_local(video_url)
		return
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
func _download(url: String, path: String, from_page: bool, attempt := 0) -> void:
	DirAccess.make_dir_recursive_absolute(VIDEO_DIR)
	_http = HTTPRequest.new()
	_http.max_redirects = 8
	_http.body_size_limit = VIDEO_LIMIT
	_http.download_chunk_size = 262144
	_http.download_file = ProjectSettings.globalize_path(path + ".part")
	add_child(_http)
	_http.request_completed.connect(_on_video_downloaded.bind(path, url, from_page, attempt))
	var err := _http.request(url, ["User-Agent: " + user_agent()])
	if err != OK:
		_video_error("The download could not start (error %d)." % err)
		return
	video_state = "loading"
	set_card("VIDEO", "Downloading…", url, INK, 0.0)


## "FPS-CAD/0.2.68 (https://github.com/BarksAndBytes/FPS-CAD; whiteboard video) Godot/4.7.2-stable".
static func user_agent() -> String:
	var v: Dictionary = Engine.get_version_info()
	return "FPS-CAD/%s (%s; whiteboard video) Godot/%s" % [BuildInfo.VERSION, PROJECT_URL, v.get("string", "4")]


## How long to wait before asking a busy server again: its Retry-After (seconds) if it gave one,
## else 5, 10, 20 s. -1 when that is too long to wait, or attempts are used up.
static func retry_delay(headers: PackedStringArray, attempt: int) -> float:
	if attempt >= RETRIES:
		return -1.0
	var wait := 5.0 * pow(2.0, attempt)
	for h in headers:
		if h.to_lower().begins_with("retry-after:"):
			var v := h.substr(12).strip_edges()
			if v.is_valid_float():
				wait = maxf(1.0, v.to_float())
	return wait if wait <= RETRY_MAX else -1.0


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
			src = _best_source(m.get_string(2))
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


## The <source> to take among a <video>'s: an Ogg one plays without converting; else the tallest
## at or under 720p (480p on phones), as Wikipedia lists an original and versions from 240p up;
## else the first video source.
static func _best_source(inner: String) -> String:
	var limit := 480 if OS.has_feature("mobile") else 720
	var first := ""
	var best := ""
	var best_h := -1
	for s in RegEx.create_from_string("(?is)<source\\b[^>]*>").search_all(inner):
		var sa := _attributes(s.get_string())
		var src := String(sa.get("src", ""))
		var t := String(sa.get("type", "")).to_lower()
		if src == "" or src.begins_with("blob:") or not (t == "" or t.begins_with("video/") or "mpegurl" in t or "dash" in t):
			continue
		if t.begins_with("video/ogg") or src.to_lower().get_slice("?", 0).ends_with(".ogv"):
			return src
		if first == "":
			first = src
		var h := String(sa.get("data-height", sa.get("height", ""))).to_int()
		if h <= 0:
			var key := String(sa.get("data-transcodekey", ""))  # "720p.vp9.webm"
			h = key.get_slice("p", 0).to_int() if key.contains("p.") else 0
		if h > 0 and h <= limit and h > best_h:
			best = src
			best_h = h
	return best if best != "" else first


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
##
## libtheora encodes on one core, and encoding is nearly all the time, so a downloaded video
## longer than MIN_SPLIT seconds is cut into one slice per worker (workers()), the slices are
## encoded at once by separate FFmpeg processes (the sound by one more), and the pieces are joined
## without re-encoding. Streams and short clips convert in one process.
func _convert(src: String, out: String, why: String, remove_src: bool) -> void:
	var ff := ffmpeg_path()
	if ff == "":
		if remove_src:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(src))
		var kind_line := why.replace(CONVERT_HINT, "").strip_edges() if CONVERT_HINT in why else "That video needs converting."
		_video_error(kind_line + "\n\nConverting it needs FFmpeg, which this version of the game doesn't have (%s).\n\n%s" % [ffmpeg_note, CONVERT_HINT])
		return
	var web := src.begins_with("http://") or src.begins_with("https://")
	_conv = {src = src, out = out, part = out + ".part", remove_src = remove_src, ff = ff,
		input = src if web else ProjectSettings.globalize_path(src), duration = 0.0, audio = false,
		dir = out.get_basename() + ".parts", phase = ""}
	video_state = "converting"
	set_card("VIDEO", "Converting for the whiteboard…", video_url, INK, 0.0)
	if web or workers() < 2:
		_start_single()
	else:
		_conv.phase = "probe"
		_spawn(PackedStringArray(["-hide_banner", "-nostdin", "-i", _conv.input]), "probe")


## How many slices to encode at once: every core but one for the game; on phones, which also run
## hot, half of them. At most 8 (4 on phones).
static func workers() -> int:
	if workers_override > 0:
		return workers_override
	var n := OS.get_processor_count()
	if OS.has_feature("mobile"):
		return clampi(n / 2, 1, 4)
	return clampi(n - 1, 1, 8)


static func _scale_filter() -> String:
	return "scale=w='min(%d,iw)':h=-2" % (MAX_WIDTH_MOBILE if OS.has_feature("mobile") else MAX_WIDTH)


## The FFmpeg arguments that turn src into an Ogg Theora video at out in one go (at most MAX_WIDTH
## wide, MAX_WIDTH_MOBILE on phones).
static func convert_args(src: String, out: String) -> PackedStringArray:
	var web := PackedStringArray(["-user_agent", user_agent()]) if src.begins_with("http") else PackedStringArray()
	return web + PackedStringArray(["-hide_banner", "-nostdin", "-y", "-i", src,
		"-map", "0:v:0", "-map", "0:a:0?", "-vf", _scale_filter(),
		"-c:v", "libtheora", "-q:v", "7", "-c:a", "libvorbis", "-q:a", "4",
		"-progress", "pipe:1", "-nostats", "-f", "ogg", out])


## One slice of the picture, no sound: frames frames from start seconds (frames 0: to the end).
## Counting frames, not seconds, keeps the slices from overlapping where a cut falls between two.
static func slice_args(src: String, out: String, start: float, frames: int) -> PackedStringArray:
	var a := PackedStringArray(["-hide_banner", "-nostdin", "-y", "-ss", "%.6f" % start, "-i", src,
		"-map", "0:v:0", "-an", "-vf", _scale_filter(), "-c:v", "libtheora", "-q:v", "7"])
	if frames > 0:
		a.append_array(["-frames:v", str(frames)])
	a.append_array(["-progress", "pipe:1", "-nostats", "-f", "ogg", out])
	return a


static func audio_args(src: String, out: String) -> PackedStringArray:
	return PackedStringArray(["-hide_banner", "-nostdin", "-y", "-i", src, "-vn", "-map", "0:a:0",
		"-c:a", "libvorbis", "-q:a", "4", "-progress", "pipe:1", "-nostats", "-f", "ogg", out])


## Joins the slices (listed in list, FFmpeg's concat format) and the sound without re-encoding.
static func join_args(list: String, audio: String, out: String) -> PackedStringArray:
	var a := PackedStringArray(["-hide_banner", "-nostdin", "-y", "-f", "concat", "-safe" if not test_bad_join else "-not_an_option", "0", "-i", list])
	if audio != "":
		a.append_array(["-i", audio])
	a.append_array(["-map", "0:v"])
	if audio != "":
		a.append_array(["-map", "1:a"])
	a.append_array(["-c", "copy", "-progress", "pipe:1", "-nostats", "-f", "ogg", out])
	return a


## [start seconds, frames, seconds] for n slices of a video duration seconds long at fps frames a
## second, cut on frame boundaries; the last runs to the end (frames 0).
static func slice_plan(duration: float, n: int, fps: float) -> Array:
	var total := roundi(duration * fps)
	var per := ceili(float(total) / n)
	var plan := []
	var first := 0
	while first < total:
		var count := mini(per, total - first)
		var last := first + count >= total
		plan.append([first / fps, 0 if last else count, count / fps])
		first += count
	return plan


## What FFmpeg's log says about its input: {duration (seconds, 0 if unknown), audio}.
static func probe_info(log_text: String) -> Dictionary:
	var info := {duration = 0.0, audio = false, fps = 0.0}
	var at := log_text.find("Duration: ")
	if at >= 0:
		var hms := log_text.substr(at + 10, 11).split(":")
		if hms.size() == 3 and hms[0].is_valid_int():
			info.duration = float(hms[0]) * 3600.0 + float(hms[1]) * 60.0 + float(hms[2])
	for line in log_text.split("\n"):
		if "Stream #" in line and "Audio:" in line:
			info.audio = true
		if "Stream #" in line and "Video:" in line and info.fps <= 0.0:
			for unit in [" fps", " tbr"]:
				var m := RegEx.create_from_string("([0-9]+(?:\\.[0-9]+)?)" + unit).search(line)
				if m != null and m.get_string(1).to_float() > 0.0:
					info.fps = m.get_string(1).to_float()
					break
	return info


func _spawn(args: PackedStringArray, role: String, extra := {}) -> bool:
	var info := OS.execute_with_pipe(_conv.ff, args, false)
	if info.is_empty():
		_conv_failed("FFmpeg didn't start.")
		return false
	var job := {pid = info.pid, stdio = info.stdio, stderr = info.stderr, out_text = "", err_text = "", done_us = 0.0, role = role}
	job.merge(extra)
	_jobs.append(job)
	return true


func _start_single() -> void:
	_conv.phase = "single"
	_spawn(convert_args(_conv.input, ProjectSettings.globalize_path(_conv.part)), "single")


func _start_slices(duration: float, audio: bool, fps: float) -> void:
	_conv.phase = "slices"
	_conv.duration = duration
	_conv.audio = audio
	DirAccess.make_dir_recursive_absolute(_conv.dir)
	var list := PackedStringArray()
	var plan := slice_plan(duration, workers(), fps)
	for i in plan.size():
		var piece := ProjectSettings.globalize_path(_conv.dir.path_join("v%d.ogv" % i))
		list.append("file '%s'" % piece.replace("'", "'\\''"))
		if not _spawn(slice_args(_conv.input, piece, plan[i][0], plan[i][1]), "slice", {length = plan[i][2]}):
			return
	var f := FileAccess.open(_conv.dir.path_join("list.txt"), FileAccess.WRITE)
	f.store_string("\n".join(list) + "\n")
	f.close()
	if audio:
		_spawn(audio_args(_conv.input, ProjectSettings.globalize_path(_conv.dir.path_join("a.oga"))), "audio")


## Reads a job's progress (key=value lines on stdout) and log (stderr); true while it runs.
func _pump(job: Dictionary) -> bool:
	for pair in [["stdio", "out_text"], ["stderr", "err_text"]]:
		var fa: FileAccess = job[pair[0]]
		if fa == null:
			continue
		var chunk := fa.get_buffer(65536)
		if not chunk.is_empty():
			job[pair[1]] += chunk.get_string_from_utf8()
	var out: String = job.out_text
	var key := out.rfind("out_time_us=")
	if key < 0:
		key = out.rfind("out_time_ms=")  # older FFmpeg: also microseconds, despite the name
	if key >= 0:
		job.done_us = out.substr(key + 12, out.find("\n", key) - key - 12).to_float()
	if job.err_text.length() > 20000:
		job.err_text = job.err_text.substr(job.err_text.length() - 4000)
	if out.length() > 20000:
		job.out_text = out.substr(out.length() - 2000)
	return OS.is_process_running(int(job.pid))


static func _last_line(text: String) -> String:
	var lines := text.strip_edges().split("\n")
	return lines[lines.size() - 1].strip_edges() if not lines.is_empty() else ""


## Moves the conversion along: progress on the board, and the next step when a step's jobs end.
func _poll_convert() -> void:
	var running := false
	for job in _jobs:
		if _pump(job):
			running = true
	match _conv.phase:
		"probe":
			if running:
				return
			var info := probe_info(_jobs[0].err_text)
			_jobs.clear()
			if info.duration >= MIN_SPLIT and info.fps > 0.0:
				_start_slices(info.duration, info.audio, info.fps)
			else:
				_start_single()
		"single":
			var job: Dictionary = _jobs[0]
			if _conv.duration <= 0.0:
				_conv.duration = probe_info(job.err_text).duration
			var p: float = clampf(job.done_us / 1e6 / _conv.duration, 0.0, 1.0) if _conv.duration > 0.0 else 0.0
			set_card("VIDEO", "Converting for the whiteboard…", "%s\n\n%d%%" % [video_url, roundi(p * 100.0)], INK, p)
			if running:
				return
			var code := OS.get_process_exit_code(int(job.pid))
			var log_text: String = job.err_text
			_jobs.clear()
			_finish_convert(code, log_text)
		"slices":
			var done := 0.0
			var n := 0
			for job in _jobs:
				if job.role == "slice":
					done += minf(job.done_us / 1e6, job.length)
					n += 1
			var p := clampf(done / _conv.duration, 0.0, 1.0) * 0.98
			set_card("VIDEO", "Converting for the whiteboard…", "%s\n\n%d%%  ·  %d at once" % [video_url, roundi(p * 100.0), n], INK, p)
			if running:
				return
			for job in _jobs:
				var code := OS.get_process_exit_code(int(job.pid))
				if code != 0:
					_one_process_instead("a slice: exit code %d, %s" % [code, _last_line(job.err_text)])
					return
			_jobs.clear()
			_conv.phase = "join"
			var audio := ProjectSettings.globalize_path(_conv.dir.path_join("a.oga")) if _conv.audio else ""
			_spawn(join_args(ProjectSettings.globalize_path(_conv.dir.path_join("list.txt")), audio,
				ProjectSettings.globalize_path(_conv.part)), "join")
		"join":
			set_card("VIDEO", "Converting for the whiteboard…", "%s\n\nJoining the pieces" % video_url, INK, 0.99)
			if running:
				return
			var code := OS.get_process_exit_code(int(_jobs[0].pid))
			var log_text: String = _jobs[0].err_text
			_jobs.clear()
			if code != 0:
				_one_process_instead("joining: exit code %d, %s" % [code, _last_line(log_text)])
				return
			_finish_convert(code, log_text)


## Slicing went wrong (a slice or the join failed): convert the whole video in one process
## instead, slower but plain. Kept in last_split_problem for the record.
func _one_process_instead(problem: String) -> void:
	last_split_problem = problem
	push_warning("video board: converting in one process after a split problem (%s)" % problem)
	for job in _jobs:
		if OS.is_process_running(int(job.pid)):
			OS.kill(int(job.pid))
	_jobs.clear()
	_remove_pieces()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_conv.part))
	_start_single()


func _finish_convert(code: int, log_text: String) -> void:
	var c := _conv
	_remove_pieces()
	if c.remove_src:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(c.src))
	var f := FileAccess.open(c.part, FileAccess.READ)
	var head := f.get_buffer(4096) if f != null else PackedByteArray()
	if f != null:
		f.close()
	_conv = {}
	if code != 0 or video_kind(head) != "theora":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(c.part))
		var last := _last_line(log_text)
		_video_error("FFmpeg couldn't convert this file (exit code %d).%s" % [code, "\n" + last if last != "" else ""])
		return
	DirAccess.rename_absolute(ProjectSettings.globalize_path(c.part), ProjectSettings.globalize_path(c.out))
	_remember(c.out)
	_start_video(c.out)


func _conv_failed(message: String) -> void:
	_cancel_convert()
	_video_error(message)


func _remove_pieces() -> void:
	if _conv.is_empty() or String(_conv.get("dir", "")) == "":
		return
	var d := DirAccess.open(_conv.dir)
	if d != null:
		for f in d.get_files():
			d.remove(f)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_conv.dir))


func _cancel_convert() -> void:
	for job in _jobs:
		if OS.is_process_running(int(job.pid)):
			OS.kill(int(job.pid))
	_jobs.clear()
	if _conv.is_empty():
		return
	_remove_pieces()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_conv.part))
	if _conv.remove_src:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_conv.src))
	_conv = {}


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
		"loading", "converting", "copying":
			pass
		_:
			if video_url != "":
				play_url(video_url)


func _on_video_downloaded(result: int, code: int, headers: PackedStringArray, _body: PackedByteArray, path: String,
		url: String, from_page: bool, attempt: int) -> void:
	var part := path + ".part"
	if _http != null:
		_http.queue_free()
		_http = null
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part))
		if result == HTTPRequest.RESULT_SUCCESS and (code == 429 or code == 503):
			var wait := retry_delay(headers, attempt)
			if wait > 0.0:
				_retry_later(url, path, from_page, attempt + 1, wait)
				return
		var why := "The server answered HTTP %d%s." % [code, {404: " (not found)", 403: " (not allowed)",
			429: " (too many requests): the site limits how often apps download from it. Try again in a few minutes",
			503: " (busy). Try again in a few minutes"}.get(code, "")]
		if url != video_url:
			why += "\nThat was the video found on the page:\n" + url
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
		_remember(path)
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
		if video_title == "":
			video_title = page_title(html)
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


## Asks a busy server again after wait seconds, counting down on the board.
func _retry_later(url: String, path: String, from_page: bool, attempt: int, wait: float) -> void:
	video_state = "loading"
	var token := _retry_token
	var left := ceili(wait)
	while left > 0:
		set_card("VIDEO", "The server is busy", "%s\n\nTrying again in %d s (%d of %d)" % [url, left, attempt, RETRIES], INK)
		await get_tree().create_timer(1.0).timeout
		if token != _retry_token or not is_inside_tree():
			return  # stopped or given another link meanwhile
		left -= 1
	_download(url, path, from_page, attempt)


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
	_retry_token += 1
	_cancel_copy()
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
	if video_state == "copying" and not _copy.is_empty():
		_pump_copy()
		return
	if video_state == "converting" and not _conv.is_empty():
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


# ---------- local files and the library of downloaded videos ----------

## A file on this device rather than a web link: a path, a file:// link, or (Android) the
## content:// address the system file picker hands back.
static func is_local(link: String) -> bool:
	for scheme in ["content://", "file://", "user://", "res://"]:
		if link.begins_with(scheme):
			return true
	return link.is_absolute_path() and not link.contains("://")


## Plays a file on this device. Theora plays where it is; other videos are converted into the
## videos folder (kept like downloads). Android's picked files (content://) can only be read
## through the system, so they are copied into the videos folder first, a piece each frame.
func _play_local(link: String) -> void:
	var cached := cached_path(link)
	if FileAccess.file_exists(cached):
		_start_video(cached)
		return
	if video_title == "":
		video_title = local_name(link)
	if link.begins_with("content://"):
		_copy_in(link, cached)
		return
	var path := link.trim_prefix("file://")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_video_error("That file isn't there any more, or can't be read:\n" + path)
		return
	var head := f.get_buffer(4096)
	f.close()
	match video_kind(head):
		"theora":
			_start_video(path)
		"page":
			_video_error(video_problem(head))
		_:
			_convert(path, cached, video_problem(head), false)


## Starts copying src (a content:// address on Android) into the videos folder, to play or
## convert into out.
func _copy_in(src_path: String, out: String) -> void:
	var src := FileAccess.open(src_path, FileAccess.READ)
	if src == null:
		_video_error("Android didn't let the game read that file (error %d). Pick it again from the video menu." % FileAccess.get_open_error())
		return
	DirAccess.make_dir_recursive_absolute(VIDEO_DIR)
	var tmp := out.get_basename() + ".src"
	var dst := FileAccess.open(tmp, FileAccess.WRITE)
	if dst == null:
		_video_error("Couldn't make room for the video in the game's storage.")
		return
	_copy = {src = src, dst = dst, tmp = tmp, total = src.get_length(), done = 0, out = out}
	video_state = "copying"
	set_card("VIDEO", "Copying from this device…", video_title, INK, 0.0)


## Copies 8 MB a frame, then plays or converts the copy.
func _pump_copy() -> void:
	var src: FileAccess = _copy.src
	var dst: FileAccess = _copy.dst
	var chunk := src.get_buffer(8 * 1048576)
	if not chunk.is_empty():
		dst.store_buffer(chunk)
		_copy.done += chunk.size()
	var total: int = _copy.total
	var p := float(_copy.done) / total if total > 0 else 0.0
	set_card("VIDEO", "Copying from this device…", "%s\n\n%d%%" % [video_title, roundi(p * 100.0)], INK, p)
	if not chunk.is_empty() and not src.eof_reached():
		return
	src.close()
	dst.close()
	var c := _copy
	_copy = {}
	var f := FileAccess.open(c.tmp, FileAccess.READ)
	var head := f.get_buffer(4096) if f != null else PackedByteArray()
	if f != null:
		f.close()
	match video_kind(head):
		"theora":
			DirAccess.rename_absolute(ProjectSettings.globalize_path(c.tmp), ProjectSettings.globalize_path(c.out))
			_remember(c.out)
			_start_video(c.out)
		"page":
			DirAccess.remove_absolute(ProjectSettings.globalize_path(c.tmp))
			_video_error(video_problem(head))
		_:
			_convert(c.tmp, c.out, video_problem(head), true)


func _cancel_copy() -> void:
	if _copy.is_empty():
		return
	_copy.src.close()
	_copy.dst.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_copy.tmp))
	_copy = {}


## A readable name for a local file: its file name (decoded from a content:// address).
static func local_name(link: String) -> String:
	var last := link.uri_decode().replace("\\", "/").get_file()
	last = last.get_slice(":", last.get_slice_count(":") - 1)  # "primary:Movies/clip.mp4" → after the volume
	last = last.get_file()
	return last if last.contains(".") else "Video from this device"  # media ids ("video:1234") say nothing


## The <title> of a web page, tidied, or "".
static func page_title(html: String) -> String:
	var m := RegEx.create_from_string("(?is)<title[^>]*>(.*?)</title>").search(html)
	return _unescape(m.get_string(1)).replace("\n", " ").strip_edges() if m != null else ""


const LIBRARY := VIDEO_DIR + "/library.json"


## Notes a newly kept video in the library: where it came from, what it is called, when.
func _remember(path: String) -> void:
	var index := _library_index()
	var title := video_title
	if title == "":
		title = local_name(video_url) if is_local(video_url) else video_url.get_slice("?", 0).get_file().uri_decode()
	if title == "":
		title = video_url
	var f := FileAccess.open(path, FileAccess.READ)
	index[path.get_file()] = {link = video_url, title = title, added = Time.get_unix_time_from_system(),
		bytes = f.get_length() if f != null else 0}
	_save_library_index(index)


static func _library_index() -> Dictionary:
	var text := FileAccess.get_file_as_string(LIBRARY)
	var data: Variant = JSON.parse_string(text) if text != "" else {}
	return data if data is Dictionary else {}


static func _save_library_index(index: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(VIDEO_DIR)
	var f := FileAccess.open(LIBRARY, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(index, "\t"))


## The downloaded and converted videos kept on this device, newest first:
## [{path, link, title, bytes, added}]. Videos kept before the library existed are listed too.
static func library() -> Array:
	var index := _library_index()
	var out := []
	var d := DirAccess.open(VIDEO_DIR)
	if d == null:
		return out
	for name in d.get_files():
		if not name.ends_with(".ogv"):
			continue
		var path := VIDEO_DIR.path_join(name)
		var e: Dictionary = index.get(name, {})
		var f := FileAccess.open(path, FileAccess.READ)
		out.append({path = path, link = String(e.get("link", "")), title = String(e.get("title", "Downloaded video %s" % name.substr(0, 6))),
			bytes = f.get_length() if f != null else int(e.get("bytes", 0)),
			added = float(e.get("added", FileAccess.get_modified_time(path)))})
	out.sort_custom(func(a, b): return a.added > b.added)
	return out


## Deletes a kept video and its library entry.
static func forget_video(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var index := _library_index()
	index.erase(path.get_file())
	_save_library_index(index)


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
	if kind == "drawing":
		_sheet_canvas = SheetCanvas.new()
		_sheet_canvas.font = UiTheme.body_font
		_sheet_canvas.size = Vector2(TEX)
		_view.add_child(_sheet_canvas)
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
