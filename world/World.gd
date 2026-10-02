class_name World
extends Node3D
## Escena de simulación: plano + iluminación + spawner.
##
## Maneja la rotación del sol según `Climate.day_progress` para dar
## sensación de día/noche y genera el mapa de biomas inicial.
##
## Ver docs: docs/GDD/Mundo y Niveles.md.

## Emitida al final de `_generate_biomes()`. El Spawner espera esta señal
## antes de colocar entidades, garantizando que el collider existe.
signal terrain_ready

@export var world_bounds: Vector2 = Vector2(60.0, 60.0)
@export var biome_texture_resolution: int = 256

## Amplitudes de elevación del terreno, RELATIVAS al tamaño de referencia (m a 60 u).
## En `_generate_biomes` se multiplican por `elev_scale` (ver ELEV_REFERENCE_SIZE /
## ELEV_EXAGGERATION) para que la PENDIENTE (altura/longitud-de-onda) sea constante a
## cualquier tamaño de mapa, en vez de aplanarse al estirarse la onda del ruido. Los
## agentes pegan su Y al terreno con `get_terrain_height` (snap cinemático, sin física
## de impulso) y el navmesh filtra por agua (bioma), no por pendiente: por eso pendientes
## mayores son seguras (no se clavan ni salen despedidos). Ajustar la dramaticidad global
## con ELEV_EXAGGERATION, no con estas constantes base.
const COLD_ELEVATION: float = 1.8
const DESERT_ELEVATION: float = 0.8
const WATER_DEPTH: float = 1.0
const RELIEF_AMPLITUDE: float = 0.3

## --- Superficie de agua (ver shaders/water.gdshader y `_build_water_surface`) ---
## Nivel Y de la lámina de agua, como fracción de WATER_DEPTH (se multiplica por
## `elev_scale`): queda por encima del fondo del agua y por debajo de la tierra seca
## (≥0), así se lee como una poza hundida.
const WATER_SURFACE_DEPTH: float = 0.4
## Un vértice "es agua" si su `water_w ≥` este umbral. Es el MISMO umbral con que
## BiomeSystem clasifica el bioma de agua (WATER_HUMIDITY_MIN), así la lámina coincide
## con el hueco del navmesh (que excluye triángulos que tocan agua).
const WATER_MESH_THRESHOLD: float = 0.5
## Profundidad (en unidades de mundo) que se mapea a COLOR.r=1 al hornear la malla.
## Normaliza el gradiente de profundidad del shader; ~el hundimiento máximo esperado.
const WATER_MAX_DEPTH: float = 2.5

## --- Paleta del ciclo día/noche ---
## El sol orbita según `Climate.day_progress` (ver `_on_day_advanced`). Además de
## rotarlo y atenuarlo, modulamos la luz ambiental y el color del cielo para que la
## noche sea claramente más oscura y azulada y los amaneceres/atardeceres, cálidos
## (objetivo: día/noche marcado pero zen). Colores en sRGB; se interpolan por tick.
## Ajustar aquí la dramaticidad: NIGHT_AMBIENT controla cuánto se oscurece la noche.
const NIGHT_AMBIENT: float = 0.18  ## energía ambiental en plena noche (siluetas aún visibles)
const DAY_AMBIENT: float = 1.0     ## energía ambiental al mediodía
const SUN_DAY: Color = Color(1.0, 0.97, 0.9)    ## luz solar al mediodía (blanco cálido)
const SUN_GOLDEN: Color = Color(1.0, 0.6, 0.3)  ## luz solar rasante (dorado de amanecer/atardecer)
const SKY_DAY_TOP: Color = Color(0.62, 0.72, 0.85)
const SKY_DAY_HOR: Color = Color(0.92, 0.92, 0.9)
const SKY_NIGHT_TOP: Color = Color(0.03, 0.04, 0.10)
const SKY_NIGHT_HOR: Color = Color(0.07, 0.09, 0.18)
const SKY_SUNSET_TOP: Color = Color(0.30, 0.28, 0.45)
const SKY_SUNSET_HOR: Color = Color(0.95, 0.52, 0.28)

## Tamaño de mundo donde se calibraron las amplitudes base de elevación.
const ELEV_REFERENCE_SIZE: float = 60.0
## Exageración global del relieve. La altura escala como
## (world_size / ELEV_REFERENCE_SIZE) * ELEV_EXAGGERATION, así la pendiente se mantiene
## constante a cualquier tamaño de mapa en lugar de aplanarse en mapas grandes.
const ELEV_EXAGGERATION: float = 2.5

