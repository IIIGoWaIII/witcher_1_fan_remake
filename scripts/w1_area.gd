@tool
class_name W1Area
extends Node3D

## Rebuilds a Witcher 1 area in Godot from the pipeline in tools/witcher1.
##
## The exported GLBs carry geometry plus a material name contract; the original
## textures and lightmaps are loose files that this script wires into the
## lightmapped shader. See docs/witcher1-pipeline.md for the export commands.
##
## Material name contract:
##   W1S|<diffuse>|<lightmapSet>|<flags>          static trimesh surface
##   W1T|<d0>,<d1>,<d2>,<d3>|<lightmapSet>|<flags>  texture-paint terrain, COLOR = weights
##   W1X|<shaderName>|<lightmapSet>|<flags>        surface owned by an engine shader

const LIGHTMAPPED_SHADER := preload("res://shaders/w1_lightmapped.gdshader")
const WATER_SHADER := preload("res://shaders/w1_water.gdshader")
const TEXTURE_DIR := "res://assets/witcher1/textures/"
const LIGHTMAP_DIR := "res://assets/witcher1/lightmaps/"

## d = day, r = morning, p = noon, w = evening, n = night.
@export_enum("d", "r", "p", "w", "n") var time_of_day: String = "r"
@export_range(0.0, 1.0, 0.01) var ambient_add: float = 0.15
@export var area_glb: String = "res://assets/witcher1/vizima_outskirts.glb"
@export var props_glb: String = "res://assets/witcher1/vizima_outskirts_props.glb"

## Node name prefixes that should not be drawn (map-edge cover planes).
@export var hidden_prefixes: PackedStringArray = ["Oslona"]

## Hide the original texture-paint terrain. Used by the Terrain3D comparison
## scene, where the ground is drawn by a Terrain3D node instead.
@export var hide_terrain: bool = false

## Follow the Sky3D day/night cycle, swapping the baked lightmap set as the sun moves.
@export var follow_sky: bool = true

## Build static trimesh collision for the imported geometry.
@export var collision_enabled: bool = true

var lightmap_index: Dictionary = {}
var materials: Array[ShaderMaterial] = []
var water_materials: Array[ShaderMaterial] = []
var unresolved: Dictionary = {}

## Water tint per baked time of day. The original keeps its water colours in the
## area's ARE resource, which this module does not contain, so these are authored to
## match the corresponding lightmap set.
const WATER_SKY := {
	"d": Color(0.56, 0.68, 0.82),
	"r": Color(0.62, 0.68, 0.72),
	"p": Color(0.52, 0.66, 0.82),
	"w": Color(0.72, 0.58, 0.46),
	"n": Color(0.12, 0.16, 0.24),
}

## Hour ranges that select each baked lightmap set.
const SKY_HOURS := [[5.0, 10.0, "r"], [10.0, 16.0, "p"], [16.0, 20.5, "w"]]


func _ready() -> void:
	lightmap_index = _read_lightmap_index()
	# Rebuild from scratch so reloading the script in the editor cannot stack a second
	# copy of the map on top of the first.
	for name in ["Area", "Props"]:
		var old := get_node_or_null(name)
		if old != null:
			remove_child(old)
			old.free()
	# Ordinary children, not internal ones: in the editor they show up in the Scene
	# dock so the whole environment is browsable and every mesh can be selected to
	# read its transform. They carry no owner, so they are never written into the
	# saved scene - the area is regenerated from the GLBs on every load.
	var area := _instance(area_glb)
	if area != null:
		area.name = "Area"
		add_child(area)
		if hide_terrain:
			_hide_terrain(area)
		_apply_materials(area)
	var props := _instance(props_glb)
	if props != null:
		props.name = "Props"
		add_child(props)
		_apply_materials(props)
	print("W1Area: %d statics, %d props, %d materials" % [
		_meshes(area).size() if area != null else 0,
		_meshes(props).size() if props != null else 0,
		materials.size()])
	set_ambient(ambient_add)
	set_time_of_day(_sky_hour() if follow_sky else time_of_day)
	for prefix in hidden_prefixes:
		_hide(self, prefix)
	# Collision is runtime only: in the editor it costs seconds on every scene open and
	# is invisible anyway.
	if collision_enabled and not Engine.is_editor_hint():
		for body in [area, props]:
			if body != null:
				_build_collision(body)


## Static trimesh collision for the imported meshes, so a character can walk the map.
## Water and other engine-shader surfaces stay non-solid. The cover planes are already
## hidden by the time this runs, so they are skipped.
func _build_collision(root: Node) -> void:
	var built := 0
	for mi in _meshes(root):
		if not mi.is_visible_in_tree():
			continue
		var src := mi.mesh.surface_get_material(0) if mi.mesh.get_surface_count() > 0 else null
		if src != null and String(src.resource_name).begins_with("W1X"):
			continue
		mi.create_trimesh_collision()
		built += 1
	print("W1Area: %d collision shapes" % built)


