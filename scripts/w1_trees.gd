@tool
class_name W1Trees
extends Node3D

## Places the substitute forest at the area's original SpeedTree transforms.
##
## tools/witcher1/export_trees.py writes one yaw/scale/position per placement (2,813
## of them) because the original SpeedTree descriptors carry no geometry. Those same
## placements already have their shadows baked into the ground lightmaps, so using the
## exact transforms keeps the bake lined up.
##
## Every tree is its own MeshInstance3D rather than a MultiMesh: the glTF import
## generates automatic mesh LODs, and those apply per instance only for MeshInstance3D.
## A MultiMesh has one bounding box, so all of its instances would share a single LOD.
## Per-instance frustum culling matters here too - most of a 400 m circle is behind you.

const PACK := "res://assets/forest/forest_assets.glb"
const MANIFEST := "res://assets/witcher1/trees.json"
const DATA := "res://assets/witcher1/trees.bin"
const FOLIAGE := preload("res://shaders/w1_foliage.gdshader")

@export var trees_enabled: bool = true
@export_range(0.0, 2000.0, 10.0) var visible_distance: float = 400.0

var tree_count: int = 0


func _ready() -> void:
	if not trees_enabled:
		return
	var manifest := _read_json(MANIFEST)
	if manifest.is_empty():
		return
	var packed: PackedScene = load(PACK)
	if packed == null:
		push_warning("W1Trees: cannot load " + PACK)
		return

	var scene := packed.instantiate()
	var parts := {}
	for asset in manifest["assets"]:
		var node := scene.find_child(asset, true, false) as Node3D
		if node == null:
			push_warning("W1Trees: pack has no asset " + asset)
			continue
		var list: Array = []
		for child in node.get_children():
			var mi := child as MeshInstance3D
			if mi == null or mi.mesh == null:
				continue
			var src := mi.mesh.surface_get_material(0) as StandardMaterial3D
			if src == null or src.albedo_texture == null:
				continue
			var mat := ShaderMaterial.new()
			mat.shader = FOLIAGE
			mat.set_shader_parameter("albedo_tex", src.albedo_texture)
			list.append({"mesh": mi.mesh, "material": mat})
		parts[asset] = list
	scene.free()

	var file := FileAccess.open(DATA, FileAccess.READ)
	if file == null:
		push_warning("W1Trees: missing " + DATA)
		return
	var data := file.get_buffer(file.get_length()).to_float32_array()
	file.close()

	var count := data.size() / 6
	for i in count:
		var o := i * 6
		var asset: String = manifest["assets"][int(data[o + 5])]
		var list: Array = parts.get(asset, [])
		if list.is_empty():
			continue
		var xform := Transform3D(
			Basis(Vector3.UP, data[o + 3]).scaled(Vector3.ONE * data[o + 4]),
			Vector3(data[o], data[o + 1], data[o + 2]))
		for part in list:
			var mi := MeshInstance3D.new()
			mi.mesh = part["mesh"]
			mi.material_override = part["material"]
			mi.transform = xform
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			mi.visibility_range_end = visible_distance
			mi.visibility_range_end_margin = 40.0
			# Internal, so thousands of trees never end up in the saved scene or the
			# scene dock - they are regenerated from the exported transforms.
			add_child(mi, false, Node.INTERNAL_MODE_FRONT)
		tree_count += 1
	print("W1Trees: %d trees in %d meshes" % [tree_count, get_child_count(true) - 1])


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("W1Trees: missing " + path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}
