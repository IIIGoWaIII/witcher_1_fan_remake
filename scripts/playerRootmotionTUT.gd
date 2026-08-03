extends CharacterBody3D
## Root-motion-driven player controller (FPS / TPS).
##
## Horizontal movement comes entirely from the AnimationTree root motion, so
## the baked walk / strafe / sprint clips decide how the character moves. This
## script only turns input into a blend-space position, turns the body to face
## the camera in third-person, and converts root motion into velocity.
##
## The camera itself is owned by CamerasController.gd (the $cameras node).

const JUMP_VELOCITY := 4.5
const MAX_LOOK_ANGLE := deg_to_rad(45.0)
## Head and CamPivot carry a baked 180° yaw (see CamerasController.Y_OFFSET),
## so every angle read back from them needs this offset removed.
const CAMERA_YAW_OFFSET := PI

@export_category("Movement")
@export var blend_speed := 2.0
## Blend speed used while the player reverses direction. Kept a bit higher than
## blend_speed so a reversal doesn't crawl over the center of the blend space
## (where the opposing clips briefly cancel root motion) — but not so high that
## it teleports the blend and pops the animation. A modest value blends the
## crossfade smoothly while the input_grace_time debounce prevents the stall.
@export var direction_flip_blend_speed := 6.0
## Multiplier on baked root motion to reach gameplay speed.
@export var root_motion_scale := 4.0
## How fast the body turns to face the camera in third-person.
@export var turn_speed := 10.0
## How long input may stay at zero before the character actually stops.
## Prevents key-switch gaps (releasing D before A registers) from triggering
## the 0.5s crossfade to idle, which would stall the character.
@export var input_grace_time := 0.15

@export_category("Procedural Look")
@export var look_speed := 8.0

@onready var model: Node3D = $geralt_anim_testglb
@onready var skeleton: Skeleton3D = $geralt_anim_testglb/Armature/Skeleton3D
@onready var anim_tree: AnimationTree = $AnimationTree
@onready var cameras: Node3D = $cameras
@onready var cam_pivot: Node3D = $cameras/CamPivot

const ProceduralLookAtScript := preload("res://scripts/ProceduralLookAt.gd")

var _look_modifier: SkeletonModifier3D = null
var _input_timer := 0.0
var _is_moving := false
var _last_blend_dir := Vector2(0.0, -0.5)

func _ready() -> void:
	_setup_procedural_look()

func _physics_process(delta: float) -> void:
	_apply_gravity_and_jump(delta)

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var is_sprinting := Input.is_action_pressed("sprint")

	_turn_to_face_camera(delta, input_dir)
	_update_animation_blend(input_dir, is_sprinting, delta)
	_apply_root_motion(delta)

	move_and_slide()

func _process(_delta: float) -> void:
	_update_procedural_look()

# --- Movement ---------------------------------------------------------------

