extends Node
## Checks for a newer Android build. This is the app's only network request: one download of a
## small public file (latest.json from the repository's android-dev release). Nothing about the
## player or their files is sent, and it can be turned off from the pause menu.
##
## A newer build downloads through the phone's browser; tapping it then installs over this one as
## an update (every published build is signed with the same key), keeping the player's files.

signal update_available(info: Dictionary)
signal checked(message: String)  # the result of a check, for a toast after "Check now"

const BuildInfo := preload("res://scripts/build_info.gd")
const LATEST_URL := "https://github.com/BarksAndBytes/FPS-CAD/releases/download/android-dev/latest.json"
const SETTINGS := "user://settings.cfg"

var latest := {}  # the newest build's latest.json, once found
var _http: HTTPRequest
var _manual := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	_http.max_redirects = 8  # GitHub serves release files through a redirect
	add_child(_http)
	_http.request_completed.connect(_on_completed)


## Builds that can be updated this way: published Android builds (local builds are build 0).
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


## Called at launch: checks quietly when the setting allows it.
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
	_http.cancel_request()
	var err := _http.request(LATEST_URL, ["Accept: application/json", "Cache-Control: no-cache"])
	if err != OK and manual:
		checked.emit("Could not check for updates (error %d)" % err)


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
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


## Pure decision, separate from the download so it can be tested: is info (latest.json) newer
## than build? Returns {newer: bool, message: String}.
static func evaluate(info: Variant, build: int) -> Dictionary:
	if not (info is Dictionary) or not info.has("build") or not info.has("apk"):
		return {newer = false, message = "The update information was not readable"}
	var remote := int(info.build)
	if remote <= build:
		return {newer = false, message = "You have the latest build (%d)" % build}
	if String(info.get("signing", "release")) != "release":
		return {newer = false, message = "Build %d is out but is not signed for updates; install it from GitHub by hand" % remote}
	return {newer = true, message = "Update available: build %d" % remote}


## Opens the newer build's APK in the browser, which downloads it; tapping the download installs it.
func download() -> void:
	if latest.has("apk"):
		OS.shell_open(String(latest.apk))
