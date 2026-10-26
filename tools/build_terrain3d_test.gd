extends SceneTree

## Builds the Terrain3D test data, assets and grass baseline for
## scenes/Vizima_outskirts_03.tscn. Run headless after export_terrain3d.py:
##
##   godot --headless --path . --script res://tools/build_terrain3d_test.gd
##
## It writes:
##   assets/terrain3d/vizima_test/data/*.res
##   assets/terrain3d/vizima_test/assets.tres
##   assets/terrain3d/vizima_test/material.tres
##   assets/terrain3d/vizima_test/grass/<type>.tscn and _mesh.res

const OUT := "res://assets/terrain3d/vizima_test"
const DATA := OUT + "/data"
const GRASS_DIR := OUT + "/grass"
const GRASS_GLB := "res://assets/witcher1/vizima_outskirts_grass.glb"
const GRASS_MANIFEST := "res://assets/witcher1/grass.json"
const TEXTURE_DIR := OUT + "/textures"
const GRASS_TEXTURE_DIR := "res://assets/witcher1/textures"
const GRASS_SHADER := "res://shaders/w1_grass.gdshader"
const TERRAIN_SHADER := "res://shaders/w1_terrain3d.gdshader"


func _initialize() -> void:
	_run()


func _run() -> void:
	var meta := _read_json(OUT + "/terrain.json")
	if meta.is_empty():
		push_error("missing terrain.json; run tools/witcher1/export_terrain3d.py")
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(DATA)
	DirAccess.make_dir_recursive_absolute(GRASS_DIR)
	# Start from a clean region set so repeated builds do not duplicate the
	# imported grass baseline.
	var dir := DirAccess.open(DATA)
	if dir != null:
		for name in dir.get_files():
			dir.remove(name)

	var height := _read_image(OUT + "/" + meta["height"]["file"],
		int(meta["height"]["width"]), int(meta["height"]["height"]))
	var control := _read_image(OUT + "/" + meta["control"]["file"],
		int(meta["control"]["width"]), int(meta["control"]["height"]))
	var color := _read_image(OUT + "/" + meta["color"]["file"],
		int(meta["color"]["width"]), int(meta["color"]["height"]), Image.FORMAT_RGBA8)
	if height == null or control == null or color == null:
		quit(1)
		return

	var assets := _build_assets(meta)
	var material := _build_material(meta)
	if assets == null or material == null:
		quit(1)
		return

	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
	terrain.data_directory = DATA
	get_root().add_child(terrain)
	# Terrain3D creates its data object in _ready, one frame after add_child.
	await process_frame
	await process_frame
	# Region size must be set after _ready; before that the node keeps its
	# default and the import slices at the wrong scale.
	terrain.region_size = int(meta["region_size"])
	terrain.vertex_spacing = float(meta["vertex_spacing"])
	await process_frame
	# The instancer snapshots the asset list when it initializes, so the assets
	# have to be assigned after the node is in the tree and has ticked once.
	terrain.assets = assets
	terrain.material = material
	await process_frame
	await process_frame
	print("Terrain3D assets: %d meshes, %d textures" % [
		terrain.assets.mesh_list.size(), terrain.assets.texture_list.size()])

	var maps: Array[Image] = [height, control, color]
	terrain.data.import_images(maps, Vector3(
		float(meta["height"]["x0"]), 0.0, float(meta["height"]["z0"])), 0.0, 1.0)
	print("Terrain3D: %d regions" % terrain.data.get_region_count())

	var imported := _import_grass(terrain, assets)
	print("Grass: %d baseline instances" % imported)
	terrain.instancer.update_mmis(true)
	await process_frame

	terrain.data.save_directory(DATA)
	print("saved terrain data to ", DATA)

	var err := ResourceSaver.save(assets, OUT + "/assets.tres")
	print("assets.tres: ", error_string(err))
	err = ResourceSaver.save(material, OUT + "/material.tres")
	print("material.tres: ", error_string(err))

	quit(0)


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _read_image(path: String, width: int, height: int, format: int = Image.FORMAT_RF) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("missing " + path)
		return null
	var bytes := f.get_buffer(f.get_length())
	var bpp := 4
	if bytes.size() != width * height * bpp:
		push_error("%s: %d bytes, expected %d" % [path, bytes.size(), width * height * bpp])
		return null
	return Image.create_from_data(width, height, false, format, bytes)


