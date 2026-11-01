extends Node
## Keeps published Android builds up to date from inside the app.
##
## Checking is the app's only network use: one download of a small public file (latest.json from
## the repository's android-dev release). Nothing about the player or their files is sent, and the
## launch check can be turned off from the pause menu.
##
## Installing downloads the newer APK into the app's own storage, checks its size and SHA-256
## against latest.json, and hands it to Android's package installer (OS.shell_open shares the file
## through Godot's FileProvider). Every published build is signed with the same key and has a
## higher version code, so Android offers it as an update and keeps the player's files. The app
## declares REQUEST_INSTALL_PACKAGES; the first time, Android asks the player to allow installs
## from FPS-CAD.

signal update_available(info: Dictionary)
signal checked(message: String)       # result of a check, for a toast
signal before_install                 # save work: the installer replaces the running app

const BuildInfo := preload("res://scripts/build_info.gd")
const UiTheme := preload("res://scripts/ui_theme.gd")
const LATEST_URL := "https://github.com/BarksAndBytes/FPS-CAD/releases/download/android-dev/latest.json"
const SETTINGS := "user://settings.cfg"
const DOWNLOADS := "user://updates"

var latest := {}  # the newest build's latest.json, once found
var _check_http: HTTPRequest
var _apk_http: HTTPRequest
var _manual := false
var _apk_path := ""

var _layer := CanvasLayer.new()
var _panel := PanelContainer.new()
var _title: Label
var _body: Label
var _bar := ProgressBar.new()
var _primary := Button.new()
var _secondary := Button.new()
var _state := ""  # "", "downloading", "ready", "failed"


func _ready() -> void:
	_check_http = HTTPRequest.new()
	_check_http.timeout = 15.0
	_check_http.max_redirects = 8  # GitHub serves release files through a redirect
	add_child(_check_http)
	_check_http.request_completed.connect(_on_checked)
	_apk_http = HTTPRequest.new()
	_apk_http.max_redirects = 8
	_apk_http.download_chunk_size = 262144
	add_child(_apk_http)
	_apk_http.request_completed.connect(_on_downloaded)
	_build_ui()
	_clean_old_downloads()


# ---------- settings ----------

## Builds that can update this way: published Android builds (local builds are build 0).
static func supported() -> bool:
	return OS.has_feature("android") and BuildInfo.BUILD > 0


static func enabled() -> bool:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	return bool(cfg.get_value("updates", "auto_check", true))


static func set_enabled(on: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("updates", "auto_check", on)
	cfg.save(SETTINGS)


static func version_text() -> String:
	if BuildInfo.BUILD <= 0:
		return "development build"
	return "build %d (%s)" % [BuildInfo.BUILD, BuildInfo.COMMIT]


func busy() -> bool:
	return _layer.visible


# ---------- checking ----------

func check_on_launch() -> void:
	if supported() and enabled():
		check(false)


## manual: report the result even when there is nothing new (pause menu "Check for updates").
func check(manual: bool) -> void:
	_manual = manual
	if not supported():
		if manual:
			checked.emit("Updates come with the Android builds from GitHub; this is a %s" % version_text())
		return
	_check_http.cancel_request()
	var err := _check_http.request(LATEST_URL, ["Accept: application/json", "Cache-Control: no-cache"])
	if err != OK and manual:
		checked.emit("Could not check for updates (error %d)" % err)


func _on_checked(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		if _manual:
			checked.emit("Could not reach GitHub to check for updates")
		return
	var info: Variant = JSON.parse_string(body.get_string_from_utf8())
	var r := evaluate(info, BuildInfo.BUILD)
	if r.newer:
		latest = info
		update_available.emit(info)
	if _manual or r.newer:
		checked.emit(r.message)


## Pure decision, separate from the network so it can be tested: is info (latest.json) an update
## for build? Returns {newer: bool, message: String}.
static func evaluate(info: Variant, build: int) -> Dictionary:
	if not (info is Dictionary) or not info.has("build") or not info.has("apk"):
		return {newer = false, message = "The update information was not readable"}
	var remote := int(info.build)
	if remote <= build:
		return {newer = false, message = "You have the latest build (%d)" % build}
	if String(info.get("signing", "release")) != "release":
		return {newer = false, message = "Build %d is out but is not signed for updates; install it from GitHub by hand" % remote}
	return {newer = true, message = "Update available: build %d" % remote}


# ---------- installing ----------

## Downloads the newer build, verifies it and opens Android's installer.
func install() -> void:
	if latest.is_empty() or _state == "downloading":
		return
	DirAccess.make_dir_recursive_absolute(DOWNLOADS)
	_apk_path = "%s/FPS-CAD-%d.apk" % [DOWNLOADS, int(latest.build)]
	if FileAccess.file_exists(_apk_path) and verify(_apk_path, latest) == "":
		_show("ready")
		_launch_installer()
		return
	_apk_http.cancel_request()
	_apk_http.download_file = ProjectSettings.globalize_path(_apk_path)
	var err := _apk_http.request(String(latest.apk))
	if err != OK:
		_fail("The download could not start (error %d)." % err)
		return
	_show("downloading")


func cancel() -> void:
	_apk_http.cancel_request()
	_state = ""
	_layer.visible = false
	if _apk_path != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_apk_path))


