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

## Gris del fantasma de muerte (sRGB) y opacidad máxima de su capa: un poco por debajo
## de 1 para que se intuya la textura debajo.
const GHOST_GREY := Color(0.66, 0.66, 0.68)
const GHOST_MAX_ALPHA: float = 0.85
## Capa gris del fantasma (`set_grey_fade`); null mientras el modelo está vivo.
var _ghost_overlay: StandardMaterial3D = null

## Halo de estado (contorno por casco invertido, `shaders/halo_outline.gdshader`). El
## índice es el estado; -1 = sin halo. Prioridad y significado los decide `Sphere`.
enum Halo { COMBAT, PLAGUE, HUNGER, COURTSHIP }
const HALO_SHADER: Shader = preload("res://shaders/halo_outline.gdshader")
const HALO_COLORS: Array[Color] = [
	Color(1.0, 0.3, 0.25),   # COMBAT: rojo
	Color(0.55, 0.85, 0.2),  # PLAGUE: verde enfermizo
	Color(1.0, 0.7, 0.2),    # HUNGER: ámbar
	Color(1.0, 0.5, 0.8),    # COURTSHIP: rosa
]
## Engorde del casco en espacio de modelo.
const HALO_GROW: float = 0.03
## Los cuatro materiales del halo, compartidos por todos los modelos (se crean una vez).
static var _halo_materials: Array[ShaderMaterial] = []
## Estado de halo puesto ahora en este modelo (-1 = ninguno).
var _halo_state: int = -1
## Mallas de la espada (vacío hasta que se crea), para que el halo la cubra como al cuerpo.
var _sword_meshes: Array[MeshInstance3D] = []


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
		for n in sword.find_children("*", "MeshInstance3D", true, false):
			_sword_meshes.append(n as MeshInstance3D)
			(n as MeshInstance3D).material_overlay = (_halo_material(_halo_state)
				if _halo_state >= 0 and _ghost_overlay == null else null)
	_sword_attach.visible = on


## Congela/reanuda la animación (para seres lejanos: ahorra CPU sin tocar geometría).
func set_anim_active(active: bool) -> void:
	if _anim != null and _anim.active != active:
		_anim.active = active


## Velocidad de la animación (1 = normal). La usa el fantasma de muerte para frenarla.
func set_anim_speed(s: float) -> void:
	if _anim != null:
		_anim.speed_scale = s


## Material de la capa gris del fantasma (nuevo en cada llamada: cada fantasma funde
## el suyo sin tocar a los demás). Lo usa también el precalentamiento del director.
static func make_ghost_overlay() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(GHOST_GREY, 0.0)
	m.roughness = 1.0
	return m


## Fundido a gris del fantasma de muerte: 0 = color normal, 1 = gris. No toca los
## materiales de tinte (propios de este modelo, pero los reutiliza `set_tint`): pone una
## capa gris semitransparente como `material_overlay` del cuerpo y de la espada, creada
## la primera vez.
func set_grey_fade(t: float) -> void:
	t = clampf(t, 0.0, 1.0)
	if _ghost_overlay == null:
		if t <= 0.0:
			return
		_ghost_overlay = make_ghost_overlay()
		var meshes: Array = _body_meshes.duplicate()
		if _sword_attach != null and _sword_attach.visible:
			meshes.append_array(_sword_attach.find_children("*", "MeshInstance3D", true, false))
		for mi in meshes:
			(mi as MeshInstance3D).material_overlay = _ghost_overlay
	_ghost_overlay.albedo_color.a = t * GHOST_MAX_ALPHA


## Halo de estado: pone el material compartido de `state` como `material_overlay` del
## cuerpo y de la espada, o lo quita con -1. Solo toca materiales cuando el estado
## cambia (se llama cada frame desde `Sphere.drive_model`). Con el fantasma de muerte
## puesto no hace nada: ese `material_overlay` es la capa gris y no se pisa.
func set_halo(state: int) -> void:
	if state == _halo_state or _ghost_overlay != null:
		return
	_halo_state = state
	var mat: ShaderMaterial = _halo_material(state) if state >= 0 else null
	for mi in _body_meshes:
		mi.material_overlay = mat
	for mi in _sword_meshes:
		mi.material_overlay = mat


static func _halo_material(state: int) -> ShaderMaterial:
	if _halo_materials.is_empty():
		for c in HALO_COLORS:
			var m := ShaderMaterial.new()
			m.shader = HALO_SHADER
			m.set_shader_parameter(&"halo_color", c)
			m.set_shader_parameter(&"grow", HALO_GROW)
			_halo_materials.append(m)
	return _halo_materials[state]
