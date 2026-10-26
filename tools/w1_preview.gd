extends Node3D

## Dev harness: loads the real area scene, then renders a set of stills from the
## map's own spawnpoints so visual regressions are easy to spot.
##
##   godot --path . res://tools/w1_preview.tscn
##
## Shots land in user://shots. Nothing here is part of the game.

const SCENE := "res://scenes/areas/vizima_outskirts.tscn"
const SHOT_DIR := "user://shots"

## Viewpoints: name -> [camera position, look-at target].
const VIEWS := {
	"inn": [Vector3(1652, 9, -1342), Vector3(1592, 4, -1418)],
	"village": [Vector3(1820, 9, -1505), Vector3(1640, 4, -1650)],
	"village_eye": [Vector3(1712, 4, -1700), Vector3(1600, 3, -1780)],
	"river": [Vector3(1420, 6, -1690), Vector3(1620, 0, -1770)],
}

## Spawnpoints to shoot from, in order. Each frames the spawnpoint's own facing.
const SPOTS := [
	"haren_house_spdp", "Mikul_spdp", "abigail_out", "final_fight",
	"spawn_drowner1", "barg_milit01",
]

## Times of day rendered from the village view, to compare the baked lightmaps.
const TOD_SWEEP := ["r", "p", "w", "n"]

## Hours driven through Sky3D, to check that the sky and the lightmap set agree.
const SKY_SWEEP := [6.0, 9.5, 13.0, 18.5, 22.0]

## Ambient values rendered from the reference view, to judge the light model.
const AMBIENT_SWEEP := [0.0, 0.15, 0.30, 0.45]

var area: W1Area
var cam: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var scene: PackedScene = load(SCENE)
	if scene == null:
		printerr("preview: cannot load ", SCENE)
		get_tree().quit(1)
		return
	area = scene.instantiate() as W1Area
	add_child(area)
	cam = _camera(area)
	if cam == null:
		printerr("preview: no Camera3D in ", SCENE)
		get_tree().quit(1)
		return
	cam.make_current()

	var t0 := Time.get_ticks_msec()
	await get_tree().process_frame
	print("preview: built in ", Time.get_ticks_msec() - t0, " ms, materials=",
		area.materials.size(), " unresolved=", area.unresolved.keys())

	print("preview: aabb=", _bounds())
	for view in VIEWS:
		await _shot(view, VIEWS[view][0], VIEWS[view][1])

	for spot in SPOTS:
		var p := _spawn(spot)
		if p.is_empty():
			continue
		await _shot(spot, p["pos"], p["pos"] + p["forward"] * 25.0)

	for tod in TOD_SWEEP:
		area.set_time_of_day(tod)
		await _shot("tod_%s" % tod, VIEWS["village"][0], VIEWS["village"][1])
	area.set_time_of_day(area.time_of_day)

	# Sky3D drives the baked lightmap set, so shoot the same view at several hours.
	var sky := area.get_node_or_null("Sky3D")
	if sky != null:
		var saved := float(sky.get("current_time"))
		for hour in SKY_SWEEP:
			sky.set("current_time", hour)
			await get_tree().process_frame
			await get_tree().process_frame
			var dome: Node = sky.get("sky")
			print("preview: hour=", hour, " tod=", sky.get("current_time"),
				" alt=", dome.get("sun_altitude") if dome else "-",
				" day=", sky.call("is_day"))
			await _shot("sky_%02d" % int(hour), VIEWS["village"][0], VIEWS["village"][1])
		sky.set("current_time", saved)
		await get_tree().process_frame

	var ref := _spawn("final_fight")
	if not ref.is_empty():
		for amb in AMBIENT_SWEEP:
			area.set_ambient(amb)
			await _shot("amb_%02d" % int(amb * 100), ref["pos"],
				ref["pos"] + ref["forward"] * 25.0)

	print("preview: done")
	get_tree().quit()


func _shot(name: String, from: Vector3, to: Vector3) -> void:
	cam.look_at_from_position(from, to, Vector3.UP)
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, name])
	print("preview: shot ", name)


func _camera(root: Node) -> Camera3D:
	for child in root.get_children():
		var c := child as Camera3D
		if c != null:
			return c
	return null


func _spawn(name: String) -> Dictionary:
	var f := FileAccess.open("res://assets/witcher1/props.json", FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not data is Dictionary:
		return {}
	for s in data.get("spawns", []):
		if String(s.get("name", "")) != name:
			continue
		var p: Array = s["pos"]
		var q: Array = s["quat"]
		var basis := _witcher_basis(q[0], q[1], q[2], q[3])
		return {"pos": Vector3(p[0], p[1], p[2]), "forward": -basis.z.normalized()}
	return {}


## Witcher (Z-up) quaternion -> Godot (Y-up) basis, matching the exporter.
func _witcher_basis(qx: float, qy: float, qz: float, qw: float) -> Basis:
	var v := Vector3(qx, qz, -qy)
	var b := Basis()
	b.x = Vector3(1 - 2 * (v.y * v.y + v.z * v.z), 2 * (v.x * v.y + qw * v.z), 2 * (v.x * v.z - qw * v.y))
	b.y = Vector3(2 * (v.x * v.y - qw * v.z), 1 - 2 * (v.x * v.x + v.z * v.z), 2 * (v.y * v.z + qw * v.x))
	b.z = Vector3(2 * (v.x * v.z + qw * v.y), 2 * (v.y * v.z - qw * v.x), 1 - 2 * (v.x * v.x + v.y * v.y))
	return b


func _bounds() -> AABB:
	var result := AABB()
	var first := true
	for mi in W1Area.meshes_in(area):
		if not mi.is_visible_in_tree():
			continue
		var b := mi.global_transform * mi.get_aabb()
		if first:
			result = b
			first = false
		else:
			result = result.merge(b)
	return result
