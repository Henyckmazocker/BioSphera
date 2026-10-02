class_name EntityModel
extends Node3D
## Envoltorio de un humanoide animado (un `.glb` por individuo).
##
## Sustituye, para los cuerpos de esferas, al render por `MultiMesh` de
## `EntityRenderer`: el MultiMesh no puede animar esqueletos por instancia, así que
## cada ser pasa a tener su propio modelo skinneado con `AnimationPlayer`.
##
## Es hijo del nodo `Sphere`; `Sphere.drive_model` le fija cada frame el transform
## (posición interpolada + rumbo + escala) y el estado de animación. El tinte por
## linaje/grupo se aplica multiplicando el `albedo_color` sobre la textura.

## Espada que se acopla a la mano cuando el ser porta arma. La carga este nodo
## (no `Sphere`) porque es detalle del modelo, no de la simulación.
const SWORD_SCENE: PackedScene = preload("res://assets/models/sword.glb")

## Hueso de la mano derecha del esqueleto (ver tools/blender_humanoid_lib.py: BONES).
const HAND_BONE: StringName = &"hand.R"

## Encaje de la espada en la palma. Ajustable tras verlo en marcha (no se puede
## previsualizar aquí): posición local respecto al hueso y giro para alinear el filo.
const SWORD_LOCAL_POS := Vector3(0.0, 0.0, 0.0)
const SWORD_LOCAL_ROT_DEG := Vector3(90.0, 0.0, 0.0)

var _anim: AnimationPlayer = null
var _skeleton: Skeleton3D = null
var _body_meshes: Array[MeshInstance3D] = []
var _materials: Array[BaseMaterial3D] = []
var _state: StringName = &""
var _sword_attach: BoneAttachment3D = null


## Instancia el `.glb` indicado y prepara animación, materiales y skeleton.
func setup(glb_scene: PackedScene) -> void:
	var inst: Node = glb_scene.instantiate()
	add_child(inst)

	_anim = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for n in inst.find_children("*", "Skeleton3D", true, false):
		_skeleton = n as Skeleton3D
		break

	# Los clips de glTF se importan SIN loop: idle/walk deben ciclar, y el attack
	# también cicla mientras dura el combate (se lee bien).
	if _anim != null:
		for clip in [&"idle", &"walk", &"attack"]:
			if _anim.has_animation(clip):
				_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR

	# Cachear las mallas del CUERPO (antes de colgar la espada) y un material propio
	# por superficie, para poder tintar por individuo sin afectar a otros ni a la espada.
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		_body_meshes.append(mi)
		for s in range(mi.get_surface_override_material_count()):
			var base: Material = mi.get_active_material(s)
			var mat: BaseMaterial3D = (base.duplicate() if base is BaseMaterial3D
				else StandardMaterial3D.new())
			mi.set_surface_override_material(s, mat)
			_materials.append(mat)

	set_state(&"idle")


## Reproduce la animación de `state` (idle/walk/attack) con un crossfade corto.
func set_state(state: StringName) -> void:
	if state == _state or _anim == null or not _anim.has_animation(state):
		return
	_state = state
	_anim.play(state, 0.15)


## Tinta todo el cuerpo (no la espada) por color de linaje/grupo. `StandardMaterial3D`
## multiplica la textura por `albedo_color`. El color se pasa en sRGB.
func set_tint(color: Color) -> void:
	for mat in _materials:
		mat.albedo_color = color


## Muestra/oculta la espada acoplada a la mano. La crea la primera vez que se pide.
func set_weapon_visible(on: bool) -> void:
	if _sword_attach == null:
		if not on or _skeleton == null:
			return
		_sword_attach = BoneAttachment3D.new()
		_skeleton.add_child(_sword_attach)
		_sword_attach.bone_name = HAND_BONE
		var sword: Node3D = SWORD_SCENE.instantiate()
		sword.position = SWORD_LOCAL_POS
		sword.rotation = Vector3(
			deg_to_rad(SWORD_LOCAL_ROT_DEG.x),
			deg_to_rad(SWORD_LOCAL_ROT_DEG.y),
			deg_to_rad(SWORD_LOCAL_ROT_DEG.z))
		_sword_attach.add_child(sword)
	_sword_attach.visible = on


## Congela/reanuda la animación (para seres lejanos: ahorra CPU sin tocar geometría).
func set_anim_active(active: bool) -> void:
	if _anim != null and _anim.active != active:
		_anim.active = active
