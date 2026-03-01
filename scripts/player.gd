extends CharacterBody3D

@export var speed = 5.0
@export var jump_velocity = 4.5
@export var mouse_sensitivity = 0.002
@export var rotation_speed = 12.0 

@onready var head = $Head
@onready var fps_camera = $Head/FPS_Camera

# Updated TPS camera nodes
@onready var cam_pivot = $CamPivot
@onready var spring_arm = $CamPivot/SpringArm3D
@onready var tps_camera = $CamPivot/SpringArm3D/TPS_Camera

@onready var model = $geralt

var is_fps = true
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	update_camera_mode()

func _unhandled_input(event):
	if event is InputEventMouseMotion:
		if is_fps:
			# FPS: Rotate the BODY horizontally, HEAD vertically
			rotate_y(-event.relative.x * mouse_sensitivity)
			head.rotation.x -= event.relative.y * mouse_sensitivity
			head.rotation.x = clamp(head.rotation.x, deg_to_rad(-85), deg_to_rad(85))
		else:
			# TPS: Rotate ONLY the CamPivot
			cam_pivot.rotation.y -= event.relative.x * mouse_sensitivity
			cam_pivot.rotation.x -= event.relative.y * mouse_sensitivity
			cam_pivot.rotation.x = clamp(cam_pivot.rotation.x, deg_to_rad(-75), deg_to_rad(75))

	if Input.is_action_just_pressed("switch_camera"):
		is_fps = !is_fps
		update_camera_mode()

func update_camera_mode():
	if is_fps:
		fps_camera.current = true
		
		# Sync rotation so FPS faces where the TPS camera was looking
		self.global_rotation.y = cam_pivot.global_rotation.y
		cam_pivot.rotation = Vector3.ZERO
		model.rotation = Vector3.ZERO
		
		set_model_shadow_mode(GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	else:
		tps_camera.current = true
		
		cam_pivot.rotation = Vector3.ZERO 
		model.rotation = Vector3.ZERO
		
		set_model_shadow_mode(GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
		head.rotation = Vector3.ZERO

func set_model_shadow_mode(mode):
	for child in model.find_children("*", "MeshInstance3D"):
		child.cast_shadow = mode

func _physics_process(delta):
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction = Vector3.ZERO
	
	if is_fps:
		direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	else:
		# Use the CamPivot's direction to walk
		var pivot_basis = cam_pivot.global_transform.basis
		var forward = pivot_basis.z
		var right = pivot_basis.x
		forward.y = 0
		right.y = 0
		direction = (forward * input_dir.y + right * input_dir.x).normalized()
		
		if direction.length() > 0.1:
			var target_dir = atan2(-direction.x, -direction.z) - self.global_rotation.y
			model.rotation.y = lerp_angle(model.rotation.y, target_dir, rotation_speed * delta)

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()
