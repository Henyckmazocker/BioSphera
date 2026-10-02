class_name TerritoryOverlay
extends Node3D
## Overlay de depuración: tiñe el suelo por celdas según quién domina cada zona
## territorial (datos en el autoload `TerritorySystem`). Capa de observación de
## la mecánica territorial — ver [[Mecánicas]] → Territorialidad.
##
## Dos modos alternables (tecla O en el HUD): por ESPECIE dominante (paleta fija
## A/B) o por GRUPO dominante (colores de clan de `GroupSystem`). La opacidad de
## cada celda refleja la fuerza de la dominancia. Se redibuja cada frame (pocas
## celdas, coste mínimo); apagado, la malla queda vacía → coste cero. Vive como
## hijo de World para compartir el espacio 3D, igual que `GroupHighlight`.

enum Mode { SPECIES, GROUP }

const CELL_Y_OFFSET: float = 0.06   # altura sobre el terreno (evita z-fighting)
const ALPHA_MAX: float = 0.4        # opacidad de una celda en dominancia plena
const MIN_STRENGTH: float = 0.05    # por debajo de esto la celda no se pinta

## Paleta fija por especie para que la lectura sea estable (el color de las
## esferas es por linaje, no por especie). Especies no listadas → hue por hash.
const SPECIES_COLORS: Dictionary = {
	&"A": Color(0.30, 0.55, 1.0),
	&"B": Color(1.0, 0.45, 0.30),
}

var _mesh: ImmediateMesh = null
var _mesh_node: MeshInstance3D = null
var _world: World = null
var _enabled: bool = false
var _mode: int = Mode.SPECIES


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
	_mesh_node.material_override = mat
	_mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_node)
	_world = get_parent() as World


func _process(_dt: float) -> void:
	_mesh.clear_surfaces()
	if not _enabled:
		return
	var cells: Array = TerritorySystem.get_overlay_cells()
	if cells.is_empty():
		return
	# Filtrar PRIMERO las celdas dibujables: una celda puede descartarse (fuerza
	# por debajo del umbral, grupo ya inexistente…), y si NINGUNA emite vértices,
	# `surface_end` falla con "No vertices were added". Solo abrimos la superficie
	# si queda al menos una celda que pintar.
	var draws: Array = []  # entradas {cell: Vector2i, col: Color}
	for entry in cells:
		var col: Color
		if _mode == Mode.GROUP:
			var gid: int = int(entry["group"])
			var strength: float = float(entry["group_strength"])
			if gid == -1 or strength < MIN_STRENGTH:
				continue
			col = Groups.get_group_color(gid)
			if col.a <= 0.0:
				continue  # grupo ya inexistente
			col.a = strength * ALPHA_MAX
		else:
			var strength: float = float(entry["species_strength"])
			if strength < MIN_STRENGTH:
				continue
			col = _species_color(entry["species"])
			col.a = strength * ALPHA_MAX
		draws.append({"cell": entry["cell"], "col": col})
	if draws.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for d in draws:
		var cell: Vector2i = d["cell"]
		_emit_cell_quad(cell.x, cell.y, d["col"])
	_mesh.surface_end()


## Cuádrado plano (XZ) que cubre la celda, siguiendo el relieve del terreno.
func _emit_cell_quad(cx: int, cz: int, col: Color) -> void:
	var size: float = TerritorySystem.TERRITORY_CELL_SIZE
	var x0: float = float(cx) * size
	var z0: float = float(cz) * size
	var x1: float = x0 + size
	var z1: float = z0 + size
	var a := _ground_point(x0, z0)
	var b := _ground_point(x1, z0)
	var c := _ground_point(x1, z1)
	var d := _ground_point(x0, z1)
	# Dos triángulos (cull_disabled → ambas caras visibles).
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(a)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(b)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(c)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(a)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(c)
	_mesh.surface_set_color(col); _mesh.surface_add_vertex(d)


func _ground_point(x: float, z: float) -> Vector3:
	var y: float = CELL_Y_OFFSET
	if _world != null:
		y += _world.get_terrain_height(x, z)
	return Vector3(x, y, z)


func _species_color(species: StringName) -> Color:
	if SPECIES_COLORS.has(species):
		return SPECIES_COLORS[species]
	var h: float = float(hash(species) & 0xFFFF) / 65535.0
	return Color.from_hsv(h, 0.7, 0.95)


# ---------------- API pública (la usa la fachada de World) ----------------

func set_enabled(v: bool) -> void:
	_enabled = v


func is_enabled() -> bool:
	return _enabled


func set_mode(m: int) -> void:
	_mode = m


func get_mode() -> int:
	return _mode


## Avanza el estado: apagado → especie → grupo → apagado. Devuelve el código de
## estado para que el HUD refleje botón/etiqueta: 0=off, 1=especie, 2=grupo.
func cycle() -> int:
	if not _enabled:
		_enabled = true
		_mode = Mode.SPECIES
		return 1
	if _mode == Mode.SPECIES:
		_mode = Mode.GROUP
		return 2
	_enabled = false
	return 0