@onready var _sun: DirectionalLight3D = $SunLight
@onready var _ground: MeshInstance3D = $Ground
@onready var _nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var _world_env: WorldEnvironment = $WorldEnvironment

## Recursos del entorno que `_on_day_advanced` modula por tick. Se duplican en
## `_ready` para no contaminar el sub-recurso embebido en la escena.
var _env: Environment = null
var _sky_mat: ProceduralSkyMaterial = null

var _ground_body: StaticBody3D
var _ground_shape: CollisionShape3D
## Rejilla de alturas precalculada para `get_terrain_height` (bilineal).
var _height_grid: Array = []
## Rejilla paralela del peso de agua (`water_w`) por vértice, capturada en el bucle de
## terreno y consumida por `_build_water_surface` (evita recomputar el ruido).
var _water_grid: Array = []
var _grid_cols: int = 0
var _grid_rows: int = 0
## Lámina de agua (MeshInstance3D) y su material; el material se modula en
## `_on_day_advanced` para el ciclo día/noche. Ver `_build_water_surface`.
var _water_mesh: MeshInstance3D = null
var _water_mat: ShaderMaterial = null
## Visualizador toggleable del navmesh (debug). Se genera tras el bake.
var _navmesh_debug: MeshInstance3D = null
## Overlay toggleable de dominancia territorial (debug). Hijo creado en `_ready`.
var _territory_overlay: TerritoryOverlay = null
## ¿El navmesh es una sola isla conexa? Lo calcula `_validate_navmesh` tras el
## bake. Si es true, `Sphere._is_target_reachable` puede saltarse el costoso
## `map_get_path` (en navmesh conexo, todo punto-sobre-navmesh es alcanzable).
## Por defecto false: conservador hasta validar (full check de ruta).
var navmesh_connected: bool = false


func _ready() -> void:
	add_to_group("world")
	world_bounds = Vector2(SimConfig.world_size, SimConfig.world_size)
	_apply_configured_world_size()
	_setup_environment()
	Climate.day_advanced.connect(_on_day_advanced)
	# Renderizador por lotes (MultiMesh) de cuerpos de esferas y plantas: una
	# draw call por tipo en lugar de una por individuo. Hijo de World para
	# compartir el espacio 3D y morir con la escena. Se crea ANTES de spawnear
	# (el Spawner espera a `terrain_ready` + nav, varios frames después).
	add_child(EntityRenderer.new())
	# Traductor de input del "modo control" (3ª persona). Solo actúa cuando
	# `PlayerControl` está activo; en observador es inerte. Hijo de World para
	# morir con la escena, igual que el renderizador.
	var player_controller := PlayerController.new()
	player_controller.name = "PlayerController"
	add_child(player_controller)
	_generate_biomes()
	# Capa de líneas de relación al inspeccionar (3.5 — visualización social).
	# Vive como hijo del World para que esté en el mismo espacio 3D que las
	# esferas, y para que se destruya junto al mundo al cambiar de escena.
	var lines_node := Node3D.new()
	lines_node.name = "RelationLines"
	lines_node.set_script(preload("res://world/RelationLines.gd"))
	add_child(lines_node)
	# Resaltado de grupos: anillos bajo los miembros del grupo marcado en el
	# gráfico de grupos del HUD. Hijo de World, mismo patrón que RelationLines.
	var highlight_node := GroupHighlight.new()
	highlight_node.name = "GroupHighlight"
	add_child(highlight_node)
	# Overlay de dominancia territorial (debug, toggle con tecla O). Mismo patrón
	# que RelationLines/GroupHighlight: hijo de World, redibujo por frame.
	_territory_overlay = TerritoryOverlay.new()
	_territory_overlay.name = "TerritoryOverlay"
	add_child(_territory_overlay)


## Tope de subdivisiones del terreno. Hasta este tamaño se mantiene ~1
## vértice/unidad; por encima, el vértice se espacia para que mapas muy grandes no
## disparen el nº de vértices (≈MAX_TERRAIN_SUBDIVS² ) ni el bake del navmesh. La
## malla, la rejilla de alturas y la de walkability comparten esta resolución, así
## que siguen siendo coherentes entre sí (solo más gruesas en mapas enormes).
const MAX_TERRAIN_SUBDIVS: int = 256


