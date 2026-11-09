class_name ProjectedDlnaRenderer
extends Node

## Makes a ProjectedScreen show up as a TV (a DLNA / UPnP MediaRenderer) in phone apps that cast
## to DLNA TVs, such as BubbleUPnP, Web Video Caster and many gallery and media-server apps.
##
## The app sends a link to the video (often served by the phone itself). FFmpeg converts it to
## Ogg Theora in the background, the screen plays it, and the app's play, pause, stop, seek and
## volume controls work. While it converts, the app shows the TV as loading (TRANSITIONING).
## Converted videos are kept in cache_dir (the last CACHE_KEEP), so casting one again is quick.
##
## Several renderers can run at once (one per whiteboard, say): each gets its own port and name.
##
## A screen whose plays_links() is true (one that downloads and converts links itself) gets the
## link as is, with no FFmpeg here; its "loading" and "error" states are passed on to the phone.
##
## Security: DLNA has no passwords. Anyone on the same network can cast to a running renderer,
## and the renderer will download whatever http(s) link it is sent. Start one only on networks
## you trust, and stop it when it isn't wanted.

## A phone chose a video (before it is converted). title is from the app, and may be "".
signal cast_received(uri: String, title: String)
## Converting the cast video: 0 to 1, when its length is known.
signal converting(fraction: float)
## The cast video can't be played; reason says why, for showing on the screen.
signal cast_failed(reason: String)

const Ssdp := preload("res://addons/projected_player/dlna/ssdp.gd")
const Upnp := preload("res://addons/projected_player/dlna/upnp_services.gd")

const MAX_REQUEST_BYTES := 262144
const REQUEST_TIMEOUT_MS := 10000
const SUBSCRIPTION_SECONDS := 1800
const EVENT_INTERVAL := 0.2
const NOTIFY_TIMEOUT_MS := 5000
const CACHE_KEEP := 5
const NO_COUNT := "2147483647"

@export var screen: ProjectedScreen
## The name phones list it under.
@export var friendly_name := "Projected Player"
## TCP port for the description, commands and events. 0 picks a free one: phones learn the port
## from discovery, so it needn't be fixed (unless a firewall needs it to be).
@export var http_port := 0
## The FFmpeg program. Empty: ffmpeg beside this program, else on the PATH. It must have the
## libtheora encoder. On Android, pass the path of an FFmpeg the app ships.
@export var ffmpeg_path := ""
@export var cache_dir := "user://projected_player/cast"
## The renderer's identity. Empty: made from this device, friendly_name and the node's path, so
## it stays the same between runs and phones remember it.
@export var uuid := ""
@export var auto_start := true

var _server: TCPServer
var _port := 0
var _udn := ""
var _clients: Array = []
var _uri := ""
var _metadata := ""
var _title := ""
var _status := "OK"
var _error := ""
var _converter: FfmpegConverter
var _last_fraction := -1.0
var _ready_path := ""  # the converted video for _uri, once there is one
var _loaded := ""  # what this renderer last loaded into the screen
var _want_play := false
var _pending_seek := -1.0
var _duration := 0.0
var _volume := 100
var _mute := false
var _subs := {}  # SID → {service, urls, expires, seq, initial}
var _sent := {}  # service → the evented values last sent
var _event_timer := 0.0
var _outbox: Array = []
var _ffmpeg := ""
var _ffmpeg_checked := false


func _ready() -> void:
	if auto_start:
		start()


func start() -> void:
	if _server != null:
		return
	if screen == null:
		push_error("ProjectedDlnaRenderer: assign a ProjectedScreen before starting.")
		return
	_server = TCPServer.new()
	var err := _server.listen(http_port, "*")
	if err != OK:
		push_error("ProjectedDlnaRenderer: cannot listen on port %d (error %d)." % [http_port, err])
		_server = null
		return
	_port = _server.get_local_port()
	_udn = "uuid:" + (uuid if uuid != "" else derived_uuid(OS.get_unique_id() + "|" + friendly_name + "|" + str(get_path())))
	Ssdp.shared().add(self)
	print("ProjectedDlnaRenderer '%s' on HTTP %d (%s)" % [friendly_name, _port, _udn])


