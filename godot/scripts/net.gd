extends Node
## Multiplayer on the local network, with no server: one player's game hosts the part and up to
## three others on the same Wi-Fi join it. Everyone walks around the same part and can change it.
##
## Finding games: a hosting game broadcasts a small UDP beacon (BEACON_PORT) every second; the
## Multiplayer page of the pause menu lists the games it hears. Playing: ENet (Godot's
## ENetMultiplayerPeer) on PORT, the host in the middle (it relays what the guests send each other).
##
## The part: the host's game keeps the official copy and a version number. Every player's game
## checks its part a few times a second (CadPart.state_text): a host's own change goes out to
## everyone as the next version; a guest's goes to the host as a proposal, made from the version
## it last had. When nobody else changed the part since, the host takes it as it is; otherwise it
## merges the two changes item by item (CadPart.merge_states: what only one side changed is kept;
## when both changed the same feature, the host's copy wins and the guest is told). The part's
## text is only ever made and read by the C++ side, so numbers keep their types (Godot's JSON
## would turn whole numbers into decimals). Imported shapes are sent only when they change. Undo and redo on a guest ask the host, so there is one history:
## undo takes back the latest change, whoever made it.
##
## While a player is in a sketch or a feature dialog, changes from others wait until they finish,
## and theirs goes out when they do. Assemblies aren't shared yet: their parts are files on each
## device.
##
## Players: each game sends its player's pose (feet, look, size, aim) ten times a second, unreliable,
## and shows the others as avatars (avatar.gd).

signal changed  # players came or went, a game was found or lost, hosting started or stopped

const Avatar := preload("res://scripts/avatar.gd")
const BuildInfo := preload("res://scripts/build_info.gd")

const PORT := 47820  # ENet; the next three are tried if it's taken
const BEACON_PORT := 47821
const MAX_PLAYERS := 4
const PROTOCOL := 1
const CHECK_EVERY := 0.25  # seconds between looks for changes to the part
const POSE_EVERY := 0.1
const BEACON_EVERY := 1.0
const SESSION_GONE := 4.0  # a game not heard from for this long leaves the list
const HISTORY := 64  # versions the host keeps to merge late proposals against
const COLORS := [Color("e8a33d"), Color("4fa3e0"), Color("6cc070"), Color("d0617a")]

var game: Node  # main.gd
var role := ""  # "", "host", "joining" or "guest"
var my_name := default_name()
var players := {}  # peer id → {name, color (index into COLORS)}
var sessions := {}  # "ip:port" → {ip, port, host, part, players, seen (msec)}
var version := 0  # the shared part's version (the host's count)
var merges := 0  # changes the host combined with others' (for the tests)
var port := 0  # the ENet port in use

# Host
var _history := {}  # version → the part's state text then
var _authors := {}  # version → who made it (peer id)
var _queue: Array = []  # proposals waiting while the host is in a sketch or dialog
# Guest
var _base_version := 0
var _base_text := ""  # the state at _base_version
var _in_flight := ""  # the state proposed and not yet answered ("" when none)
var _held := {}  # the newest version from the host, held while in a sketch or dialog
var _pending_imports := {}  # imported shapes that arrived while a proposal was out
# Both
var _known := ""  # the state everyone has agreed on, as far as this game knows
var _imports_sig := ""
var _check_t := 0.0
var _pose_t := 0.0
var _beacon_t := 0.0
var _peer: ENetMultiplayerPeer
var _beacon: PacketPeerUDP
var _listen: PacketPeerUDP
var _avatars := {}  # peer id → avatar.gd


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)


func _exit_tree() -> void:
	stop(false)
	listen_for_games(false)


## This player's name for the others: the device's model on Android, the user name elsewhere.
static func default_name() -> String:
	var n := ""
	if OS.has_feature("android"):
		n = OS.get_model_name()
	else:
		n = OS.get_environment("USERNAME" if OS.has_feature("windows") else "USER")
	n = n.strip_edges()
	return n.substr(0, 24) if n != "" else "Player"


func is_guest() -> bool:
	return role == "guest"


func in_game() -> bool:
	return role == "host" or role == "guest"


## Why this part can't be hosted now, or "".
func host_problem() -> String:
	if game.doc == null or game.state != "play":
		return "Open a part first"
	if game.is_assembly:
		return "Multiplayer shares parts for now: an assembly's parts are files on this device"
	if not game.mode in ["free", "new"]:
		return "Finish the training or challenge first"
	if role != "":
		return "Already in a multiplayer game"
	return ""


