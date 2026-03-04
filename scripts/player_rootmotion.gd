extends CharacterBody3D

@export var mouse_sensitivity = 0.002
@export var rotation_speed = 12.0 

@onready var head = $Head
@onready var fps_camera = $Head/FPS_Camera
@onready var cam_pivot = $CamPivot
@onready var tps_camera = $CamPivot/SpringArm3D/TPS_Camera

@onready var model = $geralt_anim_testglb 
@onready var anim_tree = $AnimationTree
@onready var playback = anim_tree["parameters/playback"]

var is_fps = true
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	anim_tree.active = true
	update_camera_mode()

func _unhandled_input(event):
	if event is InputEventMouseMotion:
		if is_fps:
			rotate_y(-event.relative.x * mouse_sensitivity)
			head.rotation.x -= event.relative.y * mouse_sensitivity
			head.rotation.x = clamp(head.rotation.x, deg_to_rad(-85), deg_to_rad(85))
		else:
			cam_pivot.rotation.y -= event.relative.x * mouse_sensitivity
			cam_pivot.rotation.x -= event.relative.y * mouse_sensitivity
			cam_pivot.rotation.x = clamp(cam_pivot.rotation.x, deg_to_rad(-75), deg_to_rad(75))

	if Input.is_action_just_pressed("switch_camera"):
		is_fps = !is_fps
		update_camera_mode()

func update_camera_mode():
	if is_fps:
		fps_camera.current = true
		# 180-degree fix: face the camera direction
		self.global_rotation.y = cam_pivot.global_rotation.y + PI
		cam_pivot.rotation = Vector3.ZERO
		model.rotation = Vector3.ZERO
	else:
		tps_camera.current = true
		cam_pivot.rotation = Vector3.ZERO 
		model.rotation = Vector3.ZERO
		head.rotation = Vector3.ZERO

func _physics_process(delta):
	# 1. Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# 2. Input
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var is_sprinting = Input.is_action_pressed("sprint")

	# 3. Animation State & BlendSpace (Smooth Transitions)
	if input_dir.length() > 0.1:
		if is_sprinting and input_dir.y < -0.1:
			playback.travel("sprint")
		else:
			playback.travel("Walk")
			# This line does what the video suggests: 
			# It sends the input direction to the BlendSpace
			var current_blend = anim_tree.get("parameters/Walk/blend_position")
			anim_tree.set("parameters/Walk/blend_position", lerp(current_blend, input_dir, delta * 10.0))
	else:
		playback.travel("idle")

	# 4. Root Motion Movement (The "Video" Math)
	var current_rotation = self.global_transform.basis.get_rotation_quaternion()
	var motion = anim_tree.get_root_motion_position()
	
	# Divide by delta to convert distance to velocity (as seen in video at 30:30)
	var velocity_coords = (current_rotation * motion) / delta
	
	velocity.x = velocity_coords.x
	velocity.z = velocity_coords.z

	# 5. TPS Rotation (Align Geralt with Camera)
	if not is_fps and input_dir.length() > 0.1:
		var pivot_basis = cam_pivot.global_transform.basis
		
		# 180-degree fix for your specific setup
		var forward = -pivot_basis.z 
		var right = -pivot_basis.x
		
		# Calculate the target direction Geralt should face
		var direction = (forward * input_dir.y + right * input_dir.x).normalized()
		var target_angle = atan2(-direction.x, -direction.z) - self.global_rotation.y
		
		# Smoothly rotate the model to face that direction
		model.rotation.y = lerp_angle(model.rotation.y, target_angle, rotation_speed * delta)

	move_and_slide()
