@tool
class_name W1Grass
extends Node3D

## Streams the area's original grass clumps around the camera.
##
## tools/witcher1/export_grass.py does the placement offline (one flat array of
## transforms per grass type, x/y/z/yaw/scale/phase) because the placement depends on
## the terrain's painted layers, which only the exporter can evaluate. This node then
## buckets those transforms into tiles and only builds the tiles inside `spawn_radius`
## of the camera, discarding them again past `keep_radius`. Nothing is generated at
## runtime: the transforms are the exported ones, they are just instanced on demand.

const GRASS_SHADER := preload("res://shaders/w1_grass.gdshader")
const TEXTURE_DIR := "res://assets/witcher1/textures/"
const GLB := "res://assets/witcher1/vizima_outskirts_grass.glb"
const MANIFEST := "res://assets/witcher1/grass.json"

## Tile edge in world units. Smaller tiles stream tighter but cost more MultiMeshes.
const TILE_SIZE := 64.0

@export var grass_enabled: bool = true
## Tiles whose centre is inside this radius get built.
@export_range(0.0, 1000.0, 1.0) var spawn_radius: float = 200.0
## Tiles outside this radius are freed. Must be larger than `spawn_radius`.
@export_range(0.0, 1200.0, 1.0) var keep_radius: float = 280.0
## How often the tile set is re-evaluated, in seconds.
@export_range(0.05, 2.0, 0.05) var update_interval: float = 0.2

var _types: Array[Dictionary] = []
var _tiles: Dictionary = {}
var _focus := Vector3.INF
var _next_check := 0.0


func _ready() -> void:
	if not grass_enabled:
		return
	var manifest := _read_manifest()
	if manifest.is_empty():
		return
	var scene := load(GLB) as PackedScene
	if scene == null:
		push_warning("W1Grass: cannot load " + GLB)
		return
	var root := scene.instantiate()
	var meshes := {}
	var materials := {}
	for child in root.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		meshes[mi.name] = mi.mesh
		var src := mi.mesh.surface_get_material(0) as Material
		if src != null:
			materials[mi.name] = String(src.resource_name)
	root.free()

	for model in manifest["types"]:
		var mesh: Mesh = meshes.get(model)
		if mesh == null:
			continue
		var mat := _build_material(materials.get(model, ""), manifest["types"][model]["tint"])
		if mat == null:
			continue
		var data := _read_transforms(model)
		if data.is_empty():
			continue
		_types.append({"mesh": mesh, "material": mat, "data": data,
			"tiles": _bucket(data), "patches": data.size() / 6})
	if _types.is_empty():
		return

	var total := 0
	for t in _types:
		total += int(t["patches"])
	print("W1Grass: %d types, %d patches streamed in %d m tiles" % [
		_types.size(), total, int(TILE_SIZE)])
	_focus = _focus_position()
	_refresh()


func _process(delta: float) -> void:
	if _types.is_empty():
		return
	_next_check -= delta
	if _next_check > 0.0:
		return
	_next_check = update_interval
	var here := _focus_position()
	if here.distance_to(_focus) < TILE_SIZE * 0.5:
		return
	_focus = here
	_refresh()


## Builds the tiles around the focus and drops the ones left behind.
func _refresh() -> void:
	var center := _focus
	var r := spawn_radius
	var keep := maxf(keep_radius, r + TILE_SIZE)
	var want := {}
	var x0 := floori((center.x - r) / TILE_SIZE)
	var x1 := floori((center.x + r) / TILE_SIZE)
	var z0 := floori((center.z - r) / TILE_SIZE)
	var z1 := floori((center.z + r) / TILE_SIZE)
	for ti in _types.size():
		var tiles: Dictionary = _types[ti]["tiles"]
		for tx in range(x0, x1 + 1):
			for tz in range(z0, z1 + 1):
				var dx := (tx + 0.5) * TILE_SIZE - center.x
				var dz := (tz + 0.5) * TILE_SIZE - center.z
				if dx * dx + dz * dz > r * r:
					continue
				var key := Vector3i(ti, tx, tz)
				want[key] = true
				if _tiles.has(key):
					continue
				var rows: Variant = tiles.get(Vector2i(tx, tz))
				if rows == null:
					continue
				_tiles[key] = _build_tile(_types[ti], rows)

	var stale: Array = []
	for key: Vector3i in _tiles:
		var dx2 := (key.y + 0.5) * TILE_SIZE - center.x
		var dz2 := (key.z + 0.5) * TILE_SIZE - center.z
		if dx2 * dx2 + dz2 * dz2 > keep * keep:
			stale.append(key)
	for key in stale:
		var mmi: MultiMeshInstance3D = _tiles[key]
		mmi.queue_free()
		_tiles.erase(key)


