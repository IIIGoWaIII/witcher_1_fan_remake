extends CharacterBody3D

@export var mouse_sensitivity = 0.002
@export var rotation_speed = 12.0 

@onready var head = $Head
@onready var fps_camera = $Head/FPS_Camera

# Camera nodes for TPS
@onready var cam_pivot = $CamPivot
@onready var tps_camera = $CamPivot/SpringArm3D/TPS_Camera

# Your new model and Animation nodes
@onready var model = $geralt_mixamo_animated 
@onready var anim_tree = $AnimationTree
@onready var playback = anim_tree["parameters/playback"]

var is_fps = true
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

func _ready():
	# Lock the mouse to the center of the screen
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Start the animation system
	anim_tree.active = true
	update_camera_mode()

func _unhandled_input(event):
	# Handle Mouse Movement
	if event is InputEventMouseMotion:
		if is_fps:
			rotate_y(-event.relative.x * mouse_sensitivity)
			head.rotation.x -= event.relative.y * mouse_sensitivity
			head.rotation.x = clamp(head.rotation.x, deg_to_rad(-85), deg_to_rad(85))
		else:
			cam_pivot.rotation.y -= event.relative.x * mouse_sensitivity
			cam_pivot.rotation.x -= event.relative.y * mouse_sensitivity
			cam_pivot.rotation.x = clamp(cam_pivot.rotation.x, deg_to_rad(-75), deg_to_rad(75))

	# Toggle Camera Mode (FPS/TPS)
	if Input.is_action_just_pressed("switch_camera"):
		is_fps = !is_fps
		update_camera_mode()

func update_camera_mode():
	if is_fps:
		fps_camera.current = true
		# Sync rotation so you face the direction the TPS camera was looking
		self.global_rotation.y = cam_pivot.global_rotation.y
		cam_pivot.rotation = Vector3.ZERO
		model.rotation = Vector3.ZERO
	else:
		tps_camera.current = true
		cam_pivot.rotation = Vector3.ZERO 
		model.rotation = Vector3.ZERO
		head.rotation = Vector3.ZERO

func _physics_process(delta):
	# 1. APPLY GRAVITY
	if not is_on_floor():
		velocity.y -= gravity * delta

	# 2. GET INPUT
	# Make sure these actions match your Project Settings > Input Map
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var is_sprinting = Input.is_action_pressed("sprint")

	# 3. ANIMATION STATE MACHINE LOGIC
	if input_dir.length() > 0:
		# If moving forward (y is negative) and holding sprint, go to sprint state
		if is_sprinting and input_dir.y < -0.1: 
			playback.travel("sprint")
		else:
			# Otherwise, go to our BlendSpace2D "Walk" state
			playback.travel("Walk")
			# This updates the 2D graph so diagonal movement blends animations
			anim_tree.set("parameters/Walk/blend_position", input_dir)
	else:
		# No input? Back to idle
		playback.travel("idle")

	# 4. CALCULATE MOVEMENT (ROOT MOTION)
	# This asks the animation how much the character moved this frame
	var current_rotation = self.global_transform.basis.get_rotation_quaternion()
	var velocity_from_anim = anim_tree.get_root_motion_position()
	
	# Convert that local animation distance into world velocity
	var velocity_coords = (current_rotation * velocity_from_anim) / delta
	
	# Apply X and Z from the animation, keep Y from gravity
	velocity.x = velocity_coords.x
	velocity.z = velocity_coords.z

	# 5. TPS CHARACTER ROTATION
	# Rotate the model to face the direction of movement when in 3rd person
	if not is_fps and input_dir.length() > 0.1:
		var pivot_basis = cam_pivot.global_transform.basis
		var direction = (pivot_basis.z * input_dir.y + pivot_basis.x * input_dir.x).normalized()
		var target_dir = atan2(-direction.x, -direction.z) - self.global_rotation.y
		model.rotation.y = lerp_angle(model.rotation.y, target_dir, rotation_speed * delta)

	# 6. MOVE THE CHARACTER
	move_and_slide()
