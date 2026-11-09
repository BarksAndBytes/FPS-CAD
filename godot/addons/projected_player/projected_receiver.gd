class_name ProjectedReceiver
extends Node

## Makes a ProjectedScreen discoverable on the local network and controllable
## over HTTP. It broadcasts a UDP beacon for discovery and serves a small JSON
## API for play, pause, resume, stop, and seek. See docs/PROTOCOL.md.
##
## Security: set auth_token to require "Authorization: Bearer <token>" on every
## request except OPTIONS. With it empty, anyone on the network can control the receiver.

const PROTOCOL_VERSION := 1
const BEACON_INTERVAL := 2.0
const REQUEST_TIMEOUT_MS := 5000
const MAX_REQUEST_BYTES := 65536
const REASONS := {
	200: "OK",
	202: "Accepted",
	204: "No Content",
	400: "Bad Request",
	401: "Unauthorized",
	403: "Forbidden",
	404: "Not Found",
	408: "Request Timeout",
	413: "Payload Too Large",
	422: "Unprocessable Entity",
}

@export var screen: ProjectedScreen
@export var receiver_name := "Projected Player"
@export var http_port := 8765
@export var beacon_port := 47800
## Local files may only be played from inside this absolute folder.
## Empty means local playback is refused.
@export var media_root := ""
## Shared secret for the HTTP API. Empty disables authentication.
@export var auth_token := ""
@export var auto_start := true

var _server: TCPServer
var _beacon: PacketPeerUDP
var _beacon_timer := 0.0
var _clients: Array[Dictionary] = []


func _ready() -> void:
	if auto_start:
		start()


func start() -> void:
	if _server != null:
		return
	if screen == null:
		push_error("ProjectedReceiver: assign a ProjectedScreen before starting.")
		return

	_server = TCPServer.new()
	var err := _server.listen(http_port, "*")
	if err != OK:
		push_error("ProjectedReceiver: cannot listen on port %d (error %d)." % [http_port, err])
		_server = null
		return

	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_beacon.set_dest_address("255.255.255.255", beacon_port)
	print("ProjectedReceiver '%s' listening on HTTP %d, beacon on UDP %d" % [receiver_name, http_port, beacon_port])


