extends Node3D
## The whiteboards the player sets up in the room, beside the message board (main.board).
##
## Two kinds: a properties board shows the part's volume, surface area, mass, bounding box and
## centre of mass, kept up to date as the part changes; a notes board holds the player's own notes.
## Any board, the message board included, can be picked up and carried: it stays at the same
## distance ahead, turned the same way relative to the player, and always stands on the floor;
## the D-pad (or mouse wheel and +/-) turns and resizes it while it is carried.
##
## The layout is saved in the part file (CadPart.set_boards → views/boards.json), so the boards
## come back where they stood when the part is opened again. Assemblies have only the message
## board for now.

const Whiteboard := preload("res://scripts/whiteboard.gd")
const Units := preload("res://scripts/units.gd")

const TURN_STEP := PI / 12.0   # 15° per tap
const SCALE_STEP := 1.25
const MIN_SCALE := 0.1
const MAX_SCALE := 12.0

var game: Node  # main.gd
var extra: Array = []          # the boards the player added
var messages_saved := false    # the open part remembers where the message board stands

var _carry: Node3D = null
var _carry_from := {}          # where it stood, to put it back
var _carry_dist := 0.0
var _carry_turn := 0.0         # its yaw relative to facing the player


# ---------- the set of boards ----------

## Every board, the message board first.
func all() -> Array:
	return [game.board] + extra


func clear() -> void:
	_carry = null
	for b in extra:
		b.queue_free()
	extra.clear()
	messages_saved = false


## Puts up the boards saved in the part (doc.get_boards()); the message board moves to its saved
## place if there is one.
func load_from(doc: RefCounted) -> void:
	clear()
	if doc == null or not doc.has_method("get_boards"):
		return
	for d in doc.get_boards():
		if not (d is Dictionary):
			continue
		var pos: Array = d.get("position", [0, 0, 0])
		var at := Vector3(float(pos[0]), floor_y(), float(pos[2])) if pos.size() == 3 else Vector3(0, floor_y(), 0)
		var s := clampf(float(d.get("scale", 1.0)), MIN_SCALE, MAX_SCALE)
		var kind := String(d.get("kind", ""))
		if kind == "messages":
			game.board.set_pose(at, float(d.get("yaw", 0.0)), s)
			messages_saved = true
		elif kind in ["properties", "notes"]:
			var b := add(kind, at, float(d.get("yaw", 0.0)), s, String(d.get("id", "")))
			if kind == "notes":
				b.set_notes(d.get("notes", []))
	refresh_properties()


## Writes the layout into the part and autosaves.
func save() -> void:
	if game.doc == null or not game.doc.has_method("set_boards"):
		return
	var out := []
	if game.board.active:
		out.append(game.board.to_dict())
	for b in extra:
		out.append(b.to_dict())
	game.doc.set_boards(out)
	messages_saved = true
	game._autosave()


func add(kind: String, feet: Vector3, yaw: float, s: float, id := "") -> Node3D:
	var b: Node3D = Whiteboard.new()
	b.kind = kind
	b.board_id = id if id != "" else "board-%d-%d" % [Time.get_ticks_msec(), randi() % 100000]
	add_child(b)
	b.set_pose(feet, yaw, s)
	if kind == "notes":
		b.set_card("NOTES", "", "")
		b.set_notes([])
	extra.append(b)
	if kind == "properties":
		refresh_properties()
	return b


func remove(b: Node3D) -> void:
	if b == game.board or not extra.has(b):
		return
	if b == _carry:
		_carry = null
		game.player.size_locked = false
	extra.erase(b)
	b.queue_free()
	save()


func floor_y() -> float:
	return game.view.room.floor_y()