## Hosts the open part. Returns why it couldn't, or "".
func host() -> String:
	var problem := host_problem()
	if problem != "":
		return problem
	_peer = ENetMultiplayerPeer.new()
	var err := ERR_CANT_CREATE
	for p in range(PORT, PORT + 4):
		err = _peer.create_server(p, MAX_PLAYERS - 1)
		if err == OK:
			port = p
			break
	if err != OK:
		_peer = null
		return "Couldn't open a network port for the game (error %d)" % err
	multiplayer.multiplayer_peer = _peer
	role = "host"
	version = 1
	_known = _state()
	_imports_sig = game.doc.imports_signature()
	_history = {1: _known}
	_authors = {1: 1}
	_queue.clear()
	players = {1: {name = my_name, color = 0}}
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_beacon.set_dest_address("255.255.255.255", BEACON_PORT)
	_beacon_t = 0.0
	changed.emit()
	return ""


## Joins the game found as key in sessions.
func join(key: String) -> void:
	var s: Dictionary = sessions.get(key, {})
	if s.is_empty():
		return
	join_address(String(s.ip), int(s.port))


func join_address(ip: String, at_port: int) -> void:
	if role != "":
		return
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(ip, at_port)
	if err != OK:
		_peer = null
		_toast("Couldn't start joining (error %d)" % err)
		return
	multiplayer.multiplayer_peer = _peer
	port = at_port
	role = "joining"
	changed.emit()


## Leaves the game (a host ends it for everyone). Everyone keeps the part as it is.
func stop(tell := true) -> void:
	if role == "":
		return
	var was := role
	if _peer != null:
		_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null
	if _beacon != null:
		_beacon.close()
		_beacon = null
	role = ""
	players.clear()
	_history.clear()
	_authors.clear()
	_queue.clear()
	_held = {}
	_in_flight = ""
	_pending_imports = {}
	for id in _avatars:
		_avatars[id].queue_free()
	_avatars.clear()
	if tell and was != "joining":
		_toast("Stopped hosting: the part stays here" if was == "host" else "Left the multiplayer game: the part stays here, save it to keep it")
	changed.emit()


## Listens for games' beacons (while the Multiplayer page is open).
func listen_for_games(on: bool) -> void:
	if on and _listen == null:
		_listen = PacketPeerUDP.new()
		_listen.set_broadcast_enabled(true)  # on Android this also lets broadcasts through Wi-Fi
		if _listen.bind(BEACON_PORT, "0.0.0.0") != OK:
			_listen = null
	elif not on and _listen != null:
		_listen.close()
		_listen = null
		if not sessions.is_empty():
			sessions.clear()
			changed.emit()


## Undo or redo on a guest: the host does it, for everyone.
func request_undo(redo := false) -> void:
	if role == "guest":
		_undo.rpc_id(1, redo)


## A line for the pause menu's Multiplayer entry.
func status_text() -> String:
	match role:
		"host":
			return "Multiplayer: hosting · %d player%s" % [players.size(), "" if players.size() == 1 else "s"]
		"guest":
			return "Multiplayer: playing with %s" % _host_name()
		"joining":
			return "Multiplayer: joining…"
	return "Multiplayer…"


## The Multiplayer page of the pause menu: [label, action] pairs.
func menu_items() -> Array:
	var items := []
	match role:
		"host":
			var names := []
			for id in players:
				names.append(players[id].name + (" (you)" if id == 1 else ""))
			items.append(["Hosting “%s” on this Wi-Fi · %s" % [game.doc.get_part_name(), ", ".join(names)], "mp_none"])
			items.append(["Stop hosting", "mp_leave"])
		"guest", "joining":
			items.append(["%s %s's game" % ["Playing in" if role == "guest" else "Joining", _host_name()], "mp_none"])
			items.append(["Leave the game", "mp_leave"])
		_:
			var problem := host_problem()
			items.append(["Host this part on this Wi-Fi" if problem == "" else "Host: " + problem, "mp_host"])
			var keys := sessions.keys()
			keys.sort()
			for key in keys:
				var s: Dictionary = sessions[key]
				items.append(["Join %s: “%s” · %d of %d players" % [s.host, s.part, int(s.players), MAX_PLAYERS], "mp_join:" + key])
			if keys.is_empty():
				items.append(["Looking for games on this Wi-Fi…", "mp_none"])
	items.append(["Back", "menu_back"])
	return items


func _host_name() -> String:
	return String(players.get(1, {}).get("name", "the host"))


