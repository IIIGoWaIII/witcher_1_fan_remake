extends Node

## Renders the original W1T ground from above into the Terrain3D color map.
##
## The 1 m/px image is the exact albedo-times-lightmap result of the original
## unshaded ground shader at noon. Terrain3D then drapes that image over the
## baked heightfield, which is the literal version of "project the ground
## texture onto the terrain".
##
##   godot --path . res://tools/w1_ortho_ground.tscn

const W := 2048
const H := 1024
const X0 := 1024.0
const Z0 := -2048.0
const SIZE := 1024.0
const OUT_RAW := "res://assets/terrain3d/vizima_test/color.rgba"
const OUT_PNG := "res://assets/terrain3d/vizima_test/ortho_ground.png"


func _ready() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(W, H)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	add_child(viewport)
	await get_tree().process_frame

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = false
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.sdfgi_enabled = false
	env.ssr_enabled = false
	env.glow_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	viewport.add_child(we)

	var area := Node3D.new()
	area.set_script(load("res://scripts/w1_area.gd"))
	area.set("time_of_day", "p")
	area.set("follow_sky", false)
	area.set("collision_enabled", false)
	area.set("hide_terrain", false)
	area.set("props_glb", "")
	viewport.add_child(area)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = SIZE
	cam.near = 0.05
	cam.far = 500.0
	cam.transform = Transform3D(Basis(Vector3.RIGHT, -PI / 2.0),
		Vector3(X0 + W * 0.5, 100.0, Z0 + H * 0.5))
	cam.current = true
	viewport.add_child(cam)

	await get_tree().create_timer(1.0).timeout
	await get_tree().process_frame
	await get_tree().process_frame

	var area_node := area.get_node_or_null("Area") as Node3D
	if area_node == null:
		printerr("ortho: no Area")
		get_tree().quit(1)
		return
	var shown := 0
	for mi in area_node.find_children("*", "MeshInstance3D", true, false):
		var kind := String(mi.get_meta("w1_kind", ""))
		if kind == "W1T":
			mi.visible = true
			shown += 1
		else:
			mi.visible = false
	print("ortho: %d W1T meshes" % shown)

	for i in 4:
		await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	print("ortho: image ", img.get_size(), " format ", img.get_format())
	var f := FileAccess.open(OUT_RAW, FileAccess.WRITE)
	if f == null:
		printerr("ortho: cannot write ", OUT_RAW)
		get_tree().quit(1)
		return
	f.store_buffer(img.get_data())
	f.close()
	img.save_png(OUT_PNG)
	print("ortho: wrote ", OUT_RAW, " and ", OUT_PNG)
	get_tree().quit()
