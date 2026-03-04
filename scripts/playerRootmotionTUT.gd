extends CharacterBody3D


const SPEED = 5.0
const JUMP_VELOCITY = 4.5


func _physics_process(delta: float) -> void:
	# 1. Gravity
	if not is_on_floor():
		velocity += get_gravity() * delta

	# 2. Jump
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# 3. Input
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var is_sprinting = Input.is_action_pressed("sprint")
	
	# 4. TPS: Rotate player to face camera direction
	if not $cameras.is_fps:
		if input_dir != Vector2.ZERO:
			var cam_pivot = $cameras/CamPivot
			var target_rotation = cam_pivot.global_rotation.y - PI # -PI is your -180 offset
			var old_rot = rotation.y
			rotation.y = lerp_angle(rotation.y, target_rotation, 10.0 * delta)
			# Compensate cam_pivot so its global rotation stays fixed.
			# Without this, player rotation drags cam_pivot (its child),
			# shifting the target further each frame and stacking velocity.
			cam_pivot.rotation.y -= (rotation.y - old_rot)
			
			# Reset model local rotation so it doesn't double-rotate
			$geralt_anim_testglb.rotation.y = 0
	
	# 5. Animation State & BlendSpace
	# Scale blend input so forward maps to walk (-0.5) or sprint (-1.0).
	# Without this, raw input_dir.y = -1 always hits the sprint blend point.
	var blend_input = input_dir
	if not is_sprinting and blend_input.y < 0.0:
		blend_input.y *= 0.5
	
	var direction := (transform.basis * Vector3(-input_dir.x, 0, -input_dir.y)).normalized()
	$AnimationTree.set("parameters/conditions/movement", direction != Vector3.ZERO)
	$AnimationTree.set("parameters/conditions/idle", direction == Vector3.ZERO)
	$AnimationTree.set("parameters/Walk/blend_position", blend_input)
	
	# 6. Root Motion: only apply horizontal velocity, preserve Y for gravity/jump
	var currentRotation = transform.basis.get_rotation_quaternion()
	var root_motion = (currentRotation.normalized() * $AnimationTree.get_root_motion_position()) / (delta / 4)
	velocity.x = root_motion.x
	velocity.z = root_motion.z

	move_and_slide()