func stop() -> void:
	if _server == null:
		return
	Ssdp.shared().remove(self)
	for client in _clients:
		(client.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	for job in _outbox:
		if job.peer != null:
			(job.peer as StreamPeerTCP).disconnect_from_host()
	_outbox.clear()
	_subs.clear()
	_server.stop()
	_server = null
	if _converter != null:
		_converter.cancel()
		_converter = null


func _exit_tree() -> void:
	stop()


## The TCP port in use (http_port, or the one picked when it is 0).
func get_port() -> int:
	return _port


func get_udn() -> String:
	return _udn


## The DLNA state: NO_MEDIA_PRESENT, STOPPED, TRANSITIONING (converting), PLAYING or
## PAUSED_PLAYBACK.
func get_transport_state() -> String:
	if _uri == "":
		return "NO_MEDIA_PRESENT"
	if _want_play:
		return "TRANSITIONING"
	if _is_ours():
		match screen.get_state_name():
			"loading":
				return "TRANSITIONING"
			"playing":
				return "PLAYING"
			"paused":
				return "PAUSED_PLAYBACK"
	return "STOPPED"


func get_title() -> String:
	return _title


## Why the last cast failed, or "".
func get_last_error() -> String:
	return _error


## [notification type, unique service name] pairs for discovery.
func ssdp_targets() -> Array:
	var targets := [["upnp:rootdevice", _udn + "::upnp:rootdevice"], [_udn, _udn], [Upnp.DEVICE_TYPE, _udn + "::" + Upnp.DEVICE_TYPE]]
	for short in Upnp.SERVICES:
		var type: String = Upnp.SERVICES[short][0]
		targets.append([type, _udn + "::" + type])
	return targets


func description_url(address: String) -> String:
	return "http://%s:%d/dlna/device.xml" % [address, _port]


func _process(delta: float) -> void:
	if _server == null:
		return
	Ssdp.shared().poll()
	while _server.is_connection_available():
		_clients.append({peer = _server.take_connection(), buffer = PackedByteArray(), started = Time.get_ticks_msec(), done = false, continued = false})
	var alive: Array = []
	for client in _clients:
		_service_client(client)
		if not client.done:
			alive.append(client)
	_clients = alive
	_poll_conversion()
	_watch_link_screen()
	_event_timer -= delta
	if _event_timer <= 0.0:
		_event_timer = EVENT_INTERVAL
		_expire_subscriptions()
		_send_changes()
	_pump_outbox()


# --- HTTP ---------------------------------------------------------------------------------

func _service_client(client: Dictionary) -> void:
	var peer: StreamPeerTCP = client.peer
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		client.done = true
		return
	var available := peer.get_available_bytes()
	if available > 0:
		var got := peer.get_data(available)
		if got[0] == OK:
			var buffer: PackedByteArray = client.buffer
			buffer.append_array(got[1])
			client.buffer = buffer
	if (client.buffer as PackedByteArray).size() > MAX_REQUEST_BYTES:
		_reply(client, _http(413, {}, ""))
		return
	var req := parse_request(client.buffer)
	if req.is_empty():
		if Time.get_ticks_msec() - int(client.started) > REQUEST_TIMEOUT_MS:
			_reply(client, _http(408, {}, ""))
		return
	if req.get("waiting", false):
		if req.get("expect_continue", false) and not client.continued:
			client.continued = true
			peer.put_data("HTTP/1.1 100 Continue\r\n\r\n".to_utf8_buffer())
		if Time.get_ticks_msec() - int(client.started) > REQUEST_TIMEOUT_MS:
			_reply(client, _http(408, {}, ""))
		return
	_reply(client, _handle(req))


func _reply(client: Dictionary, response: PackedByteArray) -> void:
	var peer: StreamPeerTCP = client.peer
	peer.put_data(response)
	peer.disconnect_from_host()
	client.done = true


## Parses an HTTP request: {} while the headers are incomplete, {waiting = true} while the body
## is, else {method, path, headers (lower-case names), body}. {bad = true} if malformed.
static func parse_request(buf: PackedByteArray) -> Dictionary:
	var header_end := -1
	for i in range(buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			header_end = i
			break
	if header_end < 0:
		return {}
	var lines := buf.slice(0, header_end).get_string_from_utf8().split("\r\n")
	var first := lines[0].split(" ")
	if first.size() < 2:
		return {bad = true}
	var headers := {}
	for i in range(1, lines.size()):
		var kv := lines[i].split(":", true, 1)
		if kv.size() == 2:
			headers[kv[0].strip_edges().to_lower()] = kv[1].strip_edges()
	var rest := buf.slice(header_end + 4)
	var body := PackedByteArray()
	if headers.get("transfer-encoding", "").to_lower() == "chunked":
		var at := 0
		while true:
			var line_end := -1
			for i in range(at, rest.size() - 1):
				if rest[i] == 13 and rest[i + 1] == 10:
					line_end = i
					break
			if line_end < 0:
				return {waiting = true}
			var size := rest.slice(at, line_end).get_string_from_ascii().get_slice(";", 0).strip_edges().hex_to_int()
			if size == 0:
				break
			if rest.size() < line_end + 2 + size + 2:
				return {waiting = true}
			body.append_array(rest.slice(line_end + 2, line_end + 2 + size))
			at = line_end + 2 + size + 2
	else:
		var length := maxi(0, headers.get("content-length", "0").to_int())
		if rest.size() < length:
			return {waiting = true, expect_continue = headers.get("expect", "").to_lower() == "100-continue"}
		body = rest.slice(0, length)
	return {method = first[0].to_upper(), path = first[1].get_slice("?", 0), headers = headers, body = body.get_string_from_utf8()}


func _handle(req: Dictionary) -> PackedByteArray:
	if req.get("bad", false):
		return _http(400, {}, "")
	var parts: PackedStringArray = req.path.trim_prefix("/").split("/")
	if parts.size() < 2 or parts[0] != "dlna":
		return _http(404, {}, "")
	var xml := {"Content-Type": "text/xml; charset=\"utf-8\""}
	var head: bool = req.method == "HEAD"
	if parts.size() == 2 and (req.method == "GET" or head):
		if parts[1] == "device.xml":
			return _http(200, xml, Upnp.device_xml(friendly_name, _udn), head)
		var short := parts[1].trim_suffix(".xml")
		if parts[1].ends_with(".xml") and Upnp.SERVICES.has(short):
			return _http(200, xml, Upnp.scpd_xml(short), head)
		return _http(404, {}, "")
	if parts.size() == 3 and Upnp.SERVICES.has(parts[1]):
		match [req.method, parts[2]]:
			["POST", "control"]:
				return _soap(parts[1], req)
			["SUBSCRIBE", "event"]:
				return _subscribe(parts[1], req.headers)
			["UNSUBSCRIBE", "event"]:
				return _unsubscribe(parts[1], req.headers)
		return _http(405, {}, "")
	return _http(404, {}, "")


const _REASONS := {200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout",
	412: "Precondition Failed", 413: "Payload Too Large", 500: "Internal Server Error"}


func _http(code: int, headers: Dictionary, body: String, head_only := false) -> PackedByteArray:
	var bytes := body.to_utf8_buffer()
	var text := "HTTP/1.1 %d %s\r\n" % [code, _REASONS.get(code, "OK")]
	var all := {"Server": Ssdp.SERVER, "Date": Ssdp.http_date(), "Content-Length": str(bytes.size()), "Connection": "close"}
	all.merge(headers, true)
	for name in all:
		text += "%s: %s\r\n" % [name, all[name]]
	var out := (text + "\r\n").to_utf8_buffer()
	if not head_only:
		out.append_array(bytes)
	return out


# --- Commands (SOAP) ----------------------------------------------------------------------

## The action and its arguments from a SOAP request: {action, args}, or {} if it isn't one.
static func parse_soap(body: String) -> Dictionary:
	var p := XMLParser.new()
	if body.strip_edges() == "" or p.open_buffer(body.to_utf8_buffer()) != OK:
		return {}
	var depth := 0
	var body_depth := -1
	var action := ""
	var action_depth := -1
	var args := {}
	var current := ""
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				depth += 1
				var name := p.get_node_name().get_slice(":", p.get_node_name().count(":"))
				if body_depth < 0 and name == "Body":
					body_depth = depth
				elif body_depth > 0 and action == "" and depth == body_depth + 1:
					action = name
					action_depth = depth
				elif action != "" and depth == action_depth + 1:
					current = name
					args[name] = ""
				if p.is_empty():
					if depth == action_depth + 1:
						current = ""
					depth -= 1
			XMLParser.NODE_TEXT:
				if current != "":
					args[current] += p.get_node_data()
			XMLParser.NODE_CDATA:
				if current != "":
					args[current] += p.get_node_name()
			XMLParser.NODE_ELEMENT_END:
				if depth == action_depth + 1:
					current = ""
				depth -= 1
	return {action = action, args = args} if action != "" else {}


func _soap(short: String, req: Dictionary) -> PackedByteArray:
	var soap := parse_soap(req.body)
	if soap.is_empty():
		return _fault(short, "", 401, "Invalid Action")
	var action: String = soap.action
	if not Upnp.ACTIONS[short].has(action):
		return _fault(short, action, 401, "Invalid Action")
	var args: Dictionary = soap.args
	if args.has("InstanceID") and args.InstanceID.strip_edges() != "0":
		return _fault(short, action, 718, "Invalid InstanceID")
	var result: Variant = _run(short, action, args)
	_event_timer = 0.0  # tell subscribers about any change at once
	if result is Array:  # [error code, description]
		return _fault(short, action, result[0], result[1])
	var out := ""
	for a in Upnp.ACTIONS[short][action]:
		if a[1] == "out":
			out += "<%s>%s</%s>" % [a[0], str(result.get(a[0], "")).xml_escape(), a[0]]
	var type: String = Upnp.SERVICES[short][0]
	var body := ('<?xml version="1.0" encoding="utf-8"?>\n<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
		+ '<u:%sResponse xmlns:u="%s">%s</u:%sResponse></s:Body></s:Envelope>' % [action, type, out, action])
	return _http(200, {"Content-Type": "text/xml; charset=\"utf-8\"", "EXT": ""}, body)


func _fault(_short: String, _action: String, code: int, description: String) -> PackedByteArray:
	var body := ('<?xml version="1.0" encoding="utf-8"?>\n<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
		+ '<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>'
		+ '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>%d</errorCode><errorDescription>%s</errorDescription></UPnPError>' % [code, description.xml_escape()]
		+ '</detail></s:Fault></s:Body></s:Envelope>')
	return _http(500, {"Content-Type": "text/xml; charset=\"utf-8\"", "EXT": ""}, body)


## Runs an action: its out arguments, or [error code, description].
func _run(short: String, action: String, args: Dictionary) -> Variant:
	match short + "." + action:
		"AVTransport.SetAVTransportURI":
			return _set_uri(str(args.get("CurrentURI", "")).strip_edges(), str(args.get("CurrentURIMetaData", "")))
		"AVTransport.Play":
			return _play()
		"AVTransport.Pause":
			var now := get_transport_state()
			if now == "PLAYING":
				screen.pause()
			elif _want_play:
				_want_play = false
			elif now != "PAUSED_PLAYBACK" and now != "TRANSITIONING":
				return [701, "Transition not available: nothing is playing"]
			return {}
		"AVTransport.Stop":
			if _is_ours() and screen.get_state_name() != "idle":
				screen.stop()
			_want_play = false
			_pending_seek = -1.0
			return {}
		"AVTransport.Seek":
			var unit := str(args.get("Unit", "")).strip_edges()
			if unit != "REL_TIME" and unit != "ABS_TIME":
				return [710, "Seek mode not supported: use REL_TIME"]
			var target := parse_time(str(args.get("Target", "")))
			if target < 0.0:
				return [711, "Illegal seek target"]
			if _uri == "":
				return [701, "Transition not available: nothing to seek"]
			if _is_ours() and screen.can_seek():
				screen.seek(target)
			else:
				_pending_seek = target
			return {}
		"AVTransport.Next", "AVTransport.Previous":
			return [701, "Transition not available: one video at a time"]
		"AVTransport.GetTransportInfo":
			return {CurrentTransportState = get_transport_state(), CurrentTransportStatus = _status, CurrentSpeed = "1"}
		"AVTransport.GetPositionInfo":
			return {Track = "1" if _uri != "" else "0", TrackDuration = format_time(_current_duration()), TrackMetaData = _metadata,
				TrackURI = _uri, RelTime = format_time(_position()), AbsTime = format_time(_position()), RelCount = NO_COUNT, AbsCount = NO_COUNT}
		"AVTransport.GetMediaInfo":
			return {NrTracks = "1" if _uri != "" else "0", MediaDuration = format_time(_current_duration()), CurrentURI = _uri,
				CurrentURIMetaData = _metadata, NextURI = "", NextURIMetaData = "", PlayMedium = "NETWORK" if _uri != "" else "NONE",
				RecordMedium = "NOT_IMPLEMENTED", WriteStatus = "NOT_IMPLEMENTED"}
		"AVTransport.GetDeviceCapabilities":
			return {PlayMedia = "NETWORK", RecMedia = "NOT_IMPLEMENTED", RecQualityModes = "NOT_IMPLEMENTED"}
		"AVTransport.GetTransportSettings":
			return {PlayMode = "NORMAL", RecQualityMode = "NOT_IMPLEMENTED"}
		"AVTransport.GetCurrentTransportActions":
			return {Actions = _actions()}
		"RenderingControl.GetVolume":
			return {CurrentVolume = str(_volume)}
		"RenderingControl.SetVolume":
			var v := str(args.get("DesiredVolume", "")).strip_edges()
			if not v.is_valid_int() or int(v) < 0 or int(v) > 100:
				return [402, "Invalid Args: volume is 0 to 100"]
			_volume = int(v)
			_apply_volume()
			return {}
		"RenderingControl.GetMute":
			return {CurrentMute = "1" if _mute else "0"}
		"RenderingControl.SetMute":
			_mute = str(args.get("DesiredMute", "")).strip_edges().to_lower() in ["1", "true", "yes"]
			_apply_volume()
			return {}
		"RenderingControl.ListPresets":
			return {CurrentPresetNameList = "FactoryDefaults"}
		"RenderingControl.SelectPreset":
			if str(args.get("PresetName", "")).strip_edges() != "FactoryDefaults":
				return [701, "Invalid Name"]
			_volume = 100
			_mute = false
			_apply_volume()
			return {}
		"ConnectionManager.GetProtocolInfo":
			return {Source = "", Sink = Upnp.sink_protocol_info()}
		"ConnectionManager.GetCurrentConnectionIDs":
			return {ConnectionIDs = "0"}
		"ConnectionManager.GetCurrentConnectionInfo":
			if str(args.get("ConnectionID", "")).strip_edges() != "0":
				return [706, "Invalid connection reference"]
			return {RcsID = "0", AVTransportID = "0", ProtocolInfo = "", PeerConnectionManager = "", PeerConnectionID = "-1",
				Direction = "Input", Status = "OK"}
	return [401, "Invalid Action"]


func _set_uri(uri: String, metadata: String) -> Variant:
	if uri != "" and not (uri.begins_with("http://") or uri.begins_with("https://")):
		return [716, "Resource not found: only http and https links can play"]
	if uri != "" and not _links() and _find_ffmpeg() == "":
		return [714, "Can't convert videos: FFmpeg (with Theora) wasn't found on this device"]
	if _is_ours() and screen.get_state_name() != "idle":
		screen.stop()
	if _converter != null:
		_converter.cancel()
		_converter = null
	_uri = uri
	_metadata = metadata
	_title = didl_title(metadata)
	_status = "OK"
	_error = ""
	_want_play = false
	_pending_seek = -1.0
	_ready_path = ""
	_loaded = ""
	_duration = 0.0
	if uri == "":
		return {}
	cast_received.emit(uri, _title)
	if _links():
		return {}
	var out := cache_path(uri)
	if FileAccess.file_exists(out) and TheoraBackend.theora_problem(out) == "":
		_ready_path = out
	else:
		_start_conversion()
	return {}


func _play() -> Variant:
	if _uri == "":
		return [701, "Transition not available: no video chosen"]
	_status = "OK"
	_error = ""
	if _links():
		if _is_ours():
			match screen.get_state_name():
				"paused":
					screen.resume()
					return {}
				"playing", "loading":
					return {}
		if not screen.load_source(_uri):
			_fail(screen.get_last_error())
			return {}
		_loaded = _uri
		_event_timer = 0.0
		screen.play()
		_apply_volume()
		return {}
	if _ready_path == "":
		_want_play = true
		if _converter == null:
			_start_conversion()
		return {}
	if _is_ours():
		match screen.get_state_name():
			"paused":
				screen.resume()
				return {}
			"playing":
				return {}
	_start_playback()
	return {}


func _start_playback() -> void:
	_want_play = false
	if not screen.load_source(_ready_path):
		_fail(screen.get_last_error())
		return
	_loaded = _ready_path
	_event_timer = 0.0
	screen.play()
	_apply_volume()
	_duration = screen.get_duration()
	if _pending_seek >= 0.0 and screen.can_seek():
		screen.seek(_pending_seek)
	_pending_seek = -1.0


## Whether the screen plays links itself (see ProjectedScreen.plays_links()).
func _links() -> bool:
	return screen.plays_links()


## For a screen that plays links: passes its failures to the phone, and applies a seek that came
## while it was loading.
func _watch_link_screen() -> void:
	if not _links() or not _is_ours():
		return
	match screen.get_state_name():
		"error":
			if _status == "OK":
				_fail(screen.get_last_error())
		"playing", "paused":
			if _pending_seek >= 0.0 and screen.can_seek():
				screen.seek(_pending_seek)
				_pending_seek = -1.0
				_event_timer = 0.0


func _is_ours() -> bool:
	return _loaded != "" and screen.get_source() == _loaded


func _position() -> float:
	if _is_ours() and screen.get_state_name() in ["playing", "paused"]:
		return screen.get_playback_position()
	return maxf(_pending_seek, 0.0)


func _current_duration() -> float:
	if _is_ours():
		return screen.get_duration()
	if _converter != null and _converter.duration > 0.0:
		return _converter.duration
	return _duration


func _actions() -> String:
	match get_transport_state():
		"PLAYING":
			return "Pause,Stop,Seek"
		"PAUSED_PLAYBACK":
			return "Play,Stop,Seek"
		"STOPPED":
			return "Play,Seek"
		"TRANSITIONING":
			return "Stop"
	return ""


func _apply_volume() -> void:
	if _is_ours():
		screen.set_volume(0.0 if _mute else _volume / 100.0)


## H:MM:SS, as DLNA writes times.
static func format_time(seconds: float) -> String:
	var s := maxi(0, int(seconds))
	return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]


## Seconds from H+:MM:SS[.F+] or H+:MM:SS[.F0/F1], or -1 if it isn't one.
static func parse_time(text: String) -> float:
	var parts := text.strip_edges().split(":")
	if parts.size() != 3 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1.0
	var sec := parts[2]
	var frac := 0.0
	if "." in sec:
		var f := sec.get_slice(".", 1)
		sec = sec.get_slice(".", 0)
		if "/" in f:
			var den := f.get_slice("/", 1).to_float()
			frac = f.get_slice("/", 0).to_float() / den if den > 0.0 else 0.0
		elif f.is_valid_int():
			frac = ("0." + f).to_float()
		else:
			return -1.0
	if not sec.is_valid_int() or int(parts[1]) > 59 or int(sec) > 59 or int(parts[0]) < 0:
		return -1.0
	return int(parts[0]) * 3600.0 + int(parts[1]) * 60.0 + int(sec) + frac


## The title in DIDL-Lite metadata (the dc:title element), or "".
static func didl_title(didl: String) -> String:
	if didl.strip_edges() == "":
		return ""
	var p := XMLParser.new()
	if p.open_buffer(didl.to_utf8_buffer()) != OK:
		return ""
	var in_title := false
	var title := ""
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				in_title = p.get_node_name().get_slice(":", p.get_node_name().count(":")) == "title" and not p.is_empty()
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if in_title:
					title += p.get_node_data() if p.get_node_type() == XMLParser.NODE_TEXT else p.get_node_name()
			XMLParser.NODE_ELEMENT_END:
				if in_title:
					return title.strip_edges()
	return title.strip_edges()


## A UUID made from seed (the same seed, the same UUID).
static func derived_uuid(seed: String) -> String:
	var h := seed.md5_text()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]