func _apply_configured_world_size() -> void:
	## Redimensiona la malla del suelo al tamaño elegido en la pantalla de
	## inicio. Mantiene ~1 vértice/unidad (acotado por MAX_TERRAIN_SUBDIVS) para que
	## agua y walkability sigan siendo coherentes con cualquier tamaño de terreno.
	if _ground == null or not (_ground.mesh is PlaneMesh):
		return
	var pm: PlaneMesh = _ground.mesh
	pm.size = world_bounds
	var subdivs: int = clampi(int(round(world_bounds.x)), 1, MAX_TERRAIN_SUBDIVS)
	pm.subdivide_width = subdivs
	pm.subdivide_depth = subdivs


func _generate_biomes() -> void:
	if not Biomes.is_generated:
		Biomes.generate(world_bounds)
	if _ground == null:
		return

	# --- Material con vertex colors ---
	var mat: StandardMaterial3D = _ground.get_surface_override_material(0)
	if mat == null:
		mat = StandardMaterial3D.new()
		_ground.set_surface_override_material(0, mat)
	else:
		mat = mat.duplicate()
		_ground.set_surface_override_material(0, mat)
	mat.albedo_texture = null
	mat.albedo_color = Color.WHITE
	mat.vertex_color_use_as_albedo = true

	# --- Deformar mesh según bioma + relieve y construir rejilla de alturas ---
	var plane_mesh := _ground.mesh
	var mesh: ArrayMesh = null
	if plane_mesh is PlaneMesh:
		var subdivs: int = int(plane_mesh.subdivide_width)
		if subdivs < 1:
			subdivs = 60  # ~1 m/vértice: agua visible y walkability coherente
		var size: Vector2 = plane_mesh.size
		# Escala de elevación proporcional al mapa: mantiene la pendiente constante
		# (ver ELEV_REFERENCE_SIZE / ELEV_EXAGGERATION).
		var elev_scale: float = (size.x / ELEV_REFERENCE_SIZE) * ELEV_EXAGGERATION
		var width: int = subdivs + 1
		var depth: int = subdivs + 1

		_grid_cols = width
		_grid_rows = depth
		_height_grid = []
		_water_grid = []

		var arr_mesh: ArrayMesh = ArrayMesh.new()
		var st: SurfaceTool = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

		for z in range(depth):
			var row: Array = []
			var water_row: Array = []
			for x in range(width):
				var fx := lerpf(-size.x * 0.5, size.x * 0.5, float(x) / float(width - 1))
				var fz := lerpf(-size.y * 0.5, size.y * 0.5, float(z) / float(depth - 1))
				var h: float = Biomes._humidity_noise.get_noise_2d(fx, fz)
				var t: float = Biomes._temperature_noise.get_noise_2d(fx, fz)
				# Pesos continuos derivados del mismo ruido que clasifica biomas,
				# así la altura varía suavemente sin saltos en las fronteras.
				# La banda de agua se centra en el MISMO umbral que usa
				# BiomeSystem para clasificar (WATER_HUMIDITY_MIN): así la
				# depresión visual y la frontera de transitabilidad coinciden.
				var water_w: float = smoothstep(
					Biomes.WATER_HUMIDITY_MIN - Biomes.WATER_VISUAL_BAND,
					Biomes.WATER_HUMIDITY_MIN + Biomes.WATER_VISUAL_BAND, h)
				var dry_w: float   = 1.0 - water_w
				# Ventanas de transición anchas: reparten el cambio de altura
				# sobre más distancia → pendientes suaves (centradas en los
				# umbrales de clasificación: cold -0.15, desert ~0.32).
				var cold_w: float  = 1.0 - smoothstep(-0.35, 0.05, t)
				var desert_w: float = smoothstep(0.15, 0.50, t) * (1.0 - smoothstep(-0.10, 0.10, h))
				# Agua suprime toda elevación: cold/desert solo elevan terreno seco.
				var base_y: float = (cold_w * COLD_ELEVATION + desert_w * DESERT_ELEVATION) * dry_w \
					- water_w * WATER_DEPTH
				# Relieve local de alta frecuencia, amplitud reducida para no
				# sobreescribir la forma macro del terreno.
				var relief: float = Biomes._humidity_noise.get_noise_2d(fx * 4.0, fz * 4.0) * RELIEF_AMPLITUDE
				# Escala global: macro + relieve crecen con el mapa (pendiente constante).
				var y: float = (base_y + relief) * elev_scale
				row.append(y)
				water_row.append(water_w)
				# Color mezclado con los mismos pesos: forest entre plain y water,
				# water al final para dominar sobre cold (zonas frías + húmedas).
				var forest_w: float = smoothstep(0.15, 0.45, h) * dry_w * (1.0 - desert_w) * (1.0 - cold_w)
				var c: Color = Biomes.BIOME_COLOR[Biomes.Biome.PLAIN]
				c = c.lerp(Biomes.BIOME_COLOR[Biomes.Biome.FOREST],  forest_w)
				c = c.lerp(Biomes.BIOME_COLOR[Biomes.Biome.DESERT],  desert_w * dry_w)
				c = c.lerp(Biomes.BIOME_COLOR[Biomes.Biome.COLD],    cold_w * dry_w)
				c = c.lerp(Biomes.BIOME_COLOR[Biomes.Biome.WATER],   water_w)
				st.set_color(c)
				st.set_uv(Vector2(float(x) / float(width - 1), float(z) / float(depth - 1)))
				st.add_vertex(Vector3(fx, y, fz))
			_height_grid.append(row)
			_water_grid.append(water_row)

		for z in range(depth - 1):
			for x in range(width - 1):
				var i := x + z * width
				st.add_index(i);         st.add_index(i + 1);         st.add_index(i + width)
				st.add_index(i + 1);     st.add_index(i + width + 1); st.add_index(i + width)

		st.generate_normals()
		mesh = st.commit()
		_ground.mesh = mesh
		# Bake walkability a la misma resolución que la malla:
		# is_walkable_at usará exactamente los mismos puntos que los vértices visibles.
		Biomes.bake_walkability_grid(width, depth)
		# Lámina de agua estilizada sobre las depresiones del bioma de agua.
		_build_water_surface(width, depth, size, elev_scale)
	elif plane_mesh is ArrayMesh:
		mesh = plane_mesh

	# --- Collider físico ---
	if mesh != null:
		if _ground_body == null or _ground_shape == null:
			_ground_body = StaticBody3D.new()
			_ground_shape = CollisionShape3D.new()
			_ground_body.name = "GroundBody"
			_ground_shape.name = "GroundShape"
			_ground_body.add_child(_ground_shape)
			_ground.add_child(_ground_body)
		_ground_body.collision_layer = 1
		_ground_body.collision_mask = 1
		var shape := ConcavePolygonShape3D.new()
		if mesh.get_surface_count() > 0:
			var arr := mesh.surface_get_arrays(0)
			if arr.size() > Mesh.ARRAY_VERTEX:
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				var tris := PackedVector3Array()
				for idx in indices:
					tris.append(verts[idx])
				if tris.size() % 3 == 0 and tris.size() > 0:
					shape.data = tris
					_ground_shape.shape = shape

	_bake_navigation()