func _apply_gravity_and_jump(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

func _turn_to_face_camera(delta: float, input_dir: Vector2) -> void:
	# Third-person only: rotate the body toward the camera while moving.
	# CamPivot is a child of this body, so whatever yaw we add to the body must
	# be subtracted from the pivot again, or the camera would be dragged around.
	if cameras.is_fps or input_dir.is_zero_approx():
		return

	var target_yaw := cam_pivot.global_rotation.y - CAMERA_YAW_OFFSET
	var old_yaw := rotation.y
	rotation.y = lerp_angle(old_yaw, target_yaw, turn_speed * delta)
	cam_pivot.rotation.y -= rotation.y - old_yaw
	model.rotation.y = 0.0

func _apply_root_motion(delta: float) -> void:
	# Root motion is a per-frame displacement in the body's local space.
	# Rotate it by the body yaw and convert to velocity. Y is left untouched
	# so gravity and jumps keep working.
	var root_motion := anim_tree.get_root_motion_position()
	var motion := transform.basis.get_rotation_quaternion() \
			* Vector3(root_motion.x, 0.0, root_motion.z)
	velocity.x = motion.x / delta * root_motion_scale
	velocity.z = motion.z / delta * root_motion_scale

# --- Animation --------------------------------------------------------------

func _update_animation_blend(input_dir: Vector2, is_sprinting: bool, delta: float) -> void:
	# Debounce input: brief zero-gaps while switching keys shouldn't drop the
	# character to idle. During the grace window we keep the last direction so
	# the blend stays put and root motion keeps flowing.
	if input_dir.is_zero_approx():
		_input_timer += delta
		if _input_timer >= input_grace_time:
			_is_moving = false
		else:
			input_dir = _last_blend_dir
	else:
		_input_timer = 0.0
		_last_blend_dir = input_dir
		_is_moving = true

	anim_tree.set("parameters/conditions/movement", _is_moving)
	anim_tree.set("parameters/conditions/idle", not _is_moving)

	# Forward walk sits at (0, -0.5) and sprint at (0, -1) in the blend space,
	# so raw forward input (-1) is halved unless the player is sprinting.
	var blend_target := input_dir
	if not is_sprinting and blend_target.y < 0.0:
		blend_target.y *= 0.5

	var current_blend: Vector2 = anim_tree.get("parameters/Walk/blend_position")
	var speed := direction_flip_blend_speed if _direction_flipped(current_blend, blend_target) else blend_speed
	anim_tree.set("parameters/Walk/blend_position", current_blend.lerp(blend_target, speed * delta))

func _direction_flipped(current: Vector2, target: Vector2) -> bool:
	# Routing around the center is unnecessary: a direct crossfade through the
	# center is fine as long as it's fast enough. The debounce already stopped
	# the idle-crossfade stall. This just picks the region of the blend space
	# we need a faster transition for (opposing directions).
	return (current.x * target.x < 0.0 and current.x != 0.0) \
		or (current.y * target.y < 0.0 and current.y != 0.0)

# --- Procedural look (upper body follows camera) ----------------------------

func _setup_procedural_look() -> void:
	var bones := _find_look_bones()
	if bones.is_empty():
		push_warning("Player: no look bones resolved, procedural look disabled.")
		return

	# SkeletonModifier3D must be added as a child of the Skeleton3D so it runs
	# inside the skeleton's modifier pipeline, after the AnimationTree writes
	# the pose. Instantiate via new() so the virtual methods bind correctly.
	_look_modifier = ProceduralLookAtScript.new()
	_look_modifier.name = "ProceduralLookAt"
	_look_modifier.look_bones = bones
	_look_modifier.look_speed = look_speed
	_look_modifier.active = true
	skeleton.add_child(_look_modifier)

func _find_look_bones() -> Array[Dictionary]:
	# Godot remaps ':' to '_' on import, so try both name forms.
	var candidates: Array[Array] = [
		["mixamorig_Spine1", "mixamorig:Spine1", "Spine1"],
		["mixamorig_Spine2", "mixamorig:Spine2", "Spine2"],
		["mixamorig_Neck", "mixamorig:Neck", "Neck"],
		["mixamorig_Head", "mixamorig:Head", "Head"],
	]
	var weights := [0.15, 0.20, 0.25, 0.40]

	var bones: Array[Dictionary] = []
	for i in candidates.size():
		for name in candidates[i]:
			var idx := skeleton.find_bone(name)
			if idx != -1:
				bones.append({"idx": idx, "weight": weights[i]})
				break
	return bones

func _update_procedural_look() -> void:
	if _look_modifier == null:
		return

	var target_yaw := 0.0
	var target_pitch := 0.0
	if not cameras.is_fps:
		var cam_yaw := cam_pivot.global_rotation.y - CAMERA_YAW_OFFSET
		target_yaw = clampf(angle_difference(rotation.y, cam_yaw), -MAX_LOOK_ANGLE, MAX_LOOK_ANGLE)
		target_pitch = clampf(-cam_pivot.rotation.x, -MAX_LOOK_ANGLE, MAX_LOOK_ANGLE)

	_look_modifier.target_yaw = target_yaw
	_look_modifier.target_pitch = target_pitch
