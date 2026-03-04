extends Node3D

@export var sensitivity: float = 5.0 # Kept as float for smoother division

@onready var head = $Head
@onready var fps_camera = $Head/FPS_Camera
@onready var cam_pivot = $CamPivot
@onready var tps_camera = $CamPivot/SpringArm3D/TPS_Camera

var player: CharacterBody3D
var model: Node3D
var is_fps = true

# Store the -180 degree rotation in radians (-PI) so we don't accidentally snap to 0
const Y_OFFSET = -PI 

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Get references from the parent Player node
	player = get_parent()
	model = player.get_node("geralt")
	
	# Ensure base rotations start with your -180 offset applied
	head.rotation.y = Y_OFFSET
	cam_pivot.rotation.y = Y_OFFSET
	
	update_camera_mode()

func _unhandled_input(event):
	if event is InputEventMouseMotion:
		# Match your new sensitivity math
		var actual_sens = sensitivity / 1000.0
		
		if is_fps:
			# FPS: Rotate player body left/right
			player.rotate_y(-event.relative.x * actual_sens)
			# FPS: Rotate head up/down
			head.rotation.x -= event.relative.y * actual_sens
			head.rotation.x = clamp(head.rotation.x, deg_to_rad(-85), deg_to_rad(85))
		else:
			# TPS: Rotate camera pivot left/right
			cam_pivot.rotation.y -= event.relative.x * actual_sens
			# TPS: Rotate camera pivot up/down
			cam_pivot.rotation.x -= event.relative.y * actual_sens
			cam_pivot.rotation.x = clamp(cam_pivot.rotation.x, deg_to_rad(-75), deg_to_rad(75))

	if Input.is_action_just_pressed("switch_camera"):
		is_fps = !is_fps
		update_camera_mode()

func update_camera_mode():
	if is_fps:
		fps_camera.current = true
		
		# Align player's real forward to camera's visual forward, subtracting the 180-degree offset
		player.global_rotation.y = cam_pivot.global_rotation.y - Y_OFFSET
		
		# Reset Pivot, maintaining the 180 degree Y rotation instead of Vector3.ZERO
		cam_pivot.rotation = Vector3(0, Y_OFFSET, 0)
		model.rotation = Vector3.ZERO
		set_model_shadow_mode(GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	else:
		tps_camera.current = true
		
		# Reset Pivots, maintaining the 180 degree Y rotation instead of Vector3.ZERO
		cam_pivot.rotation = Vector3(0, Y_OFFSET, 0)
		head.rotation = Vector3(0, Y_OFFSET, 0)
		model.rotation = Vector3.ZERO
		set_model_shadow_mode(GeometryInstance3D.SHADOW_CASTING_SETTING_ON)

func set_model_shadow_mode(mode):
	for child in model.find_children("*", "MeshInstance3D"):
		child.cast_shadow = mode