func stop() -> void:
	for client in _clients:
		(client.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	if _server != null:
		_server.stop()
		_server = null
	if _beacon != null:
		_beacon.close()
		_beacon = null


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	if _server == null:
		return

	_beacon_timer -= delta
	if _beacon_timer <= 0.0:
		_beacon_timer = BEACON_INTERVAL
		_send_beacon()

	while _server.is_connection_available():
		_clients.append({
			"peer": _server.take_connection(),
			"buffer": PackedByteArray(),
			"started": Time.get_ticks_msec(),
			"done": false,
		})

	var alive: Array[Dictionary] = []
	for client in _clients:
		_service_client(client)
		if not client.done:
			alive.append(client)
	_clients = alive


func _send_beacon() -> void:
	var message := {
		"app": "projected_player",
		"v": PROTOCOL_VERSION,
		"name": receiver_name,
		"http_port": http_port,
	}
	_beacon.put_packet(JSON.stringify(message).to_utf8_buffer())


func _service_client(client: Dictionary) -> void:
	var peer: StreamPeerTCP = client.peer
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		client.done = true
		return

	var available := peer.get_available_bytes()
	if available > 0:
		var result := peer.get_data(available)
		if result[0] == OK:
			var buffer: PackedByteArray = client.buffer
			buffer.append_array(result[1])
			client.buffer = buffer

	if (client.buffer as PackedByteArray).size() > MAX_REQUEST_BYTES:
		_write(client, _response(413, {"error": "request too large"}))
		return

	var request := _parse_request(client.buffer)
	if request.is_empty():
		if Time.get_ticks_msec() - int(client.started) > REQUEST_TIMEOUT_MS:
			_write(client, _response(408, {"error": "request timeout"}))
		return

	_write(client, _handle_request(request))


func _write(client: Dictionary, response: String) -> void:
	var peer: StreamPeerTCP = client.peer
	peer.put_data(response.to_utf8_buffer())
	peer.disconnect_from_host()
	client.done = true


## Returns {} while the request is incomplete, otherwise method, path, and body.
func _parse_request(buf: PackedByteArray) -> Dictionary:
	var header_end := _find_header_end(buf)
	if header_end < 0:
		return {}

	var lines := buf.slice(0, header_end).get_string_from_utf8().split("\r\n")
	var first := lines[0].split(" ")
	if first.size() < 2:
		return {"bad": true}

	var headers := {}
	for i in range(1, lines.size()):
		var parts := lines[i].split(":", true, 1)
		if parts.size() == 2:
			headers[parts[0].strip_edges().to_lower()] = parts[1].strip_edges()

	var content_length := maxi(0, int(headers.get("content-length", "0").to_int()))
	var body_start := header_end + 4
	if buf.size() < body_start + content_length:
		return {}

	return {
		"method": first[0],
		"path": first[1].get_slice("?", 0),
		"headers": headers,
		"body": buf.slice(body_start, body_start + content_length).get_string_from_utf8(),
	}


func _find_header_end(buf: PackedByteArray) -> int:
	for i in range(buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


func _handle_request(req: Dictionary) -> String:
	if req.get("bad", false):
		return _response(400, {"error": "malformed request"})
	if req.method == "OPTIONS":
		return _response(204, {})
	if not _authorized(req):
		return _response(401, {"error": "missing or invalid token"})

	var body := _json_body(req.body)
	match req.method + " " + req.path:
		"GET /info":
			return _response(200, _info())
		"GET /status":
			return _response(200, _status())
		"POST /play":
			return _cmd_play(body)
		"POST /pause":
			screen.pause()
			return _response(200, _status())
		"POST /resume":
			screen.resume()
			return _response(200, _status())
		"POST /stop":
			screen.stop()
			return _response(200, _status())
		"POST /seek":
			var position = body.get("position")
			if not (position is float or position is int) or float(position) < 0.0:
				return _response(400, {"error": "'position' must be a number of seconds, 0 or more"})
			if not screen.can_seek():
				return _response(422, {"error": "nothing to seek: play something first" if screen.get_state_name() == "idle"
					else "seek is not supported by this backend"})
			screen.seek(float(position))
			return _response(200, _status())
		_:
			return _response(404, {"error": "unknown endpoint"})


func _cmd_play(body: Dictionary) -> String:
	var source := str(body.get("source", ""))
	if source.is_empty():
		return _response(400, {"error": "missing 'source'"})
	if not _source_allowed(source):
		return _response(403, {"error": "source is outside media_root"})
	if not screen.load_source(source):
		var reason := screen.get_last_error()
		return _response(422, {"error": reason if reason != "" else "unsupported source for this backend"})
	screen.play()
	return _response(202, _status())


## Compares normalized paths. Backslashes become slashes so Windows paths match,
## and ".." segments are resolved before the prefix check.
func _source_allowed(source: String) -> bool:
	if media_root.is_empty():
		return false
	var clean := source.replace("\\", "/").simplify_path()
	var root := media_root.replace("\\", "/").simplify_path()
	if not root.ends_with("/"):
		root += "/"
	if OS.has_feature("windows"):  # Windows paths ignore case
		return clean.to_lower().begins_with(root.to_lower())
	return clean.begins_with(root)


func _authorized(req: Dictionary) -> bool:
	if auth_token.is_empty():
		return true
	var headers: Dictionary = req.get("headers", {})
	return headers.get("authorization", "") == "Bearer " + auth_token


func _info() -> Dictionary:
	return {"app": "projected_player", "v": PROTOCOL_VERSION, "name": receiver_name}


func _status() -> Dictionary:
	return {
		"name": receiver_name,
		"state": screen.get_state_name(),
		"source": screen.get_source(),
		"position": screen.get_playback_position(),
		"duration": screen.get_duration(),
	}


func _json_body(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _response(code: int, data: Dictionary) -> String:
	var body := "" if code == 204 else JSON.stringify(data)
	return "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nConnection: close\r\n\r\n%s" % [
		code,
		REASONS.get(code, "OK"),
		body.to_utf8_buffer().size(),
		body,
	]
