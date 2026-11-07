extends CanvasLayer
## The Open browser: every part and assembly saved in user://projects, most recently changed first,
## each with its kind, size and date, to open, duplicate or delete (Delete asks once more). Also
## opens a file from elsewhere on the device through the system's own picker (Windows' Open dialog;
## Android's document picker, whose content:// files are copied into the projects folder first).
## Works with a controller, the mouse or touch; B / Esc closes it.

const UiTheme := preload("res://scripts/ui_theme.gd")
const PROJECTS := "user://projects"
const KINDS := {"fpprt": "Part", "fpasm": "Assembly"}

var game: Node  # main.gd
var _panel := PanelContainer.new()
var _summary: Label
var _list := VBoxContainer.new()
var _device_button: Button
var _close_button: Button
var _armed := ""  # the file whose Delete was pressed once


func _ready() -> void:
	layer = 24
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.05, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	centre.add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.custom_minimum_size = Vector2(640, 0)
	_panel.add_child(col)
	col.add_child(UiTheme.title("OPEN", 22))
	_summary = UiTheme.text("", 15, UiTheme.MUTED)
	col.add_child(_summary)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 340)
	_list.add_theme_constant_override("separation", 6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	col.add_child(scroll)
	UiTheme.scroll_everywhere(scroll)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	_device_button = _button("Open a file on this device…", func(): _pick_file())
	_close_button = _button("Close", func(): close())
	for b in [_device_button, _close_button]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)


func _button(label: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 44)
	b.pressed.connect(action)
	return b


func open() -> void:
	_armed = ""
	_device_button.visible = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	refresh()
	visible = true
	var first := UiTheme.first_focusable(_list)
	(first if first != null else _close_button as Control).grab_focus.call_deferred()


func close() -> void:
	visible = false
	var owner_focus: Control = get_viewport().gui_get_focus_owner() if get_viewport() != null else null
	if owner_focus != null and _panel.is_ancestor_of(owner_focus):
		owner_focus.release_focus()


func keep_focus() -> void:
	if visible:
		UiTheme.keep_focus(_panel, _close_button)


## Saved parts and assemblies, newest first: [{path, name, kind, bytes, modified}].
static func saved_files() -> Array:
	var out := []
	var d := DirAccess.open(PROJECTS)
	if d == null:
		return out
	for name in d.get_files():
		var ext := name.get_extension()
		if not KINDS.has(ext):
			continue
		var path := PROJECTS.path_join(name)
		var f := FileAccess.open(path, FileAccess.READ)
		out.append({path = path, name = name.get_basename(), kind = KINDS[ext],
			bytes = f.get_length() if f != null else 0, modified = FileAccess.get_modified_time(path)})
	out.sort_custom(func(a, b): return a.modified > b.modified)
	return out


## A file name in the projects folder for name that isn't taken: "Bracket", "Bracket 2", ...
static func free_path(name: String, ext: String, except := "") -> String:
	var base := name.strip_edges().validate_filename()
	if base == "":
		base = "Part"
	var path := PROJECTS.path_join("%s.%s" % [base, ext])
	var n := 2
	while FileAccess.file_exists(path) and path != except:
		path = PROJECTS.path_join("%s %d.%s" % [base, n, ext])
		n += 1
	return path


func refresh() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var files := saved_files()
	_summary.text = "%d saved  ·  %s" % [files.size(), ProjectSettings.globalize_path(PROJECTS)] if not files.is_empty() \
		else "Nothing saved yet: use Save or Save as in the pause menu."
	for e in files:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var entry: Dictionary = e
		var open_b := Button.new()
		open_b.text = "%s\n%s  ·  %s  ·  %s" % [e.name, e.kind, _size_text(int(e.bytes)),
			Time.get_datetime_string_from_unix_time(int(e.modified), true).substr(0, 16)]
		open_b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		open_b.clip_text = true
		open_b.custom_minimum_size = Vector2(0, 58)
		open_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		open_b.pressed.connect(func(): _open(entry))
		row.add_child(open_b)
		var dup := Button.new()
		dup.text = "Duplicate"
		dup.custom_minimum_size = Vector2(110, 58)
		dup.pressed.connect(func(): _duplicate(entry))
		row.add_child(dup)
		var del := Button.new()
		del.text = "Sure?" if _armed == e.path else "Delete"
		del.custom_minimum_size = Vector2(90, 58)
		del.pressed.connect(func(): _delete(entry))
		row.add_child(del)
		_list.add_child(row)


static func _size_text(bytes: int) -> String:
	return "%.1f MB" % (bytes / 1048576.0) if bytes >= 1048576 else "%.0f KB" % maxf(1.0, bytes / 1024.0)


func _open(entry: Dictionary) -> void:
	close()
	game.open_file(entry.path)


func _duplicate(entry: Dictionary) -> void:
	var to := free_path(String(entry.name) + " copy", String(entry.path).get_extension())
	DirAccess.copy_absolute(ProjectSettings.globalize_path(entry.path), ProjectSettings.globalize_path(to))
	game.hud.toast("Duplicated as %s" % to.get_file().get_basename())
	refresh()
	keep_focus()


func _delete(entry: Dictionary) -> void:
	if _armed != entry.path:
		_armed = entry.path  # the first press arms it; the second deletes
		refresh()
		keep_focus()
		return
	_armed = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(entry.path))
	game.hud.toast("Deleted %s" % entry.name)
	refresh()
	(_close_button as Control).grab_focus.call_deferred()


func _pick_file() -> void:
	close()
	var filters := PackedStringArray(["*/*"]) if OS.has_feature("android") \
		else PackedStringArray(["*.fpprt, *.fpasm ; FPS-CAD parts and assemblies"])
	var done := func(ok: bool, paths: PackedStringArray, _filter: int) -> void:
		if ok and not paths.is_empty():
			game.open_file(paths[0])
	var err := DisplayServer.file_dialog_show("Open a part or assembly", "", "", false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, filters, done)
	if err != OK:
		game.hud.toast("The file picker didn't open (error %d)" % err)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel") or (event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE):
		close()
		get_viewport().set_input_as_handled()
