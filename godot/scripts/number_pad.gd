extends CanvasLayer
## Value entry for dimensions and feature fields. Works with a controller (D-pad and A on the
## keys), a keyboard (type and press Enter) and touch (tap the keys or the field).
##
## Plain numbers are in the document's units; anything else (a variable name, "25 mm",
## "width / 2") is passed to the CAD core as an expression.

const UiTheme := preload("res://scripts/ui_theme.gd")
const KEYS := ["7", "8", "9", "⌫", "4", "5", "6", "Clear", "1", "2", "3", "−", ".", "0", "Cancel", "OK"]
## Text mode (sketch text): letters, digits and a few signs, for a controller or touch.
const TEXT_KEYS := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
	"Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P",
	"A", "S", "D", "F", "G", "H", "J", "K", "L", "-",
	"Z", "X", "C", "V", "B", "N", "M", ".", ",", "/",
	":", "_", "?", "=", "&", "%", "#", "@", "+", "Paste",
	"aA", "Space", "⌫", "Cancel", "OK"]

var _panel := PanelContainer.new()
var _title := Label.new()
var _hint := Label.new()
var _edit := LineEdit.new()
var _ok: Button
var _grid := GridContainer.new()
var _tgrid := GridContainer.new()
var _text_ok: Button
var _letters: Array[Button] = []
var _lower := false
var _text_mode := false
var _allow_empty := false
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
	var grid := _grid
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
	_tgrid.columns = 10
	_tgrid.add_theme_constant_override("h_separation", 4)
	_tgrid.add_theme_constant_override("v_separation", 4)
	_tgrid.visible = false
	col.add_child(_tgrid)
	for k in TEXT_KEYS:
		var b := Button.new()
		b.text = k
		b.custom_minimum_size = Vector2(44, 46)
		b.add_theme_font_size_override("font_size", 18)
		var key: String = k
		b.pressed.connect(func(): _key(key))
		_tgrid.add_child(b)
		if k.length() == 1 and k >= "A" and k <= "Z":
			_letters.append(b)
		if k == "OK":
			_text_ok = b


## Opens the pad. callback(text: String) runs when the value is accepted; cancelling runs nothing.
func ask(title: String, initial: String, hint: String, callback: Callable) -> void:
	_allow_empty = false
	_set_mode(false)
	_open(title, initial, hint, callback)


## Opens the pad for words (sketch text, notes): letters on screen, or type on a keyboard.
## allow_empty: OK with nothing typed hands back "" (a note cleared to delete it).
func ask_text(title: String, initial: String, hint: String, callback: Callable, allow_empty := false) -> void:
	_set_mode(true)
	_set_lower(false)
	_open(title, initial, hint, callback)
	_allow_empty = allow_empty


## Opens the text pad for a web address: lower-case letters to start with, and Paste.
func ask_url(title: String, initial: String, hint: String, callback: Callable) -> void:
	ask_text(title, initial, hint, callback)
	_set_lower(true)


func _set_lower(on: bool) -> void:
	_lower = on
	for b in _letters:
		b.text = b.text.to_lower() if _lower else b.text.to_upper()


func _set_mode(text: bool) -> void:
	_text_mode = text
	_grid.visible = not text
	_tgrid.visible = text
	_panel.custom_minimum_size = Vector2(520, 0) if text else Vector2.ZERO


func _open(title: String, initial: String, hint: String, callback: Callable) -> void:
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
		(_text_ok if _text_mode else _ok).grab_focus.call_deferred()


func close() -> void:
	visible = false
	_cb = Callable()
	var owner_focus: Control = get_viewport().gui_get_focus_owner() if get_viewport() != null else null
	if owner_focus != null and _panel.is_ancestor_of(owner_focus):
		owner_focus.release_focus()


func keep_focus() -> void:
	if visible and Actions.last_device == "controller":
		UiTheme.keep_focus(_panel, _text_ok if _text_mode else _ok)


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
		"aA":
			_set_lower(not _lower)
		"Paste":
			var clip := DisplayServer.clipboard_get().strip_edges()
			if clip != "":
				_edit.text = clip if _fresh else _edit.text + clip
				_fresh = false
		"Space":
			_edit.text = " " if _fresh else _edit.text + " "
			_fresh = false
		_:
			var ch := k.to_lower() if _text_mode and _lower and k.length() == 1 else k
			_edit.text = ch if _fresh else _edit.text + ch
			_fresh = false


func _submit() -> void:
	var text := _edit.text.strip_edges()
	if text == "" and not _allow_empty:
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
