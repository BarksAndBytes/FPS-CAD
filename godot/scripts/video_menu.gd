extends CanvasLayer
## The video board's menu: what to play on the board the player aimed at. A web link (the text
## pad), a video already downloaded or converted (the library in user://videos, newest first, each
## with its size and date and a Delete button), or a file on this device through the system's own
## file picker (Windows' Open dialog; Android's document picker, whose content:// files the board
## copies in first). Works with a controller, the mouse or touch; B / Esc closes it.

const UiTheme := preload("res://scripts/ui_theme.gd")
const Whiteboard := preload("res://scripts/whiteboard.gd")
const VIDEO_FILTERS := ["*.mp4, *.m4v, *.mov, *.webm, *.mkv, *.ogv, *.ogg, *.avi, *.mpg, *.mpeg, *.ts, *.flv ; Videos"]

var game: Node  # main.gd
var board: Node3D = null
var _panel := PanelContainer.new()
var _summary: Label
var _list := VBoxContainer.new()
var _link_button: Button
var _file_button: Button
var _clear_button: Button


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
	col.custom_minimum_size = Vector2(620, 0)
	_panel.add_child(col)
	col.add_child(UiTheme.title("VIDEO FOR THIS BOARD", 22))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	_link_button = _button("Enter a link…", func(): _choose_link())
	_file_button = _button("Choose a file on this device…", func(): _choose_file())
	for b in [_link_button, _file_button]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	var head := HBoxContainer.new()
	col.add_child(head)
	_summary = UiTheme.text("", 15, UiTheme.MUTED)
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_summary)
	_clear_button = _button("Delete all", func(): _delete_all())
	head.add_child(_clear_button)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 320)
	_list.add_theme_constant_override("separation", 6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	col.add_child(scroll)
	UiTheme.scroll_everywhere(scroll)
	var close := _button("Close", func(): close())
	col.add_child(close)


func _button(label: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 44)
	b.pressed.connect(action)
	return b


## Opens the menu for board b.
func open(b: Node3D) -> void:
	board = b
	_file_button.visible = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	refresh()
	visible = true
	(_link_button as Control).grab_focus.call_deferred()


func close() -> void:
	visible = false
	var owner_focus: Control = get_viewport().gui_get_focus_owner() if get_viewport() != null else null
	if owner_focus != null and _panel.is_ancestor_of(owner_focus):
		owner_focus.release_focus()


func keep_focus() -> void:
	if visible:
		UiTheme.keep_focus(_panel, _link_button)


## Lists the kept videos again (after a delete, or a new download).
func refresh() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var items: Array = Whiteboard.library()
	var total := 0
	for e in items:
		total += int(e.bytes)
	_summary.text = ("Downloaded videos  ·  %d  ·  %s" % [items.size(), size_text(total)]) if not items.is_empty() \
		else "No downloaded videos yet. Links you play are kept here."
	_clear_button.visible = not items.is_empty()
	for e in items:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var play := Button.new()
		play.text = "%s\n%s  ·  %s" % [_short(String(e.title), 52), size_text(int(e.bytes)),
			Time.get_date_string_from_unix_time(int(e.added))]
		play.alignment = HORIZONTAL_ALIGNMENT_LEFT
		play.clip_text = true
		play.custom_minimum_size = Vector2(0, 58)
		play.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		play.tooltip_text = String(e.link) if String(e.link) != "" else String(e.path)
		var entry: Dictionary = e
		play.pressed.connect(func(): _play(entry))
		row.add_child(play)
		var del := Button.new()
		del.text = "Delete"
		del.custom_minimum_size = Vector2(96, 58)
		del.pressed.connect(func(): _delete(entry))
		row.add_child(del)
		_list.add_child(row)


static func size_text(bytes: int) -> String:
	if bytes >= 1024 * 1048576:
		return "%.1f GB" % (bytes / 1073741824.0)
	if bytes >= 1048576:
		return "%.0f MB" % (bytes / 1048576.0)
	return "%.0f KB" % maxf(1.0, bytes / 1024.0)


static func _short(s: String, n: int) -> String:
	return s if s.length() <= n else s.substr(0, n - 1) + "…"


func _play(entry: Dictionary) -> void:
	close()
	if not is_instance_valid(board):
		return
	# The original link keeps the board's saved link meaningful; the kept copy plays at once.
	var link: String = entry.link if String(entry.link) != "" else entry.path
	game.boards.play_video(board, link, entry.title)


func _delete(entry: Dictionary) -> void:
	game.boards.release_video(entry.path)
	Whiteboard.forget_video(entry.path)
	game.hud.toast("Deleted %s" % _short(String(entry.title), 40))
	refresh()
	keep_focus()


func _delete_all() -> void:
	for e in Whiteboard.library():
		game.boards.release_video(e.path)
		Whiteboard.forget_video(e.path)
	game.hud.toast("Deleted the downloaded videos")
	refresh()
	(_link_button as Control).grab_focus.call_deferred()


func _choose_link() -> void:
	close()
	if is_instance_valid(board):
		game.boards.ask_video_link(board)


func _choose_file() -> void:
	var b := board
	close()
	var filters := PackedStringArray(["video/*"]) if OS.has_feature("android") else PackedStringArray(VIDEO_FILTERS)
	var start := OS.get_system_dir(OS.SYSTEM_DIR_MOVIES) if not OS.has_feature("android") else ""
	var done := func(ok: bool, paths: PackedStringArray, _filter: int) -> void:
		if ok and not paths.is_empty() and is_instance_valid(b):
			game.boards.play_video(b, paths[0])
	var err := DisplayServer.file_dialog_show("Choose a video", start, "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
		filters, done)
	if err != OK:
		game.hud.toast("The file picker didn't open (error %d)" % err)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel") or (event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE):
		close()
		get_viewport().set_input_as_handled()
