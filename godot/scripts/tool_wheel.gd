extends Control
## The tool wheel, opened like a weapon wheel, with tools gathered into groups.
##
## The inner ring holds the groups (and single tools). Aiming at a group shows its tools
## branching outward from it on an outer ring. With a controller, the right stick picks the group
## and the left stick picks a tool on its branch; letting go of the wheel button takes that tool. Choosing the group (let go of the wheel button,
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
const BRANCH_PUSH := 130.0  # mouse travel (px) past which pointing picks a tool on the group's branch
const MAX_PUSH := 220.0
const ACCENT := Color("ff8a3d")

var tree: Array = []
var group := -1   # open group (index into tree), or -1 at the inner ring
var hover := -1   # hovered node: in tree at the inner ring, in the group's children on a branch
var current := -1  # value of the tool in use, highlighted
var _shown := -1   # group whose branch is drawn (open, or hovered at the inner ring)
var branch := -1   # at the inner ring: the tool on the hovered group's branch picked by the left stick
var _vec := Vector2.ZERO
var _slots: Array[Button] = []
var _kids: Array[Button] = []
var _back := Button.new()
var _title := Label.new()
var _detail := Label.new()
var _page := Label.new()
var _r := RADIUS
var _r2 := RADIUS + 100.0
var _spread := SPREAD  # radians between neighbouring tools on a branch, just enough not to overlap
var _slot_size := SLOT


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
	# Under the name: an arrow on groups, and the number key with a keyboard.
	var keys: bool = Actions.last_device == "keyboard"
	for i in tree.size():
		var node: Dictionary = tree[i]
		var b := _button(SLOT)
		var under := ("›" if node.has("children") else "") + ("  %d" % (i + 1) if keys and i < 9 else "")
		b.text = node.name + ("\n" + under.strip_edges() if under.strip_edges() != "" else "")
		var idx := i
		b.pressed.connect(func(): _choose_slot(idx))
		b.mouse_entered.connect(_hover_slot.bind(idx))
		_slots.append(b)


func _button(d: float) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(d, d)
	b.size = Vector2(d, d)
	b.focus_mode = Control.FOCUS_NONE
	b.autowrap_mode = TextServer.AUTOWRAP_WORD  # between words only; _fit_text sizes the font
	b.clip_text = true  # a label never makes its button grow over its neighbours
	add_child(b)
	# Thin inner margins: the buttons are small, so the names get the room.
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var box: StyleBox = b.get_theme_stylebox(state)
		if box != null:
			box = box.duplicate()
			box.content_margin_left = 4.0
			box.content_margin_right = 4.0
			box.content_margin_top = 3.0
			box.content_margin_bottom = 3.0
			b.add_theme_stylebox_override(state, box)
	return b


## A tap or click on the dimmed background (not on a button) steps back: from a branch to the
## groups, from the groups closed.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and Actions.last_device == "touch":
		back()
		accept_event()


## Opens at the inner ring, highlighting the group that holds the tool in use.
func open(current_value: int) -> void:
	current = current_value
	group = -1
	hover = -1
	branch = -1
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
##
## released: the wheel button was let go. Then only a complete choice counts: a single tool, or a
## group with a tool picked on its branch. Anything less closes the wheel and keeps the tool in
## use (-1).
func commit(released := false) -> int:
	if group < 0:
		if hover < 0:
			visible = false
			return -1
		if branch >= 0 and tree[hover].has("children"):
			visible = false
			return int(tree[hover].children[branch].value)
		if released and tree[hover].has("children"):
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


## Accumulates pointer motion (mouse relative or right stick) into a direction. At the inner ring,
## pushing on past a group (beyond BRANCH_PUSH) keeps that group and picks the tool on its branch
## by direction, so a mouse alone can choose any tool in one move while the wheel key is held.
func point(delta: Vector2) -> void:
	_vec = (_vec + delta).limit_length(MAX_PUSH)
	if _vec.length() < 30.0 or tree.is_empty():
		return
	var a := _vec.angle()
	if group < 0 and _vec.length() > BRANCH_PUSH and hover >= 0 and tree[hover].has("children"):
		var kids: Array = tree[hover].children
		var pick := 0
		for k in kids.size():
			if absf(angle_difference(a, _kid_angle(hover, k))) < absf(angle_difference(a, _kid_angle(hover, pick))):
				pick = k
		if pick != branch:
			branch = pick
			_refresh()
		return
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