## Construye la lámina de agua: una malla PLANA al nivel `water_level_y`, solo en las
## celdas del bioma de agua. Emite un triángulo cuando CUALQUIERA de sus 3 esquinas es
## agua (`water_w ≥ WATER_MESH_THRESHOLD`) — el complemento exacto del criterio del
## navmesh (`_bake_navigation` excluye triángulos que tocan agua), así la lámina rellena
## justo el hueco transitable sin gaps ni charcos en tierra seca. La PROFUNDIDAD del
## agua (nivel − terreno) se hornea por vértice en COLOR.r para que el shader pinte el
## gradiente y la espuma sin DEPTH_TEXTURE. Ver shaders/water.gdshader.
func _build_water_surface(width: int, depth: int, size: Vector2, elev_scale: float) -> void:
	if _water_grid.is_empty() or _height_grid.is_empty():
		return
	# Limpia una lámina anterior (regeneración del mundo), igual que _navmesh_debug.
	if _water_mesh != null:
		_water_mesh.queue_free()
		_water_mesh = null

	var water_level_y: float = -WATER_SURFACE_DEPTH * elev_scale

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any_water: bool = false

	# Mismo recorrido y triangulación que el terreno; emitimos cada triángulo solo si
	# toca agua. Recalcular fx/fz desde el índice mantiene la malla alineada con el suelo.
	for z in range(depth - 1):
		for x in range(width - 1):
			# Índices de las 4 esquinas de la celda (mismo orden que el terreno).
			var i00 := Vector2i(x, z)
			var i10 := Vector2i(x + 1, z)
			var i01 := Vector2i(x, z + 1)
			var i11 := Vector2i(x + 1, z + 1)
			# Triángulo A: (i00, i10, i01) — B: (i10, i11, i01).
			any_water = _emit_water_tri(st, [i00, i10, i01], width, depth, size, water_level_y) or any_water
			any_water = _emit_water_tri(st, [i10, i11, i01], width, depth, size, water_level_y) or any_water

	if not any_water:
		return
	st.generate_normals()
	_water_mat = ShaderMaterial.new()
	_water_mat.shader = preload("res://shaders/water.gdshader")
	st.set_material(_water_mat)
	_water_mesh = MeshInstance3D.new()
	_water_mesh.name = "Water"
	_water_mesh.mesh = st.commit()
	# El agua no proyecta sombra (lámina translúcida; coste innecesario).
	_water_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_water_mesh)
	# Sincroniza el tinte con la hora actual (si Climate ya avanzó antes del bake).
	_water_mat.set_shader_parameter("daylight", 1.0)