# --- Converting ---------------------------------------------------------------------------

func cache_path(uri: String) -> String:
	return cache_dir.path_join(uri.md5_text() + ".ogv")


func _find_ffmpeg() -> String:
	if not _ffmpeg_checked:
		_ffmpeg = FfmpegConverter.find_ffmpeg(ffmpeg_path)
		_ffmpeg_checked = true
	return _ffmpeg


func _start_conversion() -> void:
	_prune_cache()
	_converter = FfmpegConverter.new()
	_last_fraction = -1.0
	if not _converter.start(_find_ffmpeg(), _uri, ProjectSettings.globalize_path(cache_path(_uri))):
		var reason := _converter.error
		_converter = null
		_fail(reason)


func _poll_conversion() -> void:
	if _converter == null:
		return
	var result := _converter.poll()
	if result == FfmpegConverter.RUNNING:
		var fraction := _converter.progress()
		if absf(fraction - _last_fraction) >= 0.01:
			_last_fraction = fraction
			converting.emit(fraction)
		return
	var conv := _converter
	_converter = null
	if result == FfmpegConverter.DONE:
		_duration = conv.duration
		_ready_path = cache_path(_uri)
		converting.emit(1.0)
		if _want_play:
			_start_playback()
	else:
		_fail(conv.error)