func _process(dt: float) -> void:
	_read_beacons()
	if role == "host" and _beacon != null:
		_beacon_t -= dt
		if _beacon_t <= 0.0:
			_beacon_t = BEACON_EVERY
			var msg := {app = "fps-cad", v = PROTOCOL, host = my_name, part = game.doc.get_part_name(),
				players = players.size(), port = port}
			_beacon.put_packet(JSON.stringify(msg).to_utf8_buffer())
	if not in_game() or game.doc == null or game.state != "play":
		return
	_check_t += dt
	if _check_t >= CHECK_EVERY:
		_check_t = 0.0
		if role == "host":
			_check_host()
		else:
			_check_guest()
	_pose_t += dt
	if _pose_t >= POSE_EVERY:
		_pose_t = 0.0
		var aim: Variant = game._aim.get("point") if game._aim.has("point") else null
		_pose.rpc(game.player.feet, game.player.yaw, game.player.pitch, game.player.size, aim)


func _read_beacons() -> void:
	var now := Time.get_ticks_msec()
	var before := sessions.size()
	if _listen != null:
		while _listen.get_available_packet_count() > 0:
			var data := _listen.get_packet()
			var ip := _listen.get_packet_ip()
			var msg = JSON.parse_string(data.get_string_from_utf8())
			if not (msg is Dictionary) or msg.get("app") != "fps-cad" or int(msg.get("v", 0)) != PROTOCOL:
				continue
			var key := "%s:%d" % [ip, int(msg.get("port", PORT))]
			var fresh: bool = not sessions.has(key) or sessions[key].players != int(msg.get("players", 1)) or sessions[key].part != String(msg.get("part", ""))
			sessions[key] = {ip = ip, port = int(msg.get("port", PORT)), host = String(msg.get("host", "?")).substr(0, 24),
				part = String(msg.get("part", "")).substr(0, 40), players = int(msg.get("players", 1)), seen = now}
			if fresh:
				changed.emit()
	for key in sessions.keys():
		if now - int(sessions[key].seen) > SESSION_GONE * 1000:
			sessions.erase(key)
	if sessions.size() < before:
		changed.emit()


# ---------- the part ----------

## The part's state, without imported shapes.
func _state() -> String:
	return game.doc.state_text(false)


## Imported shapes to send: all of them as JSON when they changed since last sent, else "".
func _imports_to_send() -> String:
	var sig: String = game.doc.imports_signature()
	if sig == _imports_sig:
		return ""
	_imports_sig = sig
	var full = JSON.parse_string(game.doc.state_text(true))
	return JSON.stringify(full.get("imports", {})) if full is Dictionary else ""


## Whether the player is in the middle of something that changes the part in steps.
func busy() -> bool:
	return game.sketcher.active or game.dialog.visible


## state with imported shapes (a JSON object of base64 text) added, without parsing state: the
## shapes are only strings, but state's numbers must stay as the C++ side wrote them.
static func with_imports(state: String, shapes: Dictionary) -> String:
	if shapes.is_empty():
		return state
	var end := state.rfind("}")
	return state.substr(0, end) + ",\"imports\":" + JSON.stringify(shapes) + "}"


## Two changes made from base, combined by the C++ side: {state, conflicts}, or {error}.
func _merge(base: String, theirs: String, mine: String) -> Dictionary:
	return game.doc.merge_states(base, theirs, mine)


## Sets the part to state (with imports, a JSON object of shapes, or "") and redraws everything
## it touches. keep_undo: the host keeps the previous state on its undo stack.
func _apply(state: String, imports: String, keep_undo: bool) -> String:
	var shapes: Dictionary = _pending_imports.duplicate()
	var more = JSON.parse_string(imports) if imports != "" else {}
	if more is Dictionary:
		shapes.merge(more, true)
	_pending_imports = {}
	var text := with_imports(state, shapes)
	var boards_before := JSON.stringify(game.doc.get_boards())
	var err: String = game.doc.set_state(text, keep_undo)
	if err != "":
		return err
	_imports_sig = game.doc.imports_signature()
	game._on_model_changed()
	game.hud.units = game.doc.get_units()
	game.view.set_appearance(game.doc.material_info())
	if JSON.stringify(game.doc.get_boards()) != boards_before:
		game.boards.load_from(game.doc)
	return ""


func _remember(v: int, state: String, author: int) -> void:
	_history[v] = state
	_authors[v] = author
	_history.erase(v - HISTORY)
	_authors.erase(v - HISTORY)