## ¿Alguna de las 3 esquinas del triángulo cae en agua? Umbral idéntico al del bioma.
func _cell_touches_water(a: Vector2i, b: Vector2i, c: Vector2i) -> bool:
	return _water_w_at(a) >= WATER_MESH_THRESHOLD \
		or _water_w_at(b) >= WATER_MESH_THRESHOLD \
		or _water_w_at(c) >= WATER_MESH_THRESHOLD


func _water_w_at(p: Vector2i) -> float:
	return float(_water_grid[p.y][p.x])


## Emite un triángulo de la lámina si toca agua (devuelve true si lo emitió). Cada
## vértice va al nivel del agua y hornea su profundidad (nivel − altura del terreno)
## normalizada en COLOR.r.
func _emit_water_tri(st: SurfaceTool, idx: Array, width: int, depth: int,
		size: Vector2, water_level_y: float) -> bool:
	if not _cell_touches_water(idx[0], idx[1], idx[2]):
		return false
	for p in idx:
		var fx := lerpf(-size.x * 0.5, size.x * 0.5, float(p.x) / float(width - 1))
		var fz := lerpf(-size.y * 0.5, size.y * 0.5, float(p.y) / float(depth - 1))
		var terrain_y: float = float(_height_grid[p.y][p.x])
		var depth01: float = clampf((water_level_y - terrain_y) / WATER_MAX_DEPTH, 0.0, 1.0)
		st.set_color(Color(depth01, 0.0, 0.0, 1.0))
		st.set_uv(Vector2(float(p.x) / float(width - 1), float(p.y) / float(depth - 1)))
		st.add_vertex(Vector3(fx, water_level_y, fz))
	return true


func _bake_navigation() -> void:
	## Construye el NavMesh sólo con los triángulos de suelo transitable,
	## lo que garantiza que el agua queda excluida del pathfinding sin
	## depender de filtros de pendiente que no son fiables en este terreno.
	var arr_mesh := _ground.mesh as ArrayMesh
	if arr_mesh == null or arr_mesh.get_surface_count() == 0:
		terrain_ready.emit()
		return
	var arr := arr_mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var faces := PackedVector3Array()
	var i := 0
	while i + 2 < indices.size():
		var v0: Vector3 = verts[indices[i]]
		var v1: Vector3 = verts[indices[i + 1]]
		var v2: Vector3 = verts[indices[i + 2]]
		# Exigimos que los TRES vértices sean walkable, no solo el centroide:
		# si solo uno cae en agua, el triángulo se cuela en el navmesh y su
		# polígono asoma sobre la depresión del agua. Las esferas siguen el
		# borde del polígono, caen a la pendiente y quedan atrapadas con
		# `is_navigation_finished()=true` y velocidad 0 (ver logs 2026-05-20).
		if Biomes.is_walkable_at(v0) and Biomes.is_walkable_at(v1) and Biomes.is_walkable_at(v2):
			faces.append(v0)
			faces.append(v1)
			faces.append(v2)
		i += 3
	var source := NavigationMeshSourceGeometryData3D.new()
	source.add_faces(faces, _ground.global_transform)
	var nav_mesh := _nav_region.navigation_mesh
	print("[World] NavMesh bake: %d caras transitables añadidas" % (faces.size() / 3))
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source)
	# Aplana el navmesh a Y=0. En mapas grandes los polígonos planos de Recast oscilan
	# por encima/debajo del relieve curvo y NINGÚN offset constante lo arregla (offset
	# bajo → el terreno asoma y la navegación se clava; offset alto → la malla flota
	# sobre los objetos y quedan inalcanzables). La solución es no depender de la Y del
	# navmesh: las esferas navegan en XZ y pegan su altura al terreno (ver Sphere), y
	# todas las consultas al navmesh se hacen aplanadas a Y=0. Así su altura es
	# irrelevante y solo cuenta la huella XZ (que excluye el agua).
	_flatten_navmesh(nav_mesh)
	_nav_region.navigation_mesh = nav_mesh
	print("[World] NavMesh polígonos tras bake: %d" % nav_mesh.get_polygon_count())
	_build_navmesh_debug_mesh(nav_mesh)
	terrain_ready.emit()
	_validate_navmesh(nav_mesh)