func _fail(reason: String) -> void:
	_event_timer = 0.0
	_status = "ERROR_OCCURRED"
	_error = reason
	_want_play = false
	push_warning("ProjectedDlnaRenderer: " + reason)
	cast_failed.emit(reason)


## Keeps the newest CACHE_KEEP - 1 converted videos, making room for one more.
func _prune_cache() -> void:
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		DirAccess.make_dir_recursive_absolute(cache_dir)
		return
	var files: Array = []
	for name in dir.get_files():
		var path := cache_dir.path_join(name)
		if name.ends_with(".part"):
			DirAccess.remove_absolute(path)
		elif name.ends_with(".ogv") and path != _loaded:
			files.append([FileAccess.get_modified_time(path), path])
	files.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for i in range(CACHE_KEEP - 1, files.size()):
		DirAccess.remove_absolute(files[i][1])


# --- Events (GENA) ------------------------------------------------------------------------

func _subscribe(short: String, headers: Dictionary) -> PackedByteArray:
	var seconds := subscription_seconds(headers.get("timeout", ""))
	if headers.has("sid"):
		if headers.has("callback") or headers.has("nt"):
			return _http(400, {}, "")
		var sid: String = headers.sid
		if not _subs.has(sid) or _subs[sid].service != short:
			return _http(412, {}, "")
		_subs[sid].expires = Time.get_ticks_msec() + seconds * 1000
		return _http(200, {"SID": sid, "TIMEOUT": "Second-%d" % seconds}, "")
	if headers.get("nt", "") != "upnp:event":
		return _http(412, {}, "")
	var urls := PackedStringArray()
	for piece: String in str(headers.get("callback", "")).split("<", false):
		var url := piece.get_slice(">", 0).strip_edges()
		if url.begins_with("http://"):
			urls.append(url)
	if urls.is_empty():
		return _http(412, {}, "")
	var sid := "uuid:" + derived_uuid(Crypto.new().generate_random_bytes(16).hex_encode())
	_subs[sid] = {service = short, urls = urls, expires = Time.get_ticks_msec() + seconds * 1000, seq = 0, initial = true}
	_event_timer = 0.0  # send the first event soon
	return _http(200, {"SID": sid, "TIMEOUT": "Second-%d" % seconds}, "")