func _build_tile(type: Dictionary, rows: Array) -> MultiMeshInstance3D:
	var data: PackedFloat32Array = type["data"]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = type["mesh"]
	mm.instance_count = rows.size()
	for j in rows.size():
		var o: int = rows[j] * 6
		var basis := Basis(Vector3.UP, data[o + 3]).scaled(Vector3.ONE * data[o + 4])
		mm.set_instance_transform(j, Transform3D(basis, Vector3(data[o], data[o + 1], data[o + 2])))

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = type["material"]
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Internal, so streamed tiles are never written into the saved scene.
	add_child(mmi, false, Node.INTERNAL_MODE_FRONT)
	return mmi


## Grabs the camera the scene is being rendered with. In the editor that is the 3D
## viewport camera, so the grass streams around wherever you are looking while you
## work on the map.
func _focus_position() -> Vector3:
	var vp: Viewport = null
	if Engine.is_editor_hint():
		var editor := Engine.get_singleton("EditorInterface")
		if editor != null and editor.has_method("get_editor_viewport_3d"):
			vp = editor.call("get_editor_viewport_3d", 0)
	if vp == null:
		vp = get_viewport()
	if vp != null:
		var cam := vp.get_camera_3d()
		if cam != null:
			return cam.global_position
	var parent := get_parent()
	if parent != null:
		var player := parent.get_node_or_null("Player") as Node3D
		if player != null:
			return player.global_position
	return global_position


func _bucket(data: PackedFloat32Array) -> Dictionary:
	var tiles := {}
	var count := data.size() / 6
	for i in count:
		var o := i * 6
		var key := Vector2i(floori(data[o] / TILE_SIZE), floori(data[o + 2] / TILE_SIZE))
		if tiles.has(key):
			tiles[key].append(i)
		else:
			tiles[key] = [i]
	for key in tiles:
		tiles[key] = PackedInt32Array(tiles[key])
	return tiles


func _build_material(name: String, tint: Array) -> ShaderMaterial:
	var parts := name.split("|")
	if parts.size() < 4 or parts[0] != "W1G" or parts[1] == "":
		return null
	var tex := load(TEXTURE_DIR + parts[1] + ".png") as Texture2D
	if tex == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = GRASS_SHADER
	mat.set_shader_parameter("d0", tex)
	mat.set_shader_parameter("tint", Color(tint[0], tint[1], tint[2]))
	mat.set_shader_parameter("light", 1.0)
	return mat


func _read_transforms(model: String) -> PackedFloat32Array:
	var path := GLB.get_base_dir().path_join("grass_%s.bin" % model)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("W1Grass: missing " + path)
		return PackedFloat32Array()
	var data := file.get_buffer(file.get_length()).to_float32_array()
	file.close()
	return data


func _read_manifest() -> Dictionary:
	var file := FileAccess.open(MANIFEST, FileAccess.READ)
	if file == null:
		push_warning("W1Grass: missing " + MANIFEST)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


## Total patches currently instanced, for diagnostics.
func active_patches() -> int:
	var n := 0
	for mmi in _tiles.values():
		n += (mmi as MultiMeshInstance3D).multimesh.instance_count
	return n