## Colapsa la Y de todos los vértices del navmesh a 0, sin tocar la huella XZ ni los
## parámetros del bake (coste: un único recorrido de vértices al generar el mundo).
## La navegación trata el navmesh como una hoja plana en XZ: las esferas pegan su
## altura al terreno y todas las consultas (map_get_closest_point/map_get_path) se
## hacen aplanadas a Y=0, así que la altura del navmesh es irrelevante. Ver
## `_bake_navigation` y la navegación en XZ de `Sphere`.
func _flatten_navmesh(nav_mesh: NavigationMesh) -> void:
	var verts: PackedVector3Array = nav_mesh.get_vertices()
	if verts.is_empty():
		return
	for i in verts.size():
		var v: Vector3 = verts[i]
		verts[i] = Vector3(v.x, 0.0, v.z)
	nav_mesh.set_vertices(verts)


## Construye un MeshInstance3D superpuesto con la geometría del navmesh.
## El navmesh real está aplanado a Y=0 (ver `_flatten_navmesh`), así que cada vértice
## se PROYECTA a la altura del terreno (`get_terrain_height + Y_OFFSET`) para que el
## overlay se vea pegado al suelo. Es solo visualización de la huella XZ transitable.
## Sirve como toggle visual durante la partida — ver `set_navmesh_visible`.
func _build_navmesh_debug_mesh(nav_mesh: NavigationMesh) -> void:
	if _navmesh_debug != null:
		_navmesh_debug.queue_free()
		_navmesh_debug = null
	var verts: PackedVector3Array = nav_mesh.get_vertices()
	if verts.is_empty():
		return
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const Y_OFFSET: float = 0.05
	for pi in nav_mesh.get_polygon_count():
		var poly: PackedInt32Array = nav_mesh.get_polygon(pi)
		# Abanico desde el vértice 0 (los polígonos del navmesh son convexos).
		for k in range(1, poly.size() - 1):
			st.add_vertex(_project_navvert_to_terrain(verts[poly[0]], Y_OFFSET))
			st.add_vertex(_project_navvert_to_terrain(verts[poly[k]], Y_OFFSET))
			st.add_vertex(_project_navvert_to_terrain(verts[poly[k + 1]], Y_OFFSET))
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.10, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	st.set_material(mat)
	_navmesh_debug = MeshInstance3D.new()
	_navmesh_debug.name = "NavMeshDebug"
	_navmesh_debug.mesh = st.commit()
	_navmesh_debug.visible = false
	add_child(_navmesh_debug)


## Lleva un vértice del navmesh (aplanado en Y=0) a la altura del terreno en su (x, z)
## con un pequeño alza. Solo para el overlay de depuración.
func _project_navvert_to_terrain(v: Vector3, y_offset: float) -> Vector3:
	return Vector3(v.x, get_terrain_height(v.x, v.z) + y_offset, v.z)


## Activa o desactiva la visualización del navmesh sobre el terreno.
func set_navmesh_visible(v: bool) -> void:
	if _navmesh_debug != null:
		_navmesh_debug.visible = v


func is_navmesh_visible() -> bool:
	return _navmesh_debug != null and _navmesh_debug.visible


func toggle_navmesh_visible() -> bool:
	set_navmesh_visible(not is_navmesh_visible())
	return is_navmesh_visible()


## Activa/desactiva el overlay de dominancia territorial (modo especie).
func set_territory_overlay_enabled(v: bool) -> void:
	if _territory_overlay != null:
		_territory_overlay.set_enabled(v)
		if v:
			_territory_overlay.set_mode(TerritoryOverlay.Mode.SPECIES)


func is_territory_overlay_enabled() -> bool:
	return _territory_overlay != null and _territory_overlay.is_enabled()


## Avanza el overlay: apagado → especie → grupo → apagado. Devuelve el código de
## estado (0=off, 1=especie, 2=grupo) para sincronizar el botón/etiqueta del HUD.
func cycle_territory_overlay() -> int:
	if _territory_overlay == null:
		return 0
	return _territory_overlay.cycle()


