class_name NestLayer
extends Node3D
## Pinta los nidos de los grupos: un domo glTF por nido, teñido del color del clan.
##
## Los nidos no son entidades: viven en `Groups._nests` y esta capa los reconcilia
## cada frame con `Groups.get_nests()` (pocos nidos, coste mínimo). Crea los nuevos,
## borra los que ya no están y a los huérfanos los hunde y oscurece según su
## `decay_01` (patrón de `Farm.DAMAGE_DARKEN`), sin transparencia para no tener
## problemas de orden de dibujado. Vive como hijo de World, igual que `GroupHighlight`.
##
## Ver docs: docs/Planes/…/Plan - Nidos y Asentamientos.md (Render).

const MODEL_SCENE: PackedScene = preload("res://assets/models/nest.glb")
## Malla con la zona teñible (franja y banderín) en `tools/blender_nest.py`.
const TINT_MESH_NAME: String = "NestTint"
## Altura nativa del modelo (cima del banderín), para hundirlo entero al decaer.
const NATIVE_HEIGHT: float = 1.3
## Oscurecimiento máximo de un nido huérfano a punto de desaparecer.
const DECAY_DARKEN: float = 0.6

var _world: World = null
# nest_id -> {node: Node3D, mats: Array (materiales duplicados), base: Array[Color]
#             (albedo sin oscurecer, ya teñido), decay: float (último aplicado)}
var _views: Dictionary = {}


func _ready() -> void:
	_world = get_parent() as World


func _process(_dt: float) -> void:
	var seen: Dictionary = {}
	for n in Groups.get_nests():
		var nid: int = int(n.id)
		seen[nid] = true
		var v: Dictionary = _views.get(nid, {})
		if v.is_empty():
			v = _create_view(n.color)
			_views[nid] = v
		_place(v, n.position, float(n.decay_01))
	for nid in _views.keys():
		if not seen.has(nid):
			(_views[nid].node as Node3D).queue_free()
			_views.erase(nid)


## Instancia el domo y duplica sus materiales (no mutar el material compartido del
## import, como `Farm._build_visual`). La zona teñible toma el color del clan.
func _create_view(color: Color) -> Dictionary:
	var inst: Node3D = MODEL_SCENE.instantiate()
	inst.scale = Vector3.ONE * VisualScale.nest_scale()
	add_child(inst)
	var v: Dictionary = {"node": inst, "mats": [], "base": [], "decay": -1.0}
	for nd in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := nd as MeshInstance3D
		var is_tint: bool = String(mi.name).contains(TINT_MESH_NAME) \
			or String(mi.get_parent().name).contains(TINT_MESH_NAME)
		for s in range(mi.get_surface_override_material_count()):
			var src: Material = mi.get_active_material(s)
			var mat: BaseMaterial3D = (src.duplicate() if src is BaseMaterial3D
				else StandardMaterial3D.new())
			mi.set_surface_override_material(s, mat)
			if is_tint:
				mat.albedo_color = color
			v.mats.append(mat)
			v.base.append(mat.albedo_color)
	return v


## Coloca el domo a ras de terreno; si decae, lo hunde y oscurece.
func _place(v: Dictionary, pos: Vector3, decay: float) -> void:
	var ground: float = pos.y
	if _world != null:
		ground = _world.get_terrain_height(pos.x, pos.z)
	var node: Node3D = v.node
	node.position = Vector3(pos.x, ground - decay * NATIVE_HEIGHT * VisualScale.nest_scale(), pos.z)
	if is_equal_approx(decay, float(v.decay)):
		return
	v.decay = decay
	var k: float = 1.0 - DECAY_DARKEN * decay
	for i in v.mats.size():
		var base: Color = v.base[i]
		(v.mats[i] as BaseMaterial3D).albedo_color = Color(base.r * k, base.g * k, base.b * k, base.a)