func _process(_dt: float) -> void:
	if _state != "downloading":
		return
	var total := _apk_http.get_body_size()
	var got := _apk_http.get_downloaded_bytes()
	if total <= 0:
		total = int(latest.get("size", 0))
	_bar.value = 100.0 * got / total if total > 0 else 0.0
	_body.text = "Downloading build %d · %.1f of %.1f MB" % [int(latest.build), got / 1048576.0, maxf(total, got) / 1048576.0]
	if Actions.last_device == "controller" and _layer.visible:
		UiTheme.keep_focus(_panel, _secondary)


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body_bytes: PackedByteArray) -> void:
	if _state != "downloading":
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail("The download did not finish (%s). Check the connection and try again." % (
			"HTTP %d" % code if result == HTTPRequest.RESULT_SUCCESS else "error %d" % result))
		return
	var problem := verify(_apk_path, latest)
	if problem != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_apk_path))
		_fail(problem)
		return
	_show("ready")
	_launch_installer()


## "" when the file at path matches latest.json's size and SHA-256, else what is wrong.
static func verify(path: String, info: Dictionary) -> String:
	if not FileAccess.file_exists(path):
		return "The download is missing."
	var f := FileAccess.open(path, FileAccess.READ)
	var length := f.get_length() if f != null else 0
	if info.has("size") and length != int(info.size):
		return "The download is the wrong size (%d of %d bytes). Try again." % [length, int(info.size)]
	if info.has("sha256") and FileAccess.get_sha256(path) != String(info.sha256):
		return "The download is damaged (checksum mismatch). Try again."
	if length < 1024:
		return "The download is not an app package."
	return ""


func _launch_installer() -> void:
	before_install.emit()
	var err := OS.shell_open(ProjectSettings.globalize_path(_apk_path))
	if err != OK:
		_fail("Android's installer did not open (error %d)." % err)


func _clean_old_downloads() -> void:
	var dir := DirAccess.open(DOWNLOADS)
	if dir == null:
		return
	for f in dir.get_files():
		if f.ends_with(".apk"):
			dir.remove(f)


# ---------- the update panel ----------

func _build_ui() -> void:
	_layer.layer = 40
	_layer.visible = false
	add_child(_layer)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.05, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(dim)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(centre)
	centre.add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(460, 0)
	_panel.add_child(col)
	_title = UiTheme.title("UPDATE", 24, UiTheme.ACCENT)
	col.add_child(_title)
	_body = UiTheme.text("", 16)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_body)
	_bar.custom_minimum_size = Vector2(0, 18)
	_bar.show_percentage = false
	col.add_child(_bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	for b in [_secondary, _primary]:
		b.custom_minimum_size = Vector2(0, 48)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	_primary.pressed.connect(_on_primary)
	_secondary.pressed.connect(_on_secondary)


func _show(state: String) -> void:
	_state = state
	_layer.visible = true
	_title.text = "UPDATE TO BUILD %d" % int(latest.get("build", 0))
	_bar.visible = state == "downloading"
	match state:
		"downloading":
			_body.text = "Downloading…"
			_primary.visible = false
			_secondary.text = "Cancel"
			_secondary.grab_focus.call_deferred()
		"ready":
			_body.text = ("Android's installer is opening: choose Update. Your files stay as they are.\n\n"
				+ "The first time, Android asks you to allow installs from FPS-CAD: turn it on, then come back.")
			_primary.visible = true
			_primary.text = "Open installer again"
			_secondary.text = "Close"
			_primary.grab_focus.call_deferred()
		"failed":
			_primary.visible = true
			_primary.text = "Try again"
			_secondary.text = "Download in browser"
			_primary.grab_focus.call_deferred()


func _fail(message: String) -> void:
	_show("failed")
	_body.text = message


func _on_primary() -> void:
	match _state:
		"ready":
			_launch_installer()
		"failed":
			install()


func _on_secondary() -> void:
	match _state:
		"downloading":
			cancel()
		"ready":
			_state = ""
			_layer.visible = false
		"failed":
			if latest.has("apk"):
				OS.shell_open(String(latest.apk))
			_state = ""
			_layer.visible = false


func _input(event: InputEvent) -> void:
	if not _layer.visible:
		return
	if event.is_action_pressed(&"ui_cancel"):
		_on_secondary()
		get_viewport().set_input_as_handled()
