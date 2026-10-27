extends Control
## Radial tool wheel, opened like a weapon wheel. Point with the right stick or the mouse while
## the button is held and release to pick, or tap a slot on a touch screen. The wheel has pages
## (Model and Direct tools); main.gd fills it with the page to show, or the sketch tools.

signal picked(index: int)

const RADIUS := 150.0
const SLOT := 92.0

var tools: Array = []
var current := 0
var hover := -1
var _vec := Vector2.ZERO
var _slots: Array[Button] = []
var _title := Label.new()
var _detail := Label.new()
var _page := Label.new()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.06, 0.08, 0.45)
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
	_page.add_theme_color_override("font_color", Color("ff8a3d"))


func setup(tool_list: Array, page_title := "", page_hint := "") -> void:
	tools = tool_list
	_page.text = page_title + ("   ·   " + page_hint if page_hint != "" else "")
	for b in _slots:
		b.queue_free()
	_slots.clear()
	for i in tools.size():
		var b := Button.new()
		b.text = "%s\n%d" % [tools[i].name, i + 1]
		b.custom_minimum_size = Vector2(SLOT, SLOT)
		b.size = Vector2(SLOT, SLOT)
		b.focus_mode = Control.FOCUS_NONE
		var idx := i
		b.pressed.connect(func(): _choose(idx))
		b.mouse_entered.connect(func(): _set_hover(idx))
		add_child(b)
		_slots.append(b)


func _layout() -> void:
	var c := size / 2.0
	var r := minf(RADIUS, minf(size.x, size.y) / 2.0 - SLOT * 0.6)
	for i in _slots.size():
		var a := -PI / 2.0 + TAU * i / _slots.size()
		_slots[i].position = c + Vector2(cos(a), sin(a)) * r - Vector2(SLOT, SLOT) / 2.0
	_title.position = c + Vector2(-90, -26)
	_title.size = Vector2(180, 28)
	_detail.position = c + Vector2(-80, 4)
	_detail.size = Vector2(160, 40)
	_page.position = c + Vector2(-200, -r - SLOT * 0.5 - 36)
	_page.size = Vector2(400, 24)


func open(current_index: int) -> void:
	current = current_index
	hover = -1
	_vec = Vector2.ZERO
	visible = true
	_layout()
	_refresh()


## Closes the wheel. Returns the picked index when commit is true and a slot is highlighted.
func close(commit: bool) -> int:
	if not visible:
		return -1
	visible = false
	return hover if commit else -1


## Accumulates pointer motion (mouse relative or right stick) into a direction.
func point(delta: Vector2) -> void:
	_vec = (_vec + delta).limit_length(120.0)
	if _vec.length() < 30.0:
		return
	var a := fposmod(_vec.angle() + PI / 2.0, TAU)
	_set_hover(int(round(a / (TAU / tools.size()))) % tools.size())


## Absolute stick direction (right stick held away from centre).
func aim(stick: Vector2) -> void:
	if stick.length() < 0.5:
		return
	_vec = stick * 100.0
	point(Vector2.ZERO)


func _set_hover(i: int) -> void:
	if i != hover:
		hover = i
		Input.start_joy_vibration(0, 0.1, 0.0, 0.03)
		_refresh()


func _choose(i: int) -> void:
	hover = i
	visible = false
	picked.emit(i)


func _refresh() -> void:
	for i in _slots.size():
		var b := _slots[i]
		b.modulate = Color("ff8a3d") if i == hover else (Color(1, 1, 1, 1) if i == current else Color(0.85, 0.88, 0.92, 0.9))
	if tools.is_empty():
		return
	var t: Dictionary = tools[hover if hover >= 0 else clampi(current, 0, tools.size() - 1)]
	_title.text = t.name.to_upper()
	_detail.text = "%s\n%s" % [t.pri, t.alt]