func _unsubscribe(short: String, headers: Dictionary) -> PackedByteArray:
	var sid: String = headers.get("sid", "")
	if sid == "" or not _subs.has(sid) or _subs[sid].service != short:
		return _http(412, {}, "")
	_subs.erase(sid)
	return _http(200, {}, "")


## The subscription length to grant for a TIMEOUT header (Second-N or infinite).
static func subscription_seconds(timeout: String) -> int:
	var t := timeout.strip_edges().to_lower()
	if t.begins_with("second-") and t.substr(7).is_valid_int():
		return clampi(int(t.substr(7)), 60, SUBSCRIPTION_SECONDS)
	return SUBSCRIPTION_SECONDS


func _expire_subscriptions() -> void:
	var now := Time.get_ticks_msec()
	for sid in _subs.keys():
		if int(_subs[sid].expires) < now:
			_subs.erase(sid)


func _evented() -> Dictionary:
	var duration := format_time(_current_duration())
	return {
		"AVTransport": {
			"TransportState": get_transport_state(), "TransportStatus": _status, "TransportPlaySpeed": "1",
			"CurrentPlayMode": "NORMAL", "NumberOfTracks": "1" if _uri != "" else "0", "CurrentTrack": "1" if _uri != "" else "0",
			"CurrentTrackDuration": duration, "CurrentMediaDuration": duration, "CurrentTrackURI": _uri, "AVTransportURI": _uri,
			"CurrentTrackMetaData": _metadata, "AVTransportURIMetaData": _metadata, "NextAVTransportURI": "",
			"NextAVTransportURIMetaData": "", "PlaybackStorageMedium": "NETWORK" if _uri != "" else "NONE",
			"CurrentTransportActions": _actions(),
		},
		"RenderingControl": {"Volume": str(_volume), "Mute": "1" if _mute else "0", "PresetNameList": "FactoryDefaults"},
		"ConnectionManager": {"SourceProtocolInfo": "", "SinkProtocolInfo": Upnp.sink_protocol_info(), "CurrentConnectionIDs": "0"},
	}


