extends Control
## The tool wheel, opened like a weapon wheel, with tools gathered into groups.
##
## The inner ring holds the groups (and single tools). Aiming at a group shows its tools
## branching outward from it on an outer ring. Choosing the group (let go of the wheel button,
## press A / RT / click, or tap it) moves the selection out onto that branch; aim at a tool and
## press A / RT / click (or tap) to pick it. B / Esc steps back to the groups, then closes.
##
## main.gd fills the wheel from tools.gd (modelling) or sketcher.gd (sketch mode). Each node of
## the tree is {name, pri?, alt?, value} for a tool (value is what picked() reports) or
## {name, desc?, children: [...]} for a group.

signal picked(value: int)

const ENTERED := -2  # commit() result: a group opened; the wheel stays open
const RADIUS := 150.0
const SLOT := 92.0
const CHILD := 84.0
const SPREAD := 0.62  # radians between neighbouring tools on a branch
const ACCENT := Color("ff8a3d")

var tree: Array = []
var group := -1   # open group (index into tree), or -1 at the inner ring
var hover := -1   # hovered node: in tree at the inner ring, in the group's children on a branch
var current := -1  # value of the tool in use, highlighted
var _shown := -1   # group whose branch is drawn (open, or hovered at the inner ring)
var _vec := Vector2.ZERO
var _slots: Array[Button] = []
var _kids: Array[Button] = []
var _back := Button.new()
var _title := Label.new()
var _detail := Label.new()
var _page := Label.new()
var _r := RADIUS
var _r2 := RADIUS + 100.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # in the tree already: offsets must follow too
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.06, 0.08, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	for l in [_title, _detail, _page]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(l)
	_title.add_theme_font_size_override("font_size", 20)
	_detail.add_theme_font_size_override("font_size", 13)
	_detail.add_theme_color_override("font_color", Color("9ba7b6"))
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD
	_page.add_theme_font_size_override("font_size", 14)
	_page.add_theme_color_override("font_color", ACCENT)
	_back.text = "◀ Back"
	_back.focus_mode = Control.FOCUS_NONE
	_back.custom_minimum_size = Vector2(96, 34)
	_back.size = Vector2(96, 34)
	_back.visible = false
	_back.pressed.connect(back)
	add_child(_back)


func setup(nodes: Array, title := "", hint := "") -> void:
	tree = nodes
	_page.text = title + ("   ·   " + hint if hint != "" else "")
	for b in _slots:
		b.queue_free()
	_slots.clear()
	for i in tree.size():
		var node: Dictionary = tree[i]
		var b := _button(SLOT)
		b.text = "%s%s\n%d" % [node.name, "  ›" if node.has("children") else "", i + 1]
		var idx := i
		b.pressed.connect(func(): _choose_slot(idx))
		b.mouse_entered.connect(_hover_slot.bind(idx))
		_slots.append(b)


func _button(d: float) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(d, d)
	b.size = Vector2(d, d)
	b.focus_mode = Control.FOCUS_NONE
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(b)
	return b


## Opens at the inner ring, highlighting the group that holds the tool in use.
func open(current_value: int) -> void:
	current = current_value
	group = -1
	hover = -1
	_vec = Vector2.ZERO
	visible = true
	_layout()
	_show_branch(-1)
	_refresh()


## Opens group i's branch so its tools can be picked.
func enter(i: int) -> void:
	if i < 0 or i >= tree.size() or not tree[i].has("children"):
		return
	group = i
	hover = -1
	var kids: Array = tree[i].children
	for k in kids.size():
		if int(kids[k].get("value", -99)) == current:
			hover = k
	_vec = Vector2.ZERO
	_show_branch(i)
	_refresh()


## B / Esc / Back: from a branch back to the groups, from the groups closed.
func back() -> void:
	if group >= 0:
		var was := group
		group = -1
		hover = was
		_vec = Vector2.ZERO
		_show_branch(was)
		_refresh()
	else:
		visible = false


## Acts on the hovered node: picks a tool (returns its value and closes), opens a group
## (returns ENTERED), or with nothing aimed at closes (-1) at the inner ring and stays open on a
## branch (ENTERED).
func commit() -> int:
	if group < 0:
		if hover < 0:
			visible = false
			return -1
		if tree[hover].has("children"):
			enter(hover)
			return ENTERED
		visible = false
		return int(tree[hover].value)
	if hover < 0:
		return ENTERED
	visible = false
	return int(tree[group].children[hover].value)


func close(_commit := false) -> int:
	visible = false
	return -1


## Accumulates pointer motion (mouse relative or right stick) into a direction.
func point(delta: Vector2) -> void:
	_vec = (_vec + delta).limit_length(120.0)
	if _vec.length() < 30.0 or tree.is_empty():
		return
	var a := _vec.angle()
	if group < 0:
		var best := 0
		for i in tree.size():
			if absf(angle_difference(a, _slot_angle(i))) < absf(angle_difference(a, _slot_angle(best))):
				best = i
		_set_hover(best)
	else:
		var kids: Array = tree[group].children
		var best := 0
		for k in kids.size():
			if absf(angle_difference(a, _kid_angle(group, k))) < absf(angle_difference(a, _kid_angle(group, best))):
				best = k
		_set_hover(best)