## Left stick: picks the tool on the branch of the group the right stick points at (or on the open
## branch), by direction, since the branch fans out around its group.
func aim_branch(stick: Vector2) -> void:
	if stick.length() < 0.5 or tree.is_empty():
		return
	if group >= 0:
		aim(stick)
		return
	if hover < 0 or not tree[hover].has("children"):
		return
	var a := stick.angle()
	var kids: Array = tree[hover].children
	var best := 0
	for k in kids.size():
		if absf(angle_difference(a, _kid_angle(hover, k))) < absf(angle_difference(a, _kid_angle(hover, best))):
			best = k
	if best != branch:
		branch = best
		Input.start_joy_vibration(0, 0.1, 0.0, 0.03)
		_refresh()


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
	return _slot_angle(g) + (k - (n - 1) / 2.0) * _spread


func _layout() -> void:
	var c := size / 2.0
	var half := minf(size.x, size.y) / 2.0
	# Keep the outer ring on screen: on short (phone) screens both rings move in.
	# With many groups the inner ring grows so its buttons do not overlap, and the buttons shrink
	# when the screen has no room for that.
	var n := maxi(3, _slots.size())
	var gap := sin(PI / n)
	var want := maxf(RADIUS, (SLOT + 10.0) / (2.0 * gap))
	_r = clampf(half - 12.0 - CHILD / 2.0 - (SLOT + CHILD) / 2.0 - 14.0, 84.0, want)
	var slot := minf(SLOT, 2.0 * _r * gap - 8.0)
	_r2 = _r + (slot + CHILD) / 2.0 + 14.0
	_slot_size = slot
	_spread = minf(SPREAD, 2.0 * asin(clampf((CHILD + 16.0) / (2.0 * _r2), 0.0, 1.0)))
	for i in _slots.size():
		var a := _slot_angle(i)
		_slots[i].custom_minimum_size = Vector2(slot, slot)
		_slots[i].size = Vector2(slot, slot)
		_slots[i].position = c + Vector2(cos(a), sin(a)) * _r - Vector2(slot, slot) / 2.0
	# One text size for the whole ring: the largest at which every name fits its button.
	var fit := 17
	for b in _slots:
		fit = mini(fit, _fit_size(b, slot, 17))
	for b in _slots:
		b.add_theme_font_size_override("font_size", fit)
	_title.position = c + Vector2(-90, -30)
	_title.size = Vector2(180, 28)
	_detail.position = c + Vector2(-78, 0)
	_detail.size = Vector2(156, 40)
	_detail.clip_text = true
	_detail.max_lines_visible = 2
	# Back sits low in the middle, clear of the two lines of detail above it.
	_back.position = c + Vector2(-48, clampf(_r - _slot_size / 2.0 - 40.0, 40.0, 70.0))
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
		_fit_text(b, CHILD, 15)
		var a := _kid_angle(g, k)
		b.position = c + Vector2(cos(a), sin(a)) * _r2 - Vector2(CHILD, CHILD) / 2.0
		var kk := k
		var gg := g
		b.pressed.connect(func(): _choose_kid(gg, kk))
		b.mouse_entered.connect(_hover_kid.bind(gg, kk))
		_kids.append(b)


## The largest font size (at most top) at which every word of the button's text fits its width,
## so names wrap between words and never inside one.
static func _fit_text(b: Button, width: float, top: int) -> void:
	b.add_theme_font_size_override("font_size", _fit_size(b, width, top))


static func _fit_size(b: Button, width: float, top: int) -> int:
	var font: Font = b.get_theme_font("font")
	var box: StyleBox = b.get_theme_stylebox("normal")
	var room := width - 6.0 - (box.get_margin(SIDE_LEFT) + box.get_margin(SIDE_RIGHT) if box != null else 16.0)
	var tall := width - 4.0 - (box.get_margin(SIDE_TOP) + box.get_margin(SIDE_BOTTOM) if box != null else 12.0)
	var size := top
	while size > 9:
		# Lay the words out greedily at this size: every word must fit, and so must the lines.
		var fits := true
		var lines := 0
		for para in b.text.split("\n"):
			var line_w := 0.0
			lines += 1
			for w in para.split(" ", false):
				var ww := font.get_string_size(w, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
				var sp := font.get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
				if ww > room:
					fits = false
				if line_w > 0.0 and line_w + sp + ww > room:
					lines += 1
					line_w = ww
				else:
					line_w += (sp if line_w > 0.0 else 0.0) + ww
		if fits and lines * font.get_height(size) <= tall:
			break
		size -= 1
	return size


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
	if group < 0:
		branch = -1  # a new group: its tools start unpicked
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
		elif k == branch:
			col = ACCENT
		_kids[k].modulate = col
	_back.visible = group >= 0
	if tree.is_empty():
		return
	var node: Dictionary = {}
	if group >= 0:
		node = tree[group].children[hover] if hover >= 0 else tree[group]
	elif hover >= 0:
		node = tree[hover].children[branch] if branch >= 0 and tree[hover].has("children") else tree[hover]
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
