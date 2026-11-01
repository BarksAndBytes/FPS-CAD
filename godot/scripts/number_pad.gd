extends CanvasLayer
## Value entry for dimensions and feature fields. Works with a controller (D-pad and A on the
## keys), a keyboard (type and press Enter) and touch (tap the keys or the field).
##
## Plain numbers are in the document's units; anything else (a variable name, "25 mm",
## "width / 2") is passed to the CAD core as an expression.

const UiTheme := preload("res://scripts/ui_theme.gd")
const KEYS := ["7", "8", "9", "⌫", "4", "5", "6", "Clear", "1", "2", "3", "−", ".", "0", "Cancel", "OK"]

var _panel := PanelContainer.new()
var _title := Label.new()
var _hint := Label.new()
var _edit := LineEdit.new()
var _ok: Button
var _cb := Callable()
var _fresh := true  # the first key press replaces the value shown


func _ready() -> void:
	layer = 25
	visible = false
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	centre.add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.custom_minimum_size = Vector2(380, 0)
	_panel.add_child(col)
	_title = UiTheme.title("", 22)
	col.add_child(_title)
	_hint = UiTheme.text("", 14, UiTheme.MUTED)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_hint)
	_edit.add_theme_font_size_override("font_size", 26)
	_edit.custom_minimum_size = Vector2(0, 52)
	_edit.text_submitted.connect(func(_t): _submit())
	_edit.text_changed.connect(func(_t): _fresh = false)
	col.add_child(_edit)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	col.add_child(grid)
	for k in KEYS:
		var b := Button.new()
		b.text = k
		b.custom_minimum_size = Vector2(84, 54)
		b.add_theme_font_size_override("font_size", 20)
		var key: String = k
		b.pressed.connect(func(): _key(key))
		grid.add_child(b)
		if k == "OK":
			_ok = b


## Opens the pad. callback(text: String) runs when the value is accepted; cancelling runs nothing.
func ask(title: String, initial: String, hint: String, callback: Callable) -> void:
	_title.text = title
	_hint.text = hint
	_edit.text = initial
	_cb = callback
	_fresh = true
	visible = true
	if Actions.last_device == "keyboard":
		_edit.grab_focus.call_deferred()
		_edit.select_all.call_deferred()
	else:
		_ok.grab_focus.call_deferred()


func close() -> void:
	visible = false
	_cb = Callable()
	var owner_focus: Control = get_viewport().gui_get_focus_owner() if get_viewport() != null else null
	if owner_focus != null and _panel.is_ancestor_of(owner_focus):
		owner_focus.release_focus()


func keep_focus() -> void:
	if visible and Actions.last_device == "controller":
		UiTheme.keep_focus(_panel, _ok)


func _key(k: String) -> void:
	match k:
		"OK":
			_submit()
		"Cancel":
			close()
		"Clear":
			_edit.text = ""
			_fresh = false
		"⌫":
			_edit.text = _edit.text.substr(0, maxi(0, _edit.text.length() - 1))
			_fresh = false
		"−":
			_edit.text = _edit.text.substr(1) if _edit.text.begins_with("-") else "-" + _edit.text
			_fresh = false
		_:
			_edit.text = k if _fresh else _edit.text + k
			_fresh = false


func _submit() -> void:
	var text := _edit.text.strip_edges()
	if text == "":
		return
	var cb := _cb
	close()
	if cb.is_valid():
		cb.call(text)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel") or (event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE):
		close()
		get_viewport().set_input_as_handled()