## Sends subscribers what changed since last time (and new subscribers everything).
func _send_changes() -> void:
	var now := _evented()
	for short in now:
		var old: Dictionary = _sent.get(short, {})
		var changed := {}
		for key in now[short]:
			if old.get(key) != now[short][key]:
				changed[key] = now[short][key]
		_sent[short] = now[short]
		for sid in _subs:
			var sub: Dictionary = _subs[sid]
			if sub.service != short:
				continue
			var values: Dictionary = now[short] if sub.initial else changed
			if values.is_empty():
				continue
			sub.initial = false
			_notify(sid, sub, event_body(short, values))


## The NOTIFY body for changed values: LastChange for AVTransport and RenderingControl, plain
## properties for ConnectionManager.
static func event_body(short: String, values: Dictionary) -> String:
	var props := ""
	if short == "ConnectionManager":
		for key in values:
			props += "<e:property><%s>%s</%s></e:property>" % [key, str(values[key]).xml_escape(), key]
	else:
		var ns := "urn:schemas-upnp-org:metadata-1-0/%s/" % ("AVT" if short == "AVTransport" else "RCS")
		var inner := '<Event xmlns="%s"><InstanceID val="0">' % ns
		for key in values:
			var channel := ' channel="Master"' if key in ["Volume", "Mute"] else ""
			inner += '<%s%s val="%s"/>' % [key, channel, str(values[key]).xml_escape(true)]
		inner += "</InstanceID></Event>"
		props = "<e:property><LastChange>%s</LastChange></e:property>" % inner.xml_escape()
	return '<?xml version="1.0" encoding="utf-8"?>\n<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">%s</e:propertyset>' % props


