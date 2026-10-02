extends Node3D
## Líneas al inspeccionar una esfera. Dos capas en una sola malla 3D:
##
##  - **Afinidades acumuladas**: hasta `MAX_LINES` líneas desde la esfera
##    seleccionada hacia las relaciones más fuertes que recuerda (vía
##    `Relationships.get_all`), positivas en tonos cálidos, negativas en rojo,
##    alpha por intensidad. Requieren historia de interacciones.
##
##  - **Objetivo actual**: una línea más viva hacia lo que la esfera está
##    persiguiendo AHORA según su acción (`_target_plant`, `_target_mate`,
##    `_fight_target`, `_flee_target`). Da feedback inmediato sin esperar a
##    que se acumule afinidad. Color por tipo de acción.
##
## Se redibuja cada frame: pocas líneas y geometría inmediata, coste
## despreciable. Sin selección, malla vacía → invisible.
##
## Ver docs: docs/GDD/Arte y Estética.md (sección "Líneas de relación").

const MAX_LINES: int = 6
## Solo se dibujan afinidades con |valor| ≥ esto, para no saturar con
## conexiones tibias.
const MIN_ABS_AFFINITY: float = 20.0
## Altura sobre el centro de la esfera donde se anclan los extremos de las
## líneas — sobre la cabeza, no atravesando el cuerpo.
const LINE_ANCHOR_Y: float = 0.6
## Semi-anchura (m) de la cinta de cada línea, en el plano XZ. Las cintas
## son horizontales — visibles de un vistazo desde cámara cenital, donde las
## líneas de `PRIMITIVE_LINES` quedan apenas a 1 px en pantalla.
const LINE_HALF_WIDTH: float = 0.18
## La línea al objetivo actual va un punto más gruesa que las de afinidad
## para destacar como el "qué está haciendo" sobre el historial relacional.
const TARGET_LINE_HALF_WIDTH: float = 0.28

var _mesh: ImmediateMesh = null
var _mesh_node: MeshInstance3D = null


func _ready() -> void:
	_mesh = ImmediateMesh.new()
	_mesh_node = MeshInstance3D.new()
	_mesh_node.name = "Mesh"
	_mesh_node.mesh = _mesh
	# Material unshaded con vertex colors: los colores se calculan por línea
	# en `_process` y van como atributo de vértice. Doble cara para que las
	# cintas horizontales se vean también si la cámara cae por debajo.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mesh_node.material_override = mat
	add_child(_mesh_node)
	if Selection.selected_changed.is_connected(_on_selected_changed):
		Selection.selected_changed.disconnect(_on_selected_changed)
	Selection.selected_changed.connect(_on_selected_changed)
	_on_selected_changed(Selection.current)


func _on_selected_changed(_s) -> void:
	_mesh.clear_surfaces()


func _process(_dt: float) -> void:
	_mesh.clear_surfaces()
	var sel: Sphere = Selection.current
	if sel == null or not is_instance_valid(sel) or not sel._alive:
		return
	var from: Vector3 = sel.global_position + Vector3.UP * LINE_ANCHOR_Y

	# Recolectar segmentos antes de empezar la surface (más simple y permite
	# combinar las dos capas en una sola draw call).
	var segments: Array = []

	# Capa 1: afinidades acumuladas.
	var book: Dictionary = Relationships.get_all(sel.get_instance_id())
	if not book.is_empty():
		var entries: Array = []
		for other_id in book:
			var v: float = float(book[other_id])
			if absf(v) >= MIN_ABS_AFFINITY:
				entries.append({"id": other_id, "v": v})
		entries.sort_custom(func(a, b): return absf(a.v) > absf(b.v))
		if entries.size() > MAX_LINES:
			entries.resize(MAX_LINES)
		for e in entries:
			var other = instance_from_id(int(e.id))
			if other == null or not is_instance_valid(other) \
					or not (other is Sphere) or not other._alive:
				continue
			segments.append({
				"to": other.global_position + Vector3.UP * LINE_ANCHOR_Y,
				"col": _color_for_affinity(e.v),
				"hw": LINE_HALF_WIDTH,
			})

	# Capa 2: línea al objetivo de la acción actual (más viva — feedback
	# inmediato de "qué está haciendo").
	var current_target: Variant = _current_target_of(sel)
	if current_target != null:
		segments.append({
			"to": current_target["pos"],
			"col": current_target["col"],
			"hw": TARGET_LINE_HALF_WIDTH,
		})

	if segments.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in segments:
		_emit_ribbon(from, s.to, s.col, s.hw)
	_mesh.surface_end()


## Emite una cinta horizontal (rectángulo en el plano XZ) como dos triángulos.
## A vista cenital es una línea gruesa visible; de canto pierde grosor — un
## tradeoff aceptable para una cámara mayormente top-down.
func _emit_ribbon(p_from: Vector3, p_to: Vector3, col: Color, half_width: float) -> void:
	var d := p_to - p_from
	d.y = 0.0
	if d.length_squared() < 0.0001:
		return
	var dir := d.normalized()
	var perp := Vector3(-dir.z, 0.0, dir.x) * half_width
	var a := p_from + perp
	var b := p_from - perp
	var c := p_to + perp
	var dd := p_to - perp
	# Triángulo 1: a, b, c. Triángulo 2: b, dd, c. (Doble cara por cull_disabled.)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(a)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(b)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(c)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(b)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(dd)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(c)


## Objetivo actual de la esfera según su `_current_action`, con color por tipo:
## comida verde, pareja rosa, rival naranja-rojizo, amenaza (flee) rojo vivo.
## Devuelve `null` si la acción no tiene un objetivo dirigido (wander,
## follow_group sin destino claro) o si el objetivo ya no es válido.
func _current_target_of(sel: Sphere) -> Variant:
	match sel._current_action:
		BehaviorSystem.Action.SEEK_FOOD:
			var t = sel._target_plant
			if t != null and is_instance_valid(t):
				return {
					"pos": t.global_position + Vector3.UP * 0.2,
					"col": Color(0.4, 0.95, 0.4, 0.95),
				}
		BehaviorSystem.Action.SEEK_MATE:
			var t = sel._target_mate
			if t != null and is_instance_valid(t) and t._alive:
				return {
					"pos": t.global_position + Vector3.UP * LINE_ANCHOR_Y,
					"col": Color(1.0, 0.55, 0.85, 0.95),
				}
		BehaviorSystem.Action.FIGHT:
			var t = sel._fight_target
			if t != null and is_instance_valid(t) and t._alive:
				return {
					"pos": t.global_position + Vector3.UP * LINE_ANCHOR_Y,
					"col": Color(1.0, 0.45, 0.2, 0.95),
				}
		BehaviorSystem.Action.FLEE:
			var t = sel._flee_target
			if t != null and is_instance_valid(t) and t._alive:
				return {
					"pos": t.global_position + Vector3.UP * LINE_ANCHOR_Y,
					"col": Color(1.0, 0.2, 0.2, 0.95),
				}
	return null


## Color por afinidad: negativas viran a rojo, positivas a rosa/magenta.
## Alpha sube con |afinidad| para que las relaciones intensas destaquen.
func _color_for_affinity(v: float) -> Color:
	var t: float = clampf(absf(v) / 100.0, 0.0, 1.0)
	var alpha: float = lerpf(0.45, 1.0, t)
	if v < 0.0:
		return Color(1.0, lerpf(0.45, 0.1, t), lerpf(0.45, 0.1, t), alpha)
	return Color(1.0, lerpf(0.65, 0.4, t), lerpf(0.85, 0.6, t), alpha)