func _check_host() -> void:
	if busy():
		return
	var now := _state()
	if now != _known or game.doc.imports_signature() != _imports_sig:
		version += 1
		_known = now
		_remember(version, now, 1)
		_doc.rpc(version, now, _imports_to_send(), 1)
	while not _queue.is_empty() and not busy():
		var p: Array = _queue.pop_front()
		_take(p[0], p[1], p[2], p[3])


func _check_guest() -> void:
	if busy():
		return
	if not _held.is_empty():
		var h := _held
		_held = {}
		_from_host(int(h.version), String(h.state), String(h.imports))
	if _in_flight != "":
		return
	var now := _state()
	if now == _known and game.doc.imports_signature() == _imports_sig:
		return
	_in_flight = now
	_propose.rpc_id(1, _base_version, now, _imports_to_send())


## Host: takes a guest's change, merged with any others' made since the version it started from.
func _take(sender: int, base: int, state: String, imports: String) -> void:
	if not players.has(sender):
		return
	var others := false
	for v in range(base + 1, version + 1):
		if int(_authors.get(v, 0)) != sender:
			others = true
	var merged := state
	var notes: Array = []
	if others:
		if not _history.has(base):
			_result.rpc_id(sender, version, _known, _all_imports(), true,
				["The part changed too much while your change was on its way, so it wasn't kept. Try it again."])
			return
		var m := _merge(_history[base], _known, state)
		if m.has("error"):
			_result.rpc_id(sender, version, _known, _all_imports(), true, ["The host's game couldn't combine your change: " + String(m.error)])
			return
		merged = m.state
		merges += 1
		for c in m.conflicts:
			notes.append("%s changed %s at the same moment, so their version was kept" % [_name_of(_last_author()), c])
	var err := _apply(merged, imports, true)
	if err != "":
		_result.rpc_id(sender, version, _known, "", true, ["The host's game couldn't use your change: " + err])
		return
	version += 1
	_known = _state()
	_remember(version, _known, sender)
	_result.rpc_id(sender, version, _known, "", false, notes)
	for id in players:
		if id != 1 and id != sender:
			_doc.rpc_id(id, version, _known, imports, sender)
	if not notes.is_empty():
		_toast("%s's change was combined with yours" % _name_of(sender))


func _all_imports() -> String:
	var full = JSON.parse_string(game.doc.state_text(true))
	return JSON.stringify(full.get("imports", {})) if full is Dictionary else ""


func _last_author() -> int:
	return int(_authors.get(version, 1))


func _name_of(id: int) -> String:
	return String(players.get(id, {}).get("name", "another player"))


## Guest: a new version from the host. Local changes not yet sent are merged in and go out next.
func _from_host(v: int, state: String, imports: String) -> void:
	var current := _state()
	var target := state
	if current != _known:
		var m := _merge(_known, state, current)
		target = m.get("state", state)
	var err := _apply(target, imports, false)
	if err != "":
		_toast("Couldn't show the latest change: " + err)
	_base_version = v
	_base_text = state
	_known = state


# ---------- messages ----------

@rpc("any_peer", "call_remote", "reliable")
func _hello(protocol: int, build: String, player_name: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if role != "host":
		return
	if protocol != PROTOCOL:
		_refuse(sender, "That game runs a different version of FPS-CAD (%s, yours is %s). Update both to the same build." % [BuildInfo.VERSION, build])
		return
	if players.size() >= MAX_PLAYERS:
		_refuse(sender, "That game is full (%d players)" % MAX_PLAYERS)
		return
	var taken := players.values().map(func(p): return int(p.color))
	var color := 0
	while color in taken:
		color += 1
	players[sender] = {name = player_name.strip_edges().substr(0, 24) if player_name.strip_edges() != "" else "Player", color = color}
	_welcome.rpc_id(sender, version, _known, _all_imports(), players, game.doc.get_part_name())
	_players.rpc(players)
	_sync_avatars()
	_toast("%s joined" % players[sender].name)
	changed.emit()


func _refuse(id: int, reason: String) -> void:
	_refused.rpc_id(id, reason)
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		if _peer != null:
			_peer.disconnect_peer(id))


@rpc("authority", "call_remote", "reliable")
func _refused(reason: String) -> void:
	_toast(reason)
	stop.call_deferred(false)