func _validate_navmesh(nav_mesh: NavigationMesh) -> void:
	## Comprueba cuántas islas inconexas tiene el navmesh recién horneado. Un
	## navmesh fragmentado deja agentes atascados sin ruta; es preferible un
	## warning visible al arrancar que depurar esferas "quietas" en los logs.
	##
	## Trabaja directamente sobre el recurso (grafo de polígonos unidos por
	## aristas compartidas): es síncrono y fiable, sin depender de que el
	## NavigationServer haya sincronizado el mapa.
	var poly_count: int = nav_mesh.get_polygon_count()
	if poly_count == 0:
		push_warning("[World] NavMesh vacío tras el bake.")
		return
	var verts: PackedVector3Array = nav_mesh.get_vertices()
	# arista (par de índices de vértice, ordenado) -> primer polígono que la usa.
	var edge_polys: Dictionary = {}
	var parent: Array[int] = []
	for i in poly_count:
		parent.append(i)
	for pi in poly_count:
		var poly: PackedInt32Array = nav_mesh.get_polygon(pi)
		var n: int = poly.size()
		for k in n:
			var a: int = poly[k]
			var b: int = poly[(k + 1) % n]
			var key: int = (mini(a, b) << 21) | maxi(a, b)
			if edge_polys.has(key):
				_uf_union(parent, pi, int(edge_polys[key]))
			else:
				edge_polys[key] = pi
	# Área transitable por componente conexo.
	var comp_area: Dictionary = {}
	var total_area: float = 0.0
	for pi in poly_count:
		var area: float = _polygon_area_xz(nav_mesh.get_polygon(pi), verts)
		total_area += area
		var root: int = _uf_find(parent, pi)
		comp_area[root] = float(comp_area.get(root, 0.0)) + area
	var largest: float = 0.0
	for a in comp_area.values():
		largest = maxf(largest, float(a))
	var pct: float = 100.0 * largest / maxf(0.001, total_area)
	navmesh_connected = comp_area.size() <= 1
	if navmesh_connected:
		print("[World] NavMesh conectado: 1 isla, %d polígonos." % poly_count)
	else:
		push_warning(("[World] NavMesh FRAGMENTADO: %d islas; mayor componente %.0f%% " +
			"del área transitable. Agentes en islas pequeñas quedarán sin ruta.") %
			[comp_area.size(), pct])


## Espera (await) a que el NavigationServer haya completado al menos una
## iteración del mapa. Quien necesite consultar el navmesh —Spawner, Plant—
## debe esperar a esto tras `terrain_ready`; en caso contrario los queries
## fallan con "navigation map query failed before first map synchronization".
func await_nav_ready() -> void:
	var nav_map: RID = _nav_region.get_navigation_map()
	if not nav_map.is_valid():
		return
	# El bake llamó a `set_navigation_mesh` justo antes de emitir
	# `terrain_ready`. El NavigationServer integra la región en alguno de los
	# physics frames siguientes — `map_get_iteration_id` puede avanzar antes,
	# por una iteración del map sin nuestra geometría aún. En lugar de fiarnos
	# de ese contador, sondeamos la propia consulta: el snap de un punto que
	# NO está en el navmesh nunca devolverá ese mismo punto (la coincidencia
	# exacta sería casualidad astronómica). Mientras devuelva (0,0,0) — el
	# sentinel de "map vacío" del NavigationServer — la región no está lista.
	const PROBE := Vector3(1.234, 100.0, 5.678)
	var guard: int = 0
	while guard < 300:
		# `map_get_closest_point` emite ERROR si se llama con iter_id=0 (el
		# server aún no ha sincronizado nunca). Esperar a iter_id>0 evita la
		# traza de error de arranque, y ADEMÁS sondeamos el snap: si la
		# región aún no está integrada, devuelve (0,0,0) y seguimos esperando.
		if NavigationServer3D.map_get_iteration_id(nav_map) > 0:
			var snap: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, PROBE)
			if not snap.is_equal_approx(Vector3.ZERO):
				return
		await get_tree().physics_frame
		guard += 1


## ¿Es `pos` alcanzable por la navegación? Comprueba que el snap al navmesh
## queda a ≤ `max_offset` m horizontales de la posición. Fuente única de
## verdad para "transitable": evita plantar (o spawnear) en franjas que la
## rejilla por bioma considera caminables pero que el bake del navmesh
## excluyó (orillas de agua recortadas por `agent_radius`, picos cortados
## por pendiente o por voxelización). Esas franjas serían comida fantasma:
## existe pero ninguna esfera puede recorrer los últimos metros para comerla.
func is_navmesh_reachable(pos: Vector3, max_offset: float = 0.5) -> bool:
	var nav_map: RID = _nav_region.get_navigation_map()
	if not nav_map.is_valid() or NavigationServer3D.map_get_iteration_id(nav_map) == 0:
		return true  # bake aún sin sincronizar: graceful — no bloquear
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, pos)
	return Vector2(snapped.x - pos.x, snapped.z - pos.z).length() <= max_offset


