class_name GroupHighlight
extends Node3D
## Resalta en el plano a las esferas del grupo marcado desde el gráfico de grupos.
##
## Dibuja un anillo en el suelo bajo cada miembro de `Selection.highlighted_group_id`.
## Se redibuja cada frame (pocas esferas por grupo, coste mínimo); sin grupo
## marcado, la malla queda vacía → invisible. Vive como hijo de World para
## compartir el espacio 3D, igual que `RelationLines`.

const RING_SEGMENTS: int = 24
const RING_WIDTH: float = 0.16   # grosor radial del anillo (m)
const RING_Y: float = 0.06       # altura sobre la base de la esfera
const PULSE_SPEED: float = 4.0   # parpadeo suave para que destaque

var _mesh: ImmediateMesh = null
var _mesh_node: MeshInstance3D = null


func _ready() -> void:
	_mesh = ImmediateMesh.new()
	_mesh_node = MeshInstance3D.new()
	_mesh_node.name = "Mesh"
	_mesh_node.mesh = _mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Siempre visible: el anillo no debe quedar oculto por el terreno ni por el
	# propio cuerpo de la esfera (resaltado de UI, no objeto del mundo).
	mat.no_depth_test = true
	_mesh_node.material_override = mat
	_mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_node)


func _process(_dt: float) -> void:
	_mesh.clear_surfaces()
	var gid: int = Selection.highlighted_group_id
	if gid == -1:
		return
	if not Groups.has_group(gid):
		# El grupo se disolvió mientras estaba marcado: limpiar el resaltado.
		Selection.clear_group_highlight()
		return
	var members: Array = Groups.get_members(gid)
	if members.is_empty():
		return
	# Color de marca: color del grupo aclarado + parpadeo suave de alpha, para
	# que se asocie con la barra clicada y a la vez destaque sobre el plano.
	var hl: Color = Groups.get_group_color(gid).lerp(Color.WHITE, 0.35)
	var t: float = Time.get_ticks_msec() / 1000.0 * PULSE_SPEED
	hl.a = 0.6 + 0.4 * (0.5 + 0.5 * sin(t))

	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for m in members:
		if m == null or not is_instance_valid(m):
			continue
		var outer: float = m.visual_ground_radius() + 0.45
		var inner: float = maxf(0.05, outer - RING_WIDTH)
		_emit_ring(m.global_position + Vector3(0.0, RING_Y, 0.0), inner, outer, hl)
	_mesh.surface_end()


## Anillo plano en el plano XZ (entre `inner` y `outer`) como tira de triángulos.
func _emit_ring(center: Vector3, inner: float, outer: float, col: Color) -> void:
	var step: float = TAU / float(RING_SEGMENTS)
	for i in RING_SEGMENTS:
		var a0: float = float(i) * step
		var a1: float = float(i + 1) * step
		var c0 := Vector2(cos(a0), sin(a0))
		var c1 := Vector2(cos(a1), sin(a1))
		var ai := center + Vector3(c0.x * inner, 0.0, c0.y * inner)
		var ao := center + Vector3(c0.x * outer, 0.0, c0.y * outer)
		var bi := center + Vector3(c1.x * inner, 0.0, c1.y * inner)
		var bo := center + Vector3(c1.x * outer, 0.0, c1.y * outer)
		# Dos triángulos por segmento (cull_disabled → ambas caras visibles).
		_mesh.surface_set_color(col); _mesh.surface_add_vertex(ai)
		_mesh.surface_set_color(col); _mesh.surface_add_vertex(ao)
		_mesh.surface_set_color(col); _mesh.surface_add_vertex(bo)
		_mesh.surface_set_color(col); _mesh.surface_add_vertex(ai)
		_mesh.surface_set_color(col); _mesh.surface_add_vertex(bo)
		_mesh.surface_set_color(col); _mesh.surface_add_vertex(bi)