@rpc("authority", "call_remote", "reliable")
func _welcome(v: int, state: String, imports: String, all: Dictionary, part_name: String) -> void:
	if role != "joining":
		return
	var d: RefCounted = ClassDB.instantiate(&"CadPart")
	var shapes = JSON.parse_string(imports) if imports != "" else {}
	var err: String = d.set_state(with_imports(state, shapes if shapes is Dictionary else {}), false)
	if err != "":
		_toast("Couldn't load the shared part: " + err)
		stop(false)
		return
	if game.current_path != "":
		game._save()  # keep what was open
	game._autosave()
	game._close_editors()
	game._end_challenge()
	if game.tutorial != null:
		game.tutorial.queue_free()
		game.tutorial = null
	game.mode = "free"
	game._open(d, false)
	game.hud.set_menu(false)
	game._menu_page = ""
	role = "guest"
	players = all
	version = v
	_base_version = v
	_base_text = state
	_known = _state()
	_imports_sig = game.doc.imports_signature()
	listen_for_games(false)
	_sync_avatars()
	_toast("Joined %s's game: “%s”" % [_host_name(), part_name])
	changed.emit()


@rpc("authority", "call_remote", "reliable")
func _players(all: Dictionary) -> void:
	players = all
	_sync_avatars()
	changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _propose(base: int, state: String, imports: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if role != "host":
		return
	if busy():
		_queue.append([sender, base, state, imports])
	else:
		_take(sender, base, state, imports)


@rpc("authority", "call_remote", "reliable")
func _result(v: int, state: String, imports: String, rejected: bool, notes: Array) -> void:
	if role != "guest":
		return
	var proposed := _in_flight
	_in_flight = ""
	if rejected:
		_apply(state, imports, false)
	elif state != proposed:
		var current := _state()
		var target := state
		if current != proposed:  # changed again while it was on its way
			var m := _merge(proposed, state, current)
			target = m.get("state", state)
		_apply(target, imports, false)
	version = v
	_base_version = v
	_base_text = state
	_known = state
	for n in notes:
		_toast(String(n))


@rpc("authority", "call_remote", "reliable")
func _doc(v: int, state: String, imports: String, author: int) -> void:
	if role != "guest":
		return
	version = v
	if imports != "":
		var more = JSON.parse_string(imports)
		if more is Dictionary:
			_pending_imports.merge(more, true)
	if _in_flight != "":
		return  # the host's answer to the proposal includes this
	if busy():
		_held = {version = v, state = state, imports = ""}
		return
	_from_host(v, state, "")


@rpc("any_peer", "call_remote", "reliable")
func _undo(redo: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if role != "host":
		return
	var who := _name_of(sender)
	if busy():
		_note.rpc_id(sender, "%s is in the middle of a change: try again in a moment" % _host_name())
		return
	var done: bool = game.doc.redo() if redo else game.doc.undo()
	if done:
		game._on_model_changed()
		_toast("%s: %s" % [who, "Redo" if redo else "Undo"])
	_note.rpc_id(sender, ("Redo" if redo else "Undo") if done else ("Nothing to redo" if redo else "Nothing to undo"))


@rpc("authority", "call_remote", "reliable")
func _note(text: String) -> void:
	_toast(text)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _pose(feet: Vector3, yaw: float, pitch: float, size: float, aim: Variant) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if _avatars.has(sender):
		_avatars[sender].set_pose(feet, yaw, pitch, size, aim if aim is Vector3 else null)


# ---------- players coming and going ----------

func _on_connected() -> void:
	_hello.rpc_id(1, PROTOCOL, BuildInfo.VERSION, my_name)


func _on_connection_failed() -> void:
	_toast("Couldn't reach that game")
	stop.call_deferred(false)


func _on_server_gone() -> void:
	_toast("%s stopped the game. You keep the part: save it to keep it." % _host_name())
	stop.call_deferred(false)


func _on_peer_connected(_id: int) -> void:
	pass  # a guest says hello first


func _on_peer_disconnected(id: int) -> void:
	if role != "host" or not players.has(id):
		return
	_toast("%s left" % players[id].name)
	players.erase(id)
	_queue = _queue.filter(func(p: Array) -> bool: return p[0] != id)
	_players.rpc(players)
	_sync_avatars()
	changed.emit()


func _sync_avatars() -> void:
	var me := multiplayer.get_unique_id()
	for id in _avatars.keys():
		if not players.has(id):
			_avatars[id].queue_free()
			_avatars.erase(id)
	for id in players:
		if id == me:
			continue
		if not _avatars.has(id):
			var a: Node3D = Avatar.new()
			game.add_child(a)
			_avatars[id] = a
		_avatars[id].set_player(String(players[id].name), COLORS[int(players[id].color) % COLORS.size()])


func _toast(text: String) -> void:
	if game != null and game.hud != null:
		game.hud.toast(text)
