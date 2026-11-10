## The player on foot: "Bot Blast R-325" by Oscar Creativo (CC BY 4.0), the same robot as the Mac game.
## Its own idle animation plays when standing still; walking, running, jumping, the jetpack, superhero flight and the
## kneeling landing are driven by code on top of a calm frame of that idle (a port of CharacterRig.swift + Walker.swift).
## Character space: metres, x right, y up, z back (it faces -z), feet at y = 0.
class_name Robot
extends Node3D

const HEIGHT := 1.95

var model: Node3D
var skel: Skeleton3D
var anim: AnimationPlayer
var idle_len := 1.0
var base_t := 0.0
var bones := {}                  # name prefix -> bone index
var c_basis := Basis.IDENTITY    # skeleton space -> character space (rotation only)

const DRIVEN := ["CC_Base_Hip", "CC_Base_Waist", "CC_Base_Spine02", "CC_Base_Head", "CC_Base_L_Thigh", "CC_Base_R_Thigh",
	"CC_Base_L_Calf", "CC_Base_R_Calf", "CC_Base_L_Foot", "CC_Base_R_Foot", "CC_Base_L_Upperarm", "CC_Base_R_Upperarm",
	"CC_Base_L_Forearm", "CC_Base_R_Forearm"]

func _ready() -> void:
	var holder := Node3D.new(); add_child(holder)
	holder.rotation.y = PI                   # the model faces +z; the character faces -z
	model = load("res://assets/characters/robot.glb").instantiate()
	holder.add_child(model)
	skel = _find(model, "Skeleton3D") as Skeleton3D
	anim = _find(model, "AnimationPlayer") as AnimationPlayer
	for c in _all(model):
		if c is MeshInstance3D:
			(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if c.mesh != null and c.mesh.get_surface_count() > 0 and c.get_parent() == model: pass
	if anim:
		var nm: String = anim.get_animation_list()[0]
		anim.get_animation(nm).loop_mode = Animation.LOOP_LINEAR
		anim.play(nm); anim.pause()
		idle_len = anim.get_animation(nm).length
	for i in skel.get_bone_count():
		var n := skel.get_bone_name(i)
		if n.contains("scaleCompensation"): continue
		for p in DRIVEN:
			if n.begins_with(p + "_") and not bones.has(p): bones[p] = i
	# scale to HEIGHT with the feet on y = 0 (measured from the rest pose)
	_fit.call_deferred()

func _fit() -> void:
	# skinned meshes don't carry the skeleton's transform, so measure the bones instead (the top bone sits a little
	# below the top of the head)
	var lo := Vector3(1e9, 1e9, 1e9); var hi := -lo
	var to_me := global_transform.affine_inverse() * skel.global_transform
	for i in skel.get_bone_count():
		var o := to_me * skel.get_bone_global_rest(i).origin
		lo = lo.min(o); hi = hi.max(o)
	var h := (hi.y - lo.y) * 1.07
	if h <= 1e-6: return
	var k := HEIGHT / h
	var holder := model.get_parent() as Node3D
	holder.scale = Vector3(k, k, k)
	holder.position = Vector3(-(lo.x + hi.x) * 0.5 * k, -lo.y * k + 0.02, -(lo.z + hi.z) * 0.5 * k)
	_y0 = holder.position.y
	c_basis = (global_transform.affine_inverse() * skel.global_transform).basis.orthonormalized()
	base_t = _calm_time()

## pick the calmest moment of the idle: feet under the hips, legs straight
func _calm_time() -> float:
	var best := 0.0; var score_best := 1e9
	for k in 40:
		var t := idle_len * k / 40.0
		anim.seek(t, true)
		var s := 0.0
		for side in ["L", "R"]:
			if not bones.has("CC_Base_%s_Thigh" % side): continue
			var th := skel.get_bone_global_pose(bones["CC_Base_%s_Thigh" % side]).origin
			var ca := skel.get_bone_global_pose(bones["CC_Base_%s_Calf" % side]).origin
			var ft := skel.get_bone_global_pose(bones["CC_Base_%s_Foot" % side]).origin
			s += absf(ft.x - th.x) * 2.0 + absf(ft.z - th.z) + ((ca - th).normalized() - (ft - ca).normalized()).length()
		if s < score_best: score_best = s; best = t
	return best

## pose: dictionary with lt lk rt rk la le ra re laz raz lean roll bob crouch. idle_k: 1 = the robot's own idle.
func apply(idle_t: float, idle_k: float, p: Dictionary, turn: float, look: float) -> void:
	if skel == null or anim == null: return
	anim.seek(fmod(idle_t, idle_len) if idle_k > 0.5 else base_t, true)
	var mv := 1.0 - idle_k
	var cr: float = p.crouch
	var R := {}
	R["CC_Base_L_Thigh"] = Basis(Vector3.RIGHT, (p.lt + cr * 0.6) * mv)
	R["CC_Base_R_Thigh"] = Basis(Vector3.RIGHT, (p.rt + cr * 0.6) * mv)
	R["CC_Base_L_Calf"] = Basis(Vector3.RIGHT, -(p.lk + cr * 1.2) * mv)
	R["CC_Base_R_Calf"] = Basis(Vector3.RIGHT, -(p.rk + cr * 1.2) * mv)
	R["CC_Base_L_Foot"] = Basis(Vector3.RIGHT, -(p.lt - p.lk + cr * 0.6 - cr * 1.2) * 0.8 * mv)
	R["CC_Base_R_Foot"] = Basis(Vector3.RIGHT, -(p.rt - p.rk + cr * 0.6 - cr * 1.2) * 0.8 * mv)
	R["CC_Base_L_Upperarm"] = Basis(Vector3.RIGHT, p.la * mv) * Basis(Vector3.BACK, -(p.laz + 0.07) * mv)
	R["CC_Base_R_Upperarm"] = Basis(Vector3.RIGHT, p.ra * mv) * Basis(Vector3.BACK, -(p.raz - 0.07) * mv)
	R["CC_Base_L_Forearm"] = Basis(Vector3.RIGHT, p.le * 0.8 * mv)
	R["CC_Base_R_Forearm"] = Basis(Vector3.RIGHT, p.re * 0.8 * mv)
	var bank := clampf(-turn * 0.06, -0.25, 0.25)
	R["CC_Base_Waist"] = Basis(Vector3.RIGHT, -(p.lean + cr * 0.25) * 0.5 * mv) * Basis(Vector3.BACK, p.roll * mv)
	R["CC_Base_Spine02"] = Basis(Vector3.RIGHT, -(p.lean + cr * 0.25) * 0.5 * mv) * Basis(Vector3.BACK, bank * mv)
	R["CC_Base_Head"] = Basis(Vector3.RIGHT, p.lean * 0.5 * mv - look * 0.25)
	# turn each character-space rotation into the bone's own frame: local = local · (G⁻¹ r G)
	var glob := {}
	for k in R: if bones.has(k): glob[k] = (c_basis * skel.get_bone_global_pose(bones[k]).basis).orthonormalized()
	for k in R:
		if not bones.has(k): continue
		var g: Basis = glob[k]
		var delta: Basis = g.inverse() * (R[k] as Basis) * g
		var i: int = bones[k]
		skel.set_bone_pose_rotation(i, (skel.get_bone_pose_rotation(i) * delta.get_rotation_quaternion()).normalized())
	(model.get_parent() as Node3D).position.y = _base_y() + (p.bob - cr * 0.16) * mv

var _y0 := -1e9
func _base_y() -> float:
	var holder := model.get_parent() as Node3D
	return _y0 if _y0 > -1e8 else holder.position.y

func _find(n: Node, cls: String) -> Node:
	if n.get_class() == cls: return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r: return r
	return null

func _all(n: Node) -> Array:
	var out := [n]
	for c in n.get_children(): out.append_array(_all(c))
	return out
