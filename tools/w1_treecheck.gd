extends Node3D

## Dev harness: drops a few assets from the third-party forest pack into the real area
## and renders them, to check that the materials import correctly, the foliage cards
## cut out instead of blending, and the scale matches the buildings.
##
##   godot --path . res://tools/w1_treecheck.tscn

const SCENE := "res://scenes/areas/vizima_outskirts.tscn"
const PACK := "res://assets/forest/forest_assets.glb"
const SHOT := "user://shots/treecheck.png"
const FOLIAGE := preload("res://shaders/w1_foliage.gdshader")

## Asset name -> where to stand it, on the open field north-west of the bridge.
const PLACEMENTS := {
	"FirTree_17": Vector3(1470, 0, -1320),
	"Oak_25": Vector3(1510, 0, -1310),
	"Birch2_21": Vector3(1550, 0, -1322),
	"Maple_24": Vector3(1590, 0, -1306),
	"HollyShrub_4": Vector3(1440, 0, -1300),
	"BoulderMossyLarge_6": Vector3(1620, 0, -1330),
}


func _ready() -> void:
	var scene: PackedScene = load(SCENE)
	if scene == null:
		printerr("treecheck: cannot load ", SCENE)
		get_tree().quit(1)
		return
	var area := scene.instantiate() as Node3D
	add_child(area)

	var packed: PackedScene = load(PACK)
	if packed == null:
		printerr("treecheck: cannot load ", PACK)
		get_tree().quit(1)
		return
	var pack := packed.instantiate() as Node3D
	add_child(pack)
	var origin := pack.global_transform

	var placed := 0
	for name in PLACEMENTS:
		var asset := pack.find_child(name, true, false) as Node3D
		if asset == null:
			printerr("treecheck: no asset ", name)
			continue
		var relative := origin.affine_inverse() * asset.global_transform
		asset.reparent(self, false)
		asset.transform = Transform3D(Basis(Vector3.UP, randf() * TAU), PLACEMENTS[name]) * relative
		_apply_foliage(asset)
		placed += 1
	pack.queue_free()
	print("treecheck: placed ", placed, " assets")

	var cam := Camera3D.new()
	cam.fov = 68.0
	cam.far = 20000.0
	add_child(cam)
	cam.look_at_from_position(Vector3(1500, 14, -1250), Vector3(1530, 8, -1320), Vector3.UP)
	cam.make_current()

	for i in 30:
		await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://shots"))
	get_viewport().get_texture().get_image().save_png(SHOT)
	print("treecheck: done")
	get_tree().quit()


## Swaps the pack's PBR materials for the foliage shader so the trees sit in the same
## tonal range as the baked, unshaded ground.
func _apply_foliage(root: Node) -> void:
	for mi in W1Area.meshes_in(root):
		for si in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(si) as StandardMaterial3D
			if src == null or src.albedo_texture == null:
				continue
			var mat := ShaderMaterial.new()
			mat.shader = FOLIAGE
			mat.set_shader_parameter("albedo_tex", src.albedo_texture)
			mi.set_surface_override_material(si, mat)