## The nearest board along a ray: the cast hit (with .board) or {}.
func pick(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var best := {}
	for b in all():
		if b == _carry:
			continue  # look past the board being carried
		var h: Dictionary = b.cast(origin, dir, max_distance)
		if not h.is_empty() and (best.is_empty() or h.distance < best.distance):
			best = h
	return best


## The player's boards as solid things to bump into (the message board is cast by main.gd).
func cast_extra(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var best := {}
	for b in extra:
		if b == _carry:
			continue
		var h: Dictionary = b.cast(origin, dir, max_distance)
		if not h.is_empty() and (best.is_empty() or h.distance < best.distance):
			best = h
	return best


# ---------- what the properties boards say ----------

func refresh_properties() -> void:
	var props := extra.filter(func(b): return b.kind == "properties")
	if props.is_empty():
		return
	var lines := properties_text(game.doc, game.hud.units)
	for b in props:
		b.set_card("PART PROPERTIES", lines[0], lines[1])


## [heading, body] for a properties board: the part's name, then its properties line by line.
static func properties_text(doc: RefCounted, units: String) -> Array:
	if doc == null or not doc.has_method("mass_properties"):
		return ["", "Properties show for parts"]
	var name: String = doc.get_part_name() if doc.has_method("get_part_name") else "Part"
	var m: Dictionary = doc.mass_properties()
	if float(m.volume) <= 0.0:
		return [name, "No solid yet. Volume, area, mass and size show here as you build."]
	var u: String = units if Units.SCALE.has(units) else "mm"
	var k := Units.length_scale(u)
	var lines := PackedStringArray()
	var mu: String = doc.get_mass_units() if doc.has_method("get_mass_units") else ""
	lines.append("Volume   %s" % Units.volume_text(float(m.volume), u))
	lines.append("Surface area   %s" % Units.area_text(float(m.area), u))
	lines.append("Mass   %s" % Units.mass_text(float(m.mass), mu))
	var b: Dictionary = doc.bounding_box()
	if b.get("ok", false):
		var sz: Vector3 = b.size
		lines.append("Bounding box   %s × %s × %s %s" % [Units.significant(sz.x / k), Units.significant(sz.y / k),
			Units.significant(sz.z / k), u])
	var c: Vector3 = m.centre_of_mass  # Godot space: CAD X = x, Y = -z, Z = y
	lines.append("Centre of mass   X %s  Y %s  Z %s %s" % [Units.significant(c.x / k, 3), Units.significant(-c.z / k, 3),
		Units.significant(c.y / k, 3), u])
	if doc.has_method("material_info"):
		lines.append_array(material_lines(doc.material_info(), u, mu))
	var feats: int = doc.get_features().size() if doc.has_method("get_features") else 0
	lines.append("%d bod%s · %d feature%s" % [int(m.bodies), "y" if int(m.bodies) == 1 else "ies", feats, "" if feats == 1 else "s"])
	return [name, "\n".join(lines)]


## The material and its properties, two short lines for a board: name and density, then stiffness
## and strength (what is known: a typed-in density has nothing else).
static func material_lines(info: Dictionary, units: String, mass: String) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("Material   %s   ·   %s" % [info.get("name", ""), Units.density_text(float(info.get("density", 0.0)), units, mass)])
	var props := PackedStringArray()
	if info.get("youngs_modulus") != null:
		props.append("E %s" % Units.stress_text(float(info.youngs_modulus), units))
	if info.get("yield_strength") != null:
		props.append("yield %s" % Units.stress_text(float(info.yield_strength), units))
	if info.get("tensile_strength") != null:
		props.append("UTS %s" % Units.stress_text(float(info.tensile_strength), units))
	if info.get("poissons_ratio") != null:
		props.append("Poisson %s" % Units.significant(float(info.poissons_ratio), 2))
	if not props.is_empty():
		out.append("   ".join(props))
	return out


# ---------- the board tools ----------

## A board tool's trigger (tools.gd → main.gd). primary: the right trigger / left click.
func act(id: String, primary: bool) -> void:
	var aimed := _aimed()
	var b: Node3D = aimed.get("board", null)
	if carrying():
		if primary:
			drop()
		else:
			cancel()
		return
	match id:
		"board_props":
			if primary:
				add("properties", spot_ahead(), 0.0, new_scale())
				_face_player(extra[-1])
				save()
				game.hud.toast("Properties board set up · it keeps up with the part")
			else:
				_remove_aimed(b)
		"board_notes":
			if primary:
				if b != null and b.kind == "notes":
					_ask_note(b, -1)
				else:
					var nb := add("notes", spot_ahead(), 0.0, new_scale())
					_face_player(nb)
					save()
					_ask_note(nb, -1)
			else:
				if b == null or b.kind != "notes":
					game.hud.toast("Aim at a note on a notes board to change it")
					return
				var i: int = b.note_at(aimed.point)
				if i < 0:
					game.hud.toast("Aim at the note itself to change it")
					return
				_ask_note(b, i)
		"board_arrange":
			if primary:
				if b == null:
					game.hud.toast("Aim at a whiteboard to pick it up")
					return
				pick_up(b)
			else:
				_remove_aimed(b)


func _remove_aimed(b: Node3D) -> void:
	if b == null:
		game.hud.toast("Aim at a board to remove it")
	elif b == game.board:
		game.hud.toast("The message board can be moved, not removed")
	else:
		remove(b)
		game.hud.toast("Board removed")


## index < 0: a new note; otherwise change that one (clearing the text deletes it).
func _ask_note(b: Node3D, index: int) -> void:
	var initial: String = "" if index < 0 else String(b.notes[index])
	var title := "New note" if index < 0 else "Edit note"
	var hint := "Shows on the board" if index < 0 else "Clear it to delete the note"
	var done := func(text: String) -> void: set_note(b, index, text)
	game.numpad.ask_text(title, initial, hint, done, index >= 0)


## Adds (index < 0), changes or, with empty text, deletes a note, then saves.
func set_note(b: Node3D, index: int, text: String) -> void:
	if not is_instance_valid(b):
		return
	var lines: Array = b.notes.duplicate()
	var t := text.strip_edges()
	if index < 0:
		if t == "":
			return
		lines.append(t)
	elif index < lines.size():
		if t == "":
			lines.remove_at(index)
		else:
			lines[index] = t
	b.set_notes(lines)
	save()


func _aimed() -> Dictionary:
	return pick(game.player.eye_position(), game.player.aim_direction(), 60.0 * game.player.size)


## A board's size for the player's: readable from where they stand.
func new_scale() -> float:
	return clampf(game.player.size, MIN_SCALE, MAX_SCALE)


## Where a new board stands: where the crosshair meets the floor if that is a sensible distance
## away, else a little way ahead. Always on the floor.
func spot_ahead() -> Vector3:
	var p: Node3D = game.player
	var eye: Vector3 = p.eye_position()
	var dir: Vector3 = p.aim_direction()
	var fy := floor_y()
	var near: float = 1.2 * p.size
	var far: float = 10.0 * p.size
	if dir.y < -0.05:
		var at := eye + dir * ((fy - eye.y) / dir.y)
		var flat := Vector2(at.x - p.feet.x, at.z - p.feet.z).length()
		if flat >= near and flat <= far:
			return Vector3(at.x, fy, at.z)
	var fwd := Vector3(-sin(p.yaw), 0, -cos(p.yaw))
	var spot: Vector3 = p.feet + fwd * 2.5 * p.size
	return Vector3(spot.x, fy, spot.z)


func _face_player(b: Node3D) -> void:
	var feet: Vector3 = b.feet()
	b.set_pose(feet, Whiteboard.facing(feet, game.player.feet), b.board_scale)


# ---------- carrying ----------

func carrying() -> bool:
	return _carry != null and is_instance_valid(_carry)


func carried() -> Node3D:
	return _carry if carrying() else null


func pick_up(b: Node3D) -> void:
	_carry = b
	_carry_from = {feet = b.feet(), yaw = b.yaw, scale = b.board_scale}
	var p: Node3D = game.player
	var feet: Vector3 = b.feet()
	_carry_dist = maxf(Vector2(feet.x - p.feet.x, feet.z - p.feet.z).length(), 1.0 * p.size)
	_carry_turn = wrapf(b.yaw - Whiteboard.facing(feet, p.feet), -PI, PI)
	p.size_locked = true
	game.hud.toast("Carrying the board: walk to move it · %s / %s turn · %s / %s resize · %s set down · %s put back" % [
		Actions.prompt(&"undo"), Actions.prompt(&"redo"), Actions.prompt(&"grow"), Actions.prompt(&"shrink"),
		Actions.prompt(&"primary"), Actions.prompt(&"secondary")])


## Called every frame: the carried board follows the player, standing on the floor.
func update_carry() -> void:
	if not carrying():
		return
	var p: Node3D = game.player
	var fwd := Vector3(-sin(p.yaw), 0, -cos(p.yaw))
	var feet: Vector3 = p.feet + fwd * _carry_dist
	feet.y = floor_y()
	_carry.set_pose(feet, Whiteboard.facing(feet, p.feet) + _carry_turn, _carry.board_scale)


## Turns the carried board by steps of 15° (positive: anticlockwise seen from above).
func turn(steps: float) -> void:
	if carrying():
		_carry_turn = wrapf(_carry_turn + steps * TURN_STEP, -PI, PI)
		update_carry()


## Resizes the carried board about its feet; it stays standing on the floor.
func rescale(times: float) -> void:
	if not carrying():
		return
	var s: float = clampf(_carry.board_scale * pow(SCALE_STEP, times), MIN_SCALE, MAX_SCALE)
	_carry.set_pose(_carry.feet(), _carry.yaw, s)
	game.hud.toast("Board size ×%s" % Units.significant(s, 2))


func drop() -> void:
	if not carrying():
		return
	_carry = null
	game.player.size_locked = false
	save()
	game.hud.toast("Board set down")


func cancel() -> void:
	if not carrying():
		return
	_carry.set_pose(_carry_from.feet, _carry_from.yaw, _carry_from.scale)
	_carry = null
	game.player.size_locked = false
	game.hud.toast("Board put back")
