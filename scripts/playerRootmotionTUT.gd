extends CharacterBody3D


const SPEED = 5.0
const JUMP_VELOCITY = 4.5
const MAX_LOOK_ANGLE = deg_to_rad(45)

@export var blend_speed = 2.0
@export var look_speed: float = 8.0  ## How fast the procedural look blends (higher = snappier)

# Reference to the SkeletonModifier3D we spawn at runtime
var _look_modifier: Node = null

const ProceduralLookAtScript = preload("res://scripts/ProceduralLookAt.gd")


func _ready() -> void:
	var skeleton: Skeleton3D = $geralt_anim_testglb/Armature/Skeleton3D

	# Resolve bone indices (Godot remaps ":" to "_" on import)
	var look_bones: Array[Dictionary] = []
	var bone_config := [
		{"names": ["mixamorig_Spine1", "mixamorig:Spine1", "Spine1"], "weight": 0.15},
		{"names": ["mixamorig_Spine2", "mixamorig:Spine2", "Spine2"], "weight": 0.20},
		{"names": ["mixamorig_Neck",   "mixamorig:Neck",   "Neck"],   "weight": 0.25},
		{"names": ["mixamorig_Head",   "mixamorig:Head",   "Head"],   "weight": 0.40},
	]

	for config in bone_config:
		for bone_name in config["names"]:
			var idx := skeleton.find_bone(bone_name)
			if idx != -1:
				look_bones.append({"idx": idx, "weight": config["weight"]})
				break

	if look_bones.is_empty():
		push_warning("LookAt: No bones resolved — procedural look disabled.")
		return

	# Spawn the SkeletonModifier3D as a child of the Skeleton3D.
	# This is the ONLY way to reliably modify bone poses after the
	# AnimationTree has written them — the modifier pipeline runs
	# inside the skeleton's own update, so our changes are never
	# overwritten before rendering.
	#
	# IMPORTANT: Instantiate via the script's new() so the virtual
	# _process_modification_with_delta() is bound from the start.
	# Using SkeletonModifier3D.new() + set_script() can silently
	# fail to register the override.
	_look_modifier = ProceduralLookAtScript.new()
	_look_modifier.name = "ProceduralLookAt"
	_look_modifier.look_bones = look_bones
	_look_modifier.look_speed = look_speed
	_look_modifier.active = true
	skeleton.add_child(_look_modifier)


func _process(_delta: float) -> void:
	if not _look_modifier:
		return

	# Compute target look angles and feed them to the modifier.
	# The modifier's _process_modification_with_delta() will consume
	# these values at the correct pipeline stage.
	var target_yaw: float = 0.0
	var target_pitch: float = 0.0

	if not $cameras.is_fps:
		var cam_pivot := $cameras/CamPivot

		var cam_global_yaw: float = cam_pivot.global_rotation.y - PI
		var char_yaw: float = global_rotation.y

		target_yaw = angle_difference(char_yaw, cam_global_yaw)
		target_pitch = -cam_pivot.rotation.x

		target_yaw = clampf(target_yaw, -MAX_LOOK_ANGLE, MAX_LOOK_ANGLE)
		target_pitch = clampf(target_pitch, -MAX_LOOK_ANGLE, MAX_LOOK_ANGLE)

	_look_modifier.target_yaw = target_yaw
	_look_modifier.target_pitch = target_pitch


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
	var blend_target = input_dir
	if not is_sprinting and blend_target.y < 0.0:
		blend_target.y *= 0.5
	
	# Lerp the blend position for smooth transitions between directions and walk/sprint.
	# blend_speed controls how fast it blends (2.0 = ~0.5s to fully transition).
	
	var current_blend: Vector2 = $AnimationTree.get("parameters/Walk/blend_position")
	var new_blend = current_blend.lerp(blend_target, blend_speed * delta)
	
	var direction := (transform.basis * Vector3(-input_dir.x, 0, -input_dir.y)).normalized()
	$AnimationTree.set("parameters/conditions/movement", direction != Vector3.ZERO)
	$AnimationTree.set("parameters/conditions/idle", direction == Vector3.ZERO)
	$AnimationTree.set("parameters/Walk/blend_position", new_blend)
	
	# 6. Root Motion: only apply horizontal velocity, preserve Y for gravity/jump
	var currentRotation = transform.basis.get_rotation_quaternion()
	var root_motion = (currentRotation.normalized() * $AnimationTree.get_root_motion_position()) / (delta / 4)
	velocity.x = root_motion.x
	velocity.z = root_motion.z

	move_and_slide()