func _notify(sid: String, sub: Dictionary, body: String) -> void:
	var url: String = sub.urls[0]
	var rest := url.trim_prefix("http://")
	var hostport := rest.get_slice("/", 0)
	var path := rest.substr(hostport.length())
	if path == "":
		path = "/"
	var host := hostport.get_slice(":", 0)
	var port := int(hostport.get_slice(":", 1)) if ":" in hostport else 80
	var bytes := body.to_utf8_buffer()
	var head := "NOTIFY %s HTTP/1.1\r\nHOST: %s\r\nCONTENT-TYPE: text/xml; charset=\"utf-8\"\r\nNT: upnp:event\r\nNTS: upnp:propchange\r\nSID: %s\r\nSEQ: %d\r\nCONTENT-LENGTH: %d\r\nCONNECTION: close\r\n\r\n" % [
		path, hostport, sid, sub.seq, bytes.size()]
	sub.seq = 1 if sub.seq >= 4294967295 else sub.seq + 1
	var data := head.to_utf8_buffer()
	data.append_array(bytes)
	_outbox.append({sid = sid, host = host, port = port, data = data, peer = null, started = 0, sent = false})


## Delivers queued events. Each subscriber's events go one at a time, in order, so a phone never
## sees an older state after a newer one.
func _pump_outbox() -> void:
	var keep: Array = []
	var now := Time.get_ticks_msec()
	var busy := {}
	for job in _outbox:
		if job.peer == null:
			if busy.has(job.sid):
				keep.append(job)
				continue
			var fresh := StreamPeerTCP.new()
			if fresh.connect_to_host(job.host, job.port) != OK:
				continue
			job.peer = fresh
			job.started = now
		busy[job.sid] = true
		var peer: StreamPeerTCP = job.peer
		peer.poll()
		var status := peer.get_status()
		var finished := status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE or now - int(job.started) > NOTIFY_TIMEOUT_MS
		if not finished and status == StreamPeerTCP.STATUS_CONNECTED:
			if not job.sent:
				peer.put_data(job.data)
				job.sent = true
			elif peer.get_available_bytes() > 0:
				peer.get_data(peer.get_available_bytes())
				finished = true
		if finished:
			peer.disconnect_from_host()
		else:
			keep.append(job)
	_outbox = keep