## Absolute stick direction (right stick held away from centre).
func aim(stick: Vector2) -> void:
	if stick.length() < 0.5:
		return
	_vec = stick * 100.0
	point(Vector2.ZERO)


func _slot_angle(i: int) -> float:
	return -PI / 2.0 + TAU * i / maxi(1, tree.size())


func _kid_angle(g: int, k: int) -> float:
	var n: int = tree[g].children.size()
	return _slot_angle(g) + (k - (n - 1) / 2.0) * SPREAD


func _layout() -> void:
	var c := size / 2.0
	var half := minf(size.x, size.y) / 2.0
	# Keep the outer ring on screen: on short (phone) screens both rings move in.
	_r = clampf(half - 12.0 - CHILD / 2.0 - (SLOT + CHILD) / 2.0 - 14.0, 84.0, RADIUS)
	_r2 = _r + (SLOT + CHILD) / 2.0 + 14.0
	for i in _slots.size():
		var a := _slot_angle(i)
		_slots[i].position = c + Vector2(cos(a), sin(a)) * _r - Vector2(SLOT, SLOT) / 2.0
	_title.position = c + Vector2(-90, -30)
	_title.size = Vector2(180, 28)
	_detail.position = c + Vector2(-78, 0)
	_detail.size = Vector2(156, 40)
	_back.position = c + Vector2(-48, 36)
	_page.position = c + Vector2(-220, -_r2 - CHILD * 0.5 - 30)
	_page.size = Vector2(440, 24)


## Draws group g's tools on the outer ring around it (g = -1 hides them).
func _show_branch(g: int) -> void:
	if g == _shown and (g < 0 or _kids.size() == tree[g].children.size()):
		return
	for b in _kids:
		b.queue_free()
	_kids.clear()
	_shown = g
	if g < 0:
		return
	var c := size / 2.0
	var kids: Array = tree[g].children
	for k in kids.size():
		var b := _button(CHILD)
		b.text = kids[k].name
		b.add_theme_font_size_override("font_size", 15)
		var a := _kid_angle(g, k)
		b.position = c + Vector2(cos(a), sin(a)) * _r2 - Vector2(CHILD, CHILD) / 2.0
		var kk := k
		var gg := g
		b.pressed.connect(func(): _choose_kid(gg, kk))
		b.mouse_entered.connect(_hover_kid.bind(gg, kk))
		_kids.append(b)


func _hover_slot(i: int) -> void:
	if group < 0:
		_set_hover(i)


func _hover_kid(g: int, k: int) -> void:
	if group == g:
		_set_hover(k)


func _set_hover(i: int) -> void:
	if i == hover:
		return
	hover = i
	Input.start_joy_vibration(0, 0.1, 0.0, 0.03)
	if group < 0:
		_show_branch(i if i >= 0 and tree[i].has("children") else -1)
	_refresh()


func _choose_slot(i: int) -> void:
	if tree[i].has("children"):
		if group == i:
			back()
		else:
			enter(i)
		return
	visible = false
	picked.emit(int(tree[i].value))


func _choose_kid(g: int, k: int) -> void:
	visible = false
	picked.emit(int(tree[g].children[k].value))


func _holds_current(node: Dictionary) -> bool:
	if node.has("children"):
		for kid in node.children:
			if int(kid.get("value", -99)) == current:
				return true
		return false
	return int(node.get("value", -99)) == current


func _refresh() -> void:
	for i in _slots.size():
		var b := _slots[i]
		var col := Color(0.85, 0.88, 0.92, 0.9)
		if group >= 0:
			col = ACCENT if i == group else Color(1, 1, 1, 0.3)
		elif i == hover:
			col = ACCENT
		elif _holds_current(tree[i]):
			col = Color(1, 1, 1, 1)
		b.modulate = col
	for k in _kids.size():
		var kid: Dictionary = tree[_shown].children[k]
		var col := Color(1, 1, 1, 0.55)  # a preview of the branch
		if group == _shown:
			col = ACCENT if k == hover else (Color(1, 1, 1, 1) if int(kid.get("value", -99)) == current else Color(0.85, 0.88, 0.92, 0.9))
		_kids[k].modulate = col
	_back.visible = group >= 0
	if tree.is_empty():
		return
	var node: Dictionary = {}
	if group >= 0:
		node = tree[group].children[hover] if hover >= 0 else tree[group]
	elif hover >= 0:
		node = tree[hover]
	else:
		for n in tree:
			if _holds_current(n):
				node = n
	if node.is_empty():
		_title.text = ""
		_detail.text = ""
		return
	_title.text = String(node.name).to_upper()
	if node.has("children"):
		var names: Array = node.children.map(func(kid): return kid.name)
		_detail.text = String(node.get("desc", " · ".join(PackedStringArray(names))))
	else:
		_detail.text = "%s\n%s" % [node.get("pri", ""), node.get("alt", "")]
