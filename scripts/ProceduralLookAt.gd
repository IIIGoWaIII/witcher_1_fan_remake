extends SkeletonModifier3D
## Procedural upper-body look-at modifier.
## Must be a child of a Skeleton3D node.  Runs inside the skeleton's
## modifier pipeline (after AnimationTree) via _process_modification_with_delta().

const MAX_LOOK_ANGLE := deg_to_rad(45.0)

var look_speed: float = 8.0

# Target angles set by the player script each frame
var target_yaw: float = 0.0
var target_pitch: float = 0.0

# Smoothed current angles
var _current_yaw: float = 0.0
var _current_pitch: float = 0.0

# Bone indices + weights, populated by the player script
var look_bones: Array[Dictionary] = []   # [{idx: int, weight: float}]


func _process_modification_with_delta(delta: float) -> void:
	var skel := get_skeleton()
	if not skel or look_bones.is_empty():
		return

	# Smooth interpolation toward the target
	_current_yaw = lerp(_current_yaw, target_yaw, look_speed * delta)
	_current_pitch = lerp(_current_pitch, target_pitch, look_speed * delta)

	for bone in look_bones:
		var idx: int = bone["idx"]
		var w: float = bone["weight"]

		# Read the pose the AnimationTree already wrote
		var anim_pose: Quaternion = skel.get_bone_pose_rotation(idx)

		# Build additive look quaternion (yaw on Y, pitch on X) scaled by weight
		var look_quat := Quaternion(Vector3.UP, _current_yaw * w) \
					   * Quaternion(Vector3.RIGHT, _current_pitch * w)

		# Layer on top: anim first, then procedural
		skel.set_bone_pose_rotation(idx, anim_pose * look_quat)
