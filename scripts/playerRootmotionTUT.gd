extends CharacterBody3D


const SPEED = 5.0
const JUMP_VELOCITY = 4.5


func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	
	# Check camera mode from your cameras node
	if not $cameras.is_fps:
		if input_dir != Vector2.ZERO:
			# 1. Rotate the PLAYER node to match the CAMERA direction
			# We use the cam_pivot's global Y rotation
			var target_rotation = $cameras/CamPivot.global_rotation.y - PI # -PI is your -180 offset
			rotation.y = lerp_angle(rotation.y, target_rotation, 10.0 * delta)
			
			# 2. Reset the MODEL local rotation so it doesn't double-rotate
			$geralt.rotation.y = 0 
	
	var direction := (transform.basis * Vector3(-input_dir.x, 0, -input_dir.y)).normalized()
	$AnimationTree.set("parameters/conditions/movement", direction != Vector3.ZERO)
	$AnimationTree.set("parameters/conditions/idle", direction == Vector3.ZERO)
	$AnimationTree.set("parameters/Walk/blend_position", input_dir)
	
	var currentRotation = transform.basis.get_rotation_quaternion()
	velocity = (currentRotation.normalized() * $AnimationTree.get_root_motion_position()) / (delta/4)
	
	#if direction:
		#velocity.x = direction.x * SPEED
		#velocity.z = direction.z * SPEED
	#else:
		#velocity.x = move_toward(velocity.x, 0, SPEED)
		#velocity.z = move_toward(velocity.z, 0, SPEED)

	move_and_slide()
