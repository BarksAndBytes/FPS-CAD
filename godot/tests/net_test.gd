extends SceneTree
## Multiplayer test: two copies of the game on this machine, a host and a guest, over the real
## network code (net.gd). Run the host:
##
##     godot --headless --path godot --script res://tests/net_test.gd
##
## It hosts the sample part and starts the guest (this script with "-- guest <port> <file>").
## The guest finds the game by its beacon, joins, and then:
## 1. the host adds a box, the guest sees it and adds one of its own, the host sees that;
## 2. both add a box at the same moment: the host merges them, and both end with both;
## 3. the guest asks for undo: the host takes back the latest change, for both;
## 4. a board added by the guest and the part's name changed by the host both arrive;
## 5. the guest changes the part while the host is in a dialog: the change waits, and the host
##    merges it with its own when the dialog closes;
## 6. each sees the other as an avatar that has moved where they stand;
## 7. the guest writes its part to a file and leaves; the host checks the parts are identical.
## Prints PASS / FAIL lines; exits 1 on any failure.

const TIMEOUT := 30.0

var failures := 0
var main: Node


func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


func _initialize() -> void:
	var watchdog := Timer.new()
	watchdog.wait_time = 240.0
	watchdog.one_shot = true
	watchdog.autostart = true
	watchdog.timeout.connect(func():
		printerr("FAIL net test timed out")
		quit(1))
	root.add_child(watchdog)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(5)
	if args.size() >= 3 and args[0] == "guest":
		await _guest(int(args[1]), args[2])
	else:
		await _host()
	main.net.stop(false)
	await _frames(3)
	quit(1 if failures > 0 else 0)


func _host() -> void:
	main._start_mode("free")
	await _frames(5)
	var problem: String = main.net.host()
	check(problem == "", "the sample part is hosted (%s)" % problem)
	if problem != "":
		return
	var start: int = _count()
	var out := OS.get_user_data_dir().path_join("net-test-guest-%d.json" % Time.get_ticks_usec())
	var pid := OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://tests/net_test.gd", "--", "guest", str(main.net.port), out])
	check(pid > 0, "the guest's game starts")
	check(await _until(func(): return main.net.players.size() == 2), "the guest joins (2 players)")

	_box(Vector3(3, 0, 3))
	check(await _until(func(): return _count() == start + 2), "the guest's box arrives after the host's")

	_box(Vector3(-3, 0, 3))  # at the same moment as the guest's
	check(await _until(func(): return _count() == start + 4), "both boxes made at the same moment are kept")
	check(await _until(func(): return _count() == start + 3), "the guest's undo takes back the latest change")

	main.doc.set_part_name("Shared desk")
	check(await _until(func(): return main.doc.get_boards().any(func(d): return d.get("kind") == "notes")), "the guest's new board arrives")
	check(main.boards.extra.any(func(b): return b.kind == "notes" and b.notes == ["from the guest"]), "and stands in the host's room")

	main.dialog.visible = true  # as if a feature dialog were open
	_box(Vector3(0, 0, -4))
	main.player.feet = Vector3(5, 0, 5)  # tells the guest to go ahead
	check(await _until(func(): return not main.net._queue.is_empty()), "the guest's change waits while the host is in a dialog")
	var merges_before: int = main.net.merges
	main.dialog.visible = false
	check(await _until(func(): return _count() == start + 5), "then it is merged with the host's own")
	check(main.net.merges == merges_before + 1, "by the host")
	main.player.feet = Vector3(0, 0, 8)
	var avatar: Node3D = main.net._avatars.values()[0] if not main.net._avatars.is_empty() else null
	check(avatar != null and avatar.visible and _flat(avatar.position).distance_to(Vector2(1, 6)) < 0.5, "the guest is shown where they stand")

	check(await _until(func(): return not OS.is_process_running(pid), 60.0), "the guest finishes")
	check(OS.get_process_exit_code(pid) == 0, "with every check passed")
	check(await _until(func(): return main.net.players.size() == 1), "and leaves the game")
	var theirs := FileAccess.get_file_as_string(out)
	DirAccess.remove_absolute(out)
	check(theirs != "" and theirs == main.doc.state_text(false), "host and guest end with the same part")
	check(main.doc.get_part_name() == "Shared desk", "with the host's new name")


func _guest(port: int, out: String) -> void:
	main._start_mode("new")
	await _frames(5)
	main.player.feet = Vector3(1, 0, 6)
	main.net.listen_for_games(true)
	var found := await _until(func(): return _session_on(port) != "", 10.0)
	check(found, "the guest finds the game by its beacon")
	if found:
		main.net.join(_session_on(port))
	else:
		main.net.join_address("127.0.0.1", port)
	check(await _until(func(): return main.net.role == "guest"), "the guest is welcomed")
	if main.net.role != "guest":
		return
	var start: int = _count()
	check(start > 0 and not main.is_assembly and main.mode == "free", "with the host's part (%d features)" % start)

	check(await _until(func(): return _count() == start + 1), "the host's box arrives")
	_box(Vector3(3, 0, -3))
	check(await _until(_settled), "the host takes the guest's box")

	_box(Vector3(-3, 0, -3))  # at the same moment as the host's
	check(await _until(func(): return _count() == start + 4 and _settled()), "both boxes made at the same moment are kept")
	await _seconds(0.5)
	main.net.request_undo(false)
	check(await _until(func(): return _count() == start + 3), "the guest's undo takes back the latest change, for everyone")

	var b: Node3D = main.boards.add("notes", Vector3(0, main.boards.floor_y(), 5), 0.0, 1.0)
	b.set_notes(["from the guest"])
	main.boards.save()
	check(await _until(func(): return main.doc.get_part_name() == "Shared desk" and _settled()), "the host's new name arrives, and the board is taken")
	check(main.boards.extra.any(func(x): return x.kind == "notes" and x.notes == ["from the guest"]), "with the guest's board still standing")
	check(await _until(func(): return _host_avatar() != null and _flat(_host_avatar().position).distance_to(Vector2(5, 5)) < 0.5), "the host moves (into its dialog)")
	_box(Vector3(0, 0, 4))
	check(await _until(func(): return _count() == start + 5 and _settled()), "a change made during the host's dialog ends up beside the host's")
	var avatar: Node3D = main.net._avatars.values()[0] if not main.net._avatars.is_empty() else null
	check(avatar != null and avatar.visible, "the host is shown as an avatar")
	await _seconds(1.0)
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(main.doc.state_text(false))
	f.close()


## Adds a box as the box tool does (an undo step first).
func _box(at: Vector3) -> void:
	main.doc.checkpoint()
	main.doc.add_primitive("box", at, {w = 0.2, d = 0.2, h = 0.2}, "new-body")
	main._on_model_changed()


## Where p stands on the floor, ignoring height (players fall to the floor).
func _flat(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


func _host_avatar() -> Node3D:
	return main.net._avatars.get(1)


## The guest's game has nothing on its way to the host and agrees with what it last heard.
func _settled() -> bool:
	return main.net._in_flight == "" and main.net._known == main.doc.state_text(false)


## The found game on port, as a key of net.sessions, or "".
func _session_on(port: int) -> String:
	for k in main.net.sessions:
		if int(main.net.sessions[k].port) == port:
			return k
	return ""


func _count() -> int:
	return main.doc.get_features().size() if main.doc != null else -1


func _until(test: Callable, seconds := TIMEOUT) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		if test.call():
			return true
		await process_frame
	return false


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _seconds(t: float) -> void:
	await create_timer(t).timeout