func _build_assets(meta: Dictionary) -> Terrain3DAssets:
	var assets := Terrain3DAssets.new()
	var textures: Array[Terrain3DTextureAsset] = []
	var uv_scale := float(meta.get("texture_uv_scale", 0.5))
	var normal_tex := load(OUT + "/textures/flat_normal.png") as Texture2D
	if normal_tex == null:
		push_warning("missing flat normal texture")
	for i in meta["textures"].size():
		var stem: String = meta["textures"][i]
		var tex := load("%s/%s.png" % [TEXTURE_DIR, stem]) as Texture2D
		if tex == null:
			push_warning("missing terrain texture " + stem)
			continue
		var t := Terrain3DTextureAsset.new()
		t.name = stem
		t.id = i
		t.albedo_texture = tex
		t.normal_texture = normal_tex
		t.uv_scale = uv_scale
		textures.append(t)
	assets.texture_list = textures

	var manifest := _read_json(GRASS_MANIFEST)
	if manifest.is_empty():
		push_error("missing " + GRASS_MANIFEST)
		return null
	var packed := load(GRASS_GLB) as PackedScene
	if packed == null:
		push_error("cannot load " + GRASS_GLB)
		return null
	var root := packed.instantiate()
	var meshes := {}
	for child in root.get_children():
		var mi := child as MeshInstance3D
		if mi != null and mi.mesh != null:
			meshes[String(mi.name)] = mi
	var mesh_assets: Array[Terrain3DMeshAsset] = []
	var id := 0
	for model in manifest["types"]:
		var mi: MeshInstance3D = meshes.get(model)
		if mi == null:
			push_warning("grass mesh missing: " + model)
			continue
		var mesh_path := "%s/%s_mesh.res" % [GRASS_DIR, model]
		var err := ResourceSaver.save(mi.mesh, mesh_path)
		if err != OK:
			push_error("save %s: %s" % [mesh_path, error_string(err)])
			continue
		var holder := MeshInstance3D.new()
		holder.name = model
		holder.mesh = load(mesh_path)
		var scene := PackedScene.new()
		scene.pack(holder)
		holder.free()
		var scene_path := "%s/%s.tscn" % [GRASS_DIR, model]
		err = ResourceSaver.save(scene, scene_path)
		if err != OK:
			push_error("save %s: %s" % [scene_path, error_string(err)])
			continue

		var mat := _grass_material(mi, manifest["types"][model])
		var a := Terrain3DMeshAsset.new()
		a.name = model
		a.id = id
		a.scene_file = load(scene_path)
		a.material_override = mat
		a.density = 1.0
		a.last_lod = 0
		a.last_shadow_lod = 0
		a.lod0_range = 200.0
		a.cast_shadows = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh_assets.append(a)
		id += 1
		print("grass asset ", model, " id ", a.id)
	root.free()
	assets.mesh_list = mesh_assets
	return assets


func _grass_material(mi: MeshInstance3D, entry: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(GRASS_SHADER)
	var src := mi.mesh.surface_get_material(0)
	var parts := String(src.resource_name if src != null else "").split("|")
	var stem := parts[1] if parts.size() > 1 else ""
	var tex := load("%s/%s.png" % [GRASS_TEXTURE_DIR, stem]) as Texture2D
	if tex != null:
		mat.set_shader_parameter("d0", tex)
	var tint: Array = entry.get("tint", [0.588, 0.588, 0.588])
	mat.set_shader_parameter("tint", Color(tint[0], tint[1], tint[2]))
	mat.set_shader_parameter("light", 1.0)
	return mat


func _build_material(meta: Dictionary) -> Terrain3DMaterial:
	var mat := Terrain3DMaterial.new()
	mat.shader_override = load(TERRAIN_SHADER)
	mat.shader_override_enabled = true
	mat.world_background = 0
	mat.auto_shader = false
	mat.show_checkered = false
	return mat


func _import_grass(terrain: Terrain3D, assets: Terrain3DAssets) -> int:
	var manifest := _read_json(GRASS_MANIFEST)
	var id := 0
	var total := 0
	for model in manifest["types"]:
		var asset := _find_asset(assets, model)
		if asset == null:
			continue
		var data := _read_bin("res://assets/witcher1/grass_%s.bin" % model)
		if data.is_empty():
			continue
		var count := data.size() / 6
		var transforms: Array[Transform3D] = []
		transforms.resize(count)
		for i in count:
			var o := i * 6
			var basis := Basis(Vector3.UP, data[o + 3]).scaled(Vector3.ONE * data[o + 4])
			transforms[i] = Transform3D(basis, Vector3(data[o], data[o + 1], data[o + 2]))
		terrain.instancer.add_transforms(asset.id, transforms, PackedColorArray(), false)
		print("grass ", model, " id ", asset.id, " ", count)
		total += count
		id += 1
	return total


func _find_asset(assets: Terrain3DAssets, model: String) -> Terrain3DMeshAsset:
	for a in assets.mesh_list:
		if a.name == model:
			return a
	return null


func _read_bin(path: String) -> PackedFloat32Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("missing " + path)
		return PackedFloat32Array()
	var out := f.get_buffer(f.get_length()).to_float32_array()
	return out
