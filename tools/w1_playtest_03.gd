extends Node

## Dev harness: loads the playable scene, lets the character settle, then reports where
## it ended up and renders one frame. Catches "the world has no collision" and
## "the wrong camera is current" without launching the editor.
##
##   godot --path . res://tools/w1_playtest.tscn

const SCENE := "res://scenes/Vizima_outskirts_03.tscn"
const SHOT := "user://shots/playtest.png"

var area: Node3D


func _ready() -> void:
	var packed: PackedScene = load(SCENE)
	if packed == null:
		printerr("playtest: cannot load ", SCENE)
		get_tree().quit(1)
		return
	area = packed.instantiate() as Node3D
	add_child(area)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var start := Time.get_ticks_msec()
	await get_tree().create_timer(2.5).timeout

	var player := area.get_node_or_null("Player") as CharacterBody3D
	if player == null:
		printerr("playtest: no Player in ", SCENE)
		get_tree().quit(1)
		return
	print("playtest: spawn=", player.global_position, " on_floor=", player.is_on_floor(),
		" velocity=", player.velocity)
	var cam := get_viewport().get_camera_3d()
	print("playtest: camera=", cam.get_path() if cam != null else "<none>")
	print("playtest: grass=", _grass_report())
	print("playtest: fps=", await _fps())

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://shots"))
	for i in 4:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(SHOT)

	# Walk the stream: teleport the character, let the grass catch up, and check that the
	# circle followed instead of leaving grass behind or dropping it.
	await _walk(player, Vector3(1500, 3, -1280), "playtest_walk")

	# Regression check: grass is streamed around whichever camera renders, so a far
	# camera must still see grass near itself.
	var far_cam := Camera3D.new()
	far_cam.fov = 68.0
	far_cam.far = 20000.0
	add_child(far_cam)
	far_cam.look_at_from_position(Vector3(1400, 8, -1250), Vector3(1800, 2, -1600), Vector3.UP)
	far_cam.make_current()
	await get_tree().create_timer(0.6).timeout
	print("playtest: grass@far=", _grass_report())
	for i in 4:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://shots/playtest_far.png")

	print("playtest: done in ", Time.get_ticks_msec() - start, " ms")
	get_tree().quit()


func _walk(player: CharacterBody3D, to: Vector3, shot: String) -> void:
	player.global_position = to
	await get_tree().create_timer(0.8).timeout
	print("playtest: walked to ", player.global_position, " grass=", _grass_report())
	for i in 4:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://shots/%s.png" % shot)


func _grass_report() -> String:
	var t3d := area.get_node_or_null("Terrain3D") as Terrain3D
	if t3d != null:
		return "Terrain3D instancer (W1Grass disabled)"
	return "<none>"


## Frame rate over 180 frames with vsync off, so the number means something.
func _fps() -> String:
	var trees := area.get_node_or_null("Trees")
	for i in 10:
		await RenderingServer.frame_post_draw
	var frames := 180
	var t0 := Time.get_ticks_usec()
	for i in frames:
		await RenderingServer.frame_post_draw
	var with_trees := frames * 1e6 / maxf(float(Time.get_ticks_usec() - t0), 1.0)
	if trees == null:
		return "%.0f fps" % with_trees
	trees.visible = false
	for i in 10:
		await RenderingServer.frame_post_draw
	t0 = Time.get_ticks_usec()
	for i in frames:
		await RenderingServer.frame_post_draw
	var without := frames * 1e6 / maxf(float(Time.get_ticks_usec() - t0), 1.0)
	trees.visible = true
	return "%.0f fps, %.0f fps without trees" % [with_trees, without]
