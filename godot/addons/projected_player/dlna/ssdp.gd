extends RefCounted

## SSDP, UPnP's discovery: one socket for every ProjectedDlnaRenderer in this program, since UDP
## port 1900 can only be bound once. It answers phones' searches (M-SEARCH) and announces the
## renderers (NOTIFY ssdp:alive, and ssdp:byebye when one stops).
##
## If another program already holds port 1900 (on Windows the "SSDP Discovery" service may),
## searches can't be answered, so the renderers are announced every FALLBACK_INTERVAL seconds
## instead; phone apps that listen for announcements still find them.

const GROUP := "239.255.255.250"
const MAX_AGE := 1800
const ANNOUNCE_INTERVAL := 300.0
const FALLBACK_INTERVAL := 15.0
const SERVER := "Godot/4 UPnP/1.0 ProjectedPlayer/1.0"

## The SSDP port. Only tests change it (before the first renderer starts).
static var port := 1900
static var _shared: RefCounted

var listening := false
var _socket: PacketPeerUDP  # bound to the SSDP port: receives searches, sends everything
var _sender: PacketPeerUDP  # used when the port couldn't be bound
var _renderers: Array = []
var _replies: Array = []  # [due msec, ip, port, text]
var _next_announce := 0.0
var _polled_frame := -1


static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://addons/projected_player/dlna/ssdp.gd").new()
	return _shared


func add(renderer: Node) -> void:
	if renderer in _renderers:
		return
	if _renderers.is_empty():
		_open()
	_renderers.append(renderer)
	_announce(renderer, "ssdp:alive")
	_next_announce = minf(_next_announce, _now() + 1.0)  # once more soon: UDP can drop it


func remove(renderer: Node) -> void:
	if not renderer in _renderers:
		return
	_announce(renderer, "ssdp:byebye")
	_renderers.erase(renderer)
	_replies = _replies.filter(func(r: Array) -> bool: return r[4] != renderer)
	if _renderers.is_empty():
		_close()


## Called by each renderer every frame; does its work once a frame.
func poll() -> void:
	var frame := Engine.get_process_frames()
	if frame == _polled_frame:
		return
	_polled_frame = frame
	if _socket != null:
		while _socket.get_available_packet_count() > 0:
			var data := _socket.get_packet()
			_on_packet(data.get_string_from_utf8(), _socket.get_packet_ip(), _socket.get_packet_port())
	var now := Time.get_ticks_msec()
	var keep: Array = []
	for reply in _replies:
		if reply[0] <= now:
			_send(reply[1], reply[2], reply[3])
		else:
			keep.append(reply)
	_replies = keep
	if _now() >= _next_announce:
		_next_announce = _now() + (ANNOUNCE_INTERVAL if listening else FALLBACK_INTERVAL)
		for renderer in _renderers:
			_announce(renderer, "ssdp:alive")


## The IPv4 addresses of this device, loopback last.
static func local_addresses() -> PackedStringArray:
	var found := PackedStringArray()
	for iface in IP.get_local_interfaces():
		for address in iface.addresses:
			if address.is_valid_ip_address() and not ":" in address and not address.begins_with("127.") and not address in found:
				found.append(address)
	found.append("127.0.0.1")
	return found


## The address of this device that the device at peer most likely reaches (most leading bits in
## common).
static func address_for(peer: String) -> String:
	if peer.begins_with("127."):
		return "127.0.0.1"
	var best := ""
	var best_bits := -1
	for address in local_addresses():
		var bits := _common_bits(address, peer)
		if bits > best_bits:
			best = address
			best_bits = bits
	return best


static func _common_bits(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	if pa.size() != 4 or pb.size() != 4:
		return 0
	var bits := 0
	for i in 4:
		var x := int(pa[i]) ^ int(pb[i])
		if x == 0:
			bits += 8
			continue
		var n := 7
		while n >= 0 and (x >> n) & 1 == 0:
			bits += 1
			n -= 1
		break
	return bits


static func http_date() -> String:
	var t := Time.get_datetime_dict_from_system(true)
	var days := ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s, %02d %s %d %02d:%02d:%02d GMT" % [days[t.weekday], t.day, months[t.month - 1], t.year, t.hour, t.minute, t.second]


func _open() -> void:
	_socket = PacketPeerUDP.new()
	listening = _socket.bind(port, "0.0.0.0") == OK
	if not listening:
		push_warning("ProjectedDlnaRenderer: UDP port %d is in use by another program, so phones can't search for this renderer; it will announce itself every %d seconds instead." % [port, FALLBACK_INTERVAL])
		_socket = null
		_sender = PacketPeerUDP.new()
		return
	var joined := 0
	for iface in IP.get_local_interfaces():
		for address in iface.addresses:
			if address.is_valid_ip_address() and not ":" in address:
				if _socket.join_multicast_group(GROUP, iface.name) == OK:
					joined += 1
				break
	if joined == 0:
		push_warning("ProjectedDlnaRenderer: couldn't join the SSDP multicast group on any network.")
	_next_announce = 0.0


func _close() -> void:
	if _socket != null:
		_socket.close()
	if _sender != null:
		_sender.close()
	_socket = null
	_sender = null
	listening = false
	_replies.clear()


func _send(ip: String, to_port: int, text: String) -> void:
	var sock := _socket if _socket != null else _sender
	if sock == null:
		return
	sock.set_dest_address(ip, to_port)
	sock.put_packet(text.to_utf8_buffer())


func _announce(renderer: Node, nts: String) -> void:
	for address in local_addresses():
		if address.begins_with("127.") and local_addresses().size() > 1:
			continue
		for target in renderer.ssdp_targets():
			var lines := ["NOTIFY * HTTP/1.1", "HOST: %s:%d" % [GROUP, port], "NT: " + target[0], "NTS: " + nts, "USN: " + target[1]]
			if nts == "ssdp:alive":
				lines.append_array(["CACHE-CONTROL: max-age=%d" % MAX_AGE, "LOCATION: " + renderer.description_url(address), "SERVER: " + SERVER])
			_send(GROUP, port, "\r\n".join(lines) + "\r\n\r\n")


func _on_packet(text: String, ip: String, from_port: int) -> void:
	if not text.begins_with("M-SEARCH "):
		return
	var headers := {}
	for line in text.split("\r\n"):
		var kv := line.split(":", true, 1)
		if kv.size() == 2:
			headers[kv[0].strip_edges().to_upper()] = kv[1].strip_edges()
	if headers.get("MAN", "").replace("\"", "") != "ssdp:discover":
		return
	var st: String = headers.get("ST", "")
	var mx := clampi(int(headers.get("MX", "1")), 0, 5)
	var address := address_for(ip)
	for renderer in _renderers:
		for target in renderer.ssdp_targets():
			if st == "ssdp:all" or st == target[0]:
				var reply := "\r\n".join([
					"HTTP/1.1 200 OK",
					"CACHE-CONTROL: max-age=%d" % MAX_AGE,
					"DATE: " + http_date(),
					"EXT:",
					"LOCATION: " + renderer.description_url(address),
					"SERVER: " + SERVER,
					"ST: " + target[0],
					"USN: " + target[1],
				]) + "\r\n\r\n"
				# Spread replies over part of MX so a busy network isn't hit at once.
				var delay := randi_range(0, mini(mx, 1) * 400)
				_replies.append([Time.get_ticks_msec() + delay, ip, from_port, reply, renderer])


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