## Re-target every material at a different baked time of day.
func set_time_of_day(tag: String) -> void:
	time_of_day = tag
	for m in materials:
		var set_name := String(m.get_meta("lightmap_set", ""))
		if set_name.is_empty():
			continue
		var stem := resolve_lightmap(set_name, tag)
		if stem.is_empty():
			continue
		var tex := load(LIGHTMAP_DIR + stem + ".png") as Texture2D
		if tex != null:
			m.set_shader_parameter("lightmap_tex", tex)
	for w in water_materials:
		w.set_shader_parameter("sky_color", WATER_SKY.get(tag, WATER_SKY["d"]))


func _process(_delta: float) -> void:
	if not follow_sky:
		return
	var tag := _sky_hour()
	if tag != time_of_day:
		set_time_of_day(tag)


## Which baked lightmap set matches the sky's current hour.
func _sky_hour() -> String:
	var sky := get_node_or_null("Sky3D")
	if sky == null or not ("current_time" in sky):
		return time_of_day
	var hour := float(sky.get("current_time"))
	for band in SKY_HOURS:
		if hour >= band[0] and hour < band[1]:
			return band[2]
	return "n"


func set_ambient(value: float) -> void:
	ambient_add = value
	for m in materials:
		m.set_shader_parameter("ambient_add", value)


func resolve_lightmap(set_name: String, tag: String) -> String:
	var entry: Variant = lightmap_index.get(set_name.to_lower())
	if entry is not Dictionary:
		return ""
	var variants: Dictionary = entry
	if variants.has(tag):
		return String(variants[tag])
	for t in ["r", "p", "d", "w", "n"]:
		if variants.has(t):
			return String(variants[t])
	return ""


func _instance(path: String) -> Node3D:
	var packed: PackedScene = load(path)
	if packed == null:
		push_warning("W1Area: could not load " + path)
		return null
	return packed.instantiate() as Node3D


func _apply_materials(root: Node) -> void:
	for mi in _meshes(root):
		for si in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(si)
			if src == null:
				continue
			var mat := _build_material(String(src.resource_name))
			if mat != null:
				mi.set_meta("w1_material", String(src.resource_name))
				mi.set_meta("w1_kind", String(src.resource_name).split("|")[0])
				mi.set_surface_override_material(si, mat)


func _build_material(name: String) -> Material:
	var parts := name.split("|")
	if parts.size() < 4:
		return null
	var kind := parts[0]
	if kind == "W1X":
		if parts[1] == "proc_water":
			var water := ShaderMaterial.new()
			water.shader = WATER_SHADER
			water_materials.append(water)
			return water
		unresolved[parts[1]] = int(unresolved.get(parts[1], 0)) + 1
		return null

	var mat := ShaderMaterial.new()
	mat.shader = LIGHTMAPPED_SHADER
	mat.set_meta("lightmap_set", parts[2])
	mat.set_shader_parameter("painted", kind == "W1T")
	mat.set_shader_parameter("alpha_cut", (int(parts[3]) & 1) != 0)
	var names := parts[1].split(",", true)
	var has_diffuse := false
	for slot in 4:
		var tex: Texture2D = _white()
		if slot < names.size() and names[slot] != "":
			tex = _texture(TEXTURE_DIR, names[slot])
			has_diffuse = true
		mat.set_shader_parameter("d%d" % slot, tex)
	var lm: Texture2D = _white()
	var has_lightmap := false
	if parts[2] != "":
		var stem := resolve_lightmap(parts[2], time_of_day)
		if stem != "":
			lm = _texture(LIGHTMAP_DIR, stem)
			has_lightmap = true
	mat.set_shader_parameter("lightmap_tex", lm)
	mat.set_shader_parameter("lightmap_albedo", not has_diffuse and has_lightmap)
	mat.set_shader_parameter("flat_shade", not has_diffuse and not has_lightmap)
	mat.set_shader_parameter("ambient_add", ambient_add)
	materials.append(mat)
	return mat


func _texture(dir: String, stem: String) -> Texture2D:
	var tex := load(dir + stem + ".png") as Texture2D
	if tex == null:
		if not unresolved.has(stem):
			unresolved[stem] = 0
		unresolved[stem] = int(unresolved[stem]) + 1
		return _white()
	return tex


var _white_tex: Texture2D


func _white() -> Texture2D:
	if _white_tex == null:
		var img := Image.create(4, 4, true, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_white_tex = ImageTexture.create_from_image(img)
	return _white_tex


func _read_lightmap_index() -> Dictionary:
	var f := FileAccess.open(LIGHTMAP_DIR + "index.json", FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


static func meshes_in(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children(true):
			stack.push_back(c)
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			out.append(mi)
	return out


func _meshes(root: Node) -> Array[MeshInstance3D]:
	return meshes_in(root)


func _hide(root: Node, prefix: String) -> void:
	for mi in _meshes(root):
		if String(mi.name).begins_with(prefix):
			mi.visible = false


## Hides the 186 texture-paint terrain meshes while keeping buildings, props,
## roads baked into static meshes and the water visible. Must run before
## _apply_materials(), which replaces the source material names.
func _hide_terrain(root: Node) -> void:
	var hidden := 0
	for mi in _meshes(root):
		if mi.mesh.get_surface_count() == 0:
			continue
		var src := mi.mesh.surface_get_material(0)
		if src != null and String(src.resource_name).begins_with("W1T"):
			mi.visible = false
			hidden += 1
	print("W1Area: hid %d terrain meshes" % hidden)