func _uf_find(parent: Array[int], x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]
		x = parent[x]
	return x


func _uf_union(parent: Array[int], a: int, b: int) -> void:
	var ra: int = _uf_find(parent, a)
	var rb: int = _uf_find(parent, b)
	if ra != rb:
		parent[ra] = rb


func _polygon_area_xz(poly: PackedInt32Array, verts: PackedVector3Array) -> float:
	## Área en el plano XZ de un polígono convexo (abanico desde el vértice 0).
	if poly.size() < 3:
		return 0.0
	var area: float = 0.0
	var o: Vector3 = verts[poly[0]]
	for k in range(1, poly.size() - 1):
		var p1: Vector3 = verts[poly[k]]
		var p2: Vector3 = verts[poly[k + 1]]
		area += absf((p1.x - o.x) * (p2.z - o.z) - (p2.x - o.x) * (p1.z - o.z)) * 0.5
	return area


## Duplica el Environment y su cielo procedural para poder modularlos por tick
## (ambiental + color de cielo) sin mutar el sub-recurso embebido en World.tscn,
## que se comparte entre instancias de la escena. Mismo patrón que el material del
## suelo en `_generate_biomes`.
func _setup_environment() -> void:
	if _world_env == null or _world_env.environment == null:
		return
	_env = _world_env.environment.duplicate(true)
	_world_env.environment = _env
	if _env.sky != null and _env.sky.sky_material is ProceduralSkyMaterial:
		_sky_mat = _env.sky.sky_material


func _on_day_advanced(day_progress: float) -> void:
	var angle: float = day_progress * TAU
	var basis: Basis = Basis.IDENTITY
	basis = basis.rotated(Vector3.RIGHT, -PI * 0.5 + angle)
	_sun.transform.basis = basis
	var elevation: float = sin(angle)
	_sun.light_energy = clampf(elevation * 1.4, 0.05, 1.4)

	# Factor de luz diurna (0 plena noche → 1 día) con transición suave por el
	# amanecer/atardecer, y factor "dorado" que pica con el sol rasante.
	var daylight: float = smoothstep(-0.25, 0.15, elevation)
	var golden: float = clampf(1.0 - absf(elevation) * 3.0, 0.0, 1.0)

	# El color del sol vira a dorado cerca del horizonte.
	_sun.light_color = SUN_DAY.lerp(SUN_GOLDEN, golden)

	# Atenuar la ambiental de noche es lo que de verdad oscurece la escena: el
	# cielo procedural es estático y, sin esto, rellenaría la noche con luz diurna.
	if _env != null:
		_env.ambient_light_energy = lerpf(NIGHT_AMBIENT, DAY_AMBIENT, daylight)

	# Cielo: noche azul oscuro → día claro, con tinte cálido en el horizonte al
	# amanecer/atardecer (el dorado sube más en el horizonte que en el cénit).
	if _sky_mat != null:
		var top: Color = SKY_NIGHT_TOP.lerp(SKY_DAY_TOP, daylight).lerp(SKY_SUNSET_TOP, golden * 0.5)
		var hor: Color = SKY_NIGHT_HOR.lerp(SKY_DAY_HOR, daylight).lerp(SKY_SUNSET_HOR, golden)
		_sky_mat.sky_top_color = top
		_sky_mat.sky_horizon_color = hor

	# Agua: el shader vira hacia el tinte nocturno al bajar `daylight`, en sincronía
	# con la atenuación de la ambiental y del cielo.
	if _water_mat != null:
		_water_mat.set_shader_parameter("daylight", daylight)


## Altura Y del terreno en (x, z) con interpolación bilineal sobre la rejilla.
## Retorna 0.0 si la rejilla aún no está construida (antes de terrain_ready).
func get_terrain_height(x: float, z: float) -> float:
	if _height_grid.is_empty():
		return 0.0
	var u := (x + world_bounds.x * 0.5) / world_bounds.x * float(_grid_cols - 1)
	var v := (z + world_bounds.y * 0.5) / world_bounds.y * float(_grid_rows - 1)
	var c0 := clampi(int(floor(u)), 0, _grid_cols - 2)
	var r0 := clampi(int(floor(v)), 0, _grid_rows - 2)
	var c1 := c0 + 1
	var r1 := r0 + 1
	var fx: float = fmod(u, 1.0)
	var fz: float = fmod(v, 1.0)
	var h00: float = _height_grid[r0][c0]
	var h10: float = _height_grid[r0][c1]
	var h01: float = _height_grid[r1][c0]
	var h11: float = _height_grid[r1][c1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)
