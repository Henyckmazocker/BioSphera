class_name EntityRenderer
extends Node3D
## Renderizador por lotes (MultiMesh) de los cuerpos de esferas y plantas.
##
## Sustituye al `MeshInstance3D` por individuo: cada esfera/planta dejaba una
## draw call y, con material único por instancia, sin batching posible. Aquí
## todos los cuerpos de cada tipo se dibujan con UNA sola draw call vía
## `MultiMeshInstance3D`, con color por instancia para las esferas.
##
## Es un nodo "pull": cada frame recorre los grupos `spheres` y `plants` y
## reescribe los buffers. No requiere registro/baja por entidad (robusto ante
## nacimientos y muertes). Las etiquetas (`Label3D`) y la flecha de dirección
## siguen siendo hijos de cada esfera; este nodo solo refresca su parte visual
## con UNA única consulta de cámara por frame (antes 1 por esfera).
##
## Vive como hijo de `World` (lo crea `World._ready`), igual que `RelationLines`.

## Offsets verticales que tenían los nodos `Mesh` en las escenas originales
## (`Plant.tscn`): se replican aquí para que el cuerpo quede a la misma altura que
## antes respecto al origen de la entidad. (Los cuerpos de esferas ya NO se dibujan
## aquí: cada ser tiene su propio modelo humanoide animado, ver `EntityModel`.)
const PLANT_BODY_OFFSET := Vector3(0.0, 0.25, 0.0)
# Offsets verticales de los recursos de economía: la mitad de la altura de su
# malla, para que el cuerpo descanse sobre el suelo (el nodo está a ras de tierra).
const WOOD_BODY_OFFSET := Vector3(0.0, VisualScale.TREE_HEIGHT * 0.5, 0.0)
const STONE_BODY_OFFSET := Vector3(0.0, 0.25, 0.0)
const GOLD_BODY_OFFSET := Vector3(0.0, 0.3, 0.0)
## La capacidad de los buffers crece por bloques para no reasignar cada vez que
## nace una entidad; nunca encoge (se mantiene en el pico poblacional).
const CAPACITY_CHUNK: int = 128

var _mm_plant: MultiMesh
var _mm_wood: MultiMesh        # madera: tronco marrón
var _mm_stone: MultiMesh       # piedra: roca gris
var _mm_gold: MultiMesh        # oro: prisma amarillo


func _ready() -> void:
	_mm_plant = _make_multimesh(_plant_mesh(), false)
	_mm_wood = _make_multimesh(_wood_mesh(), false)
	_mm_stone = _make_multimesh(_stone_mesh(), false)
	_mm_gold = _make_multimesh(_gold_mesh(), false)

	_add_mm_instance(_mm_plant, _plant_material())
	_add_mm_instance(_mm_wood, _simple_material(Color(0.45, 0.30, 0.16), 0.8, 0.0))
	_add_mm_instance(_mm_stone, _simple_material(Color(0.55, 0.56, 0.58), 0.7, 0.0))
	_add_mm_instance(_mm_gold, _simple_material(Color(0.95, 0.78, 0.18), 0.25, 0.9))


func _process(_dt: float) -> void:
	# La cámara se resuelve UNA vez para toda la población (antes cada esfera la
	# pedía en su propio `_process`).
	var cam: Camera3D = get_viewport().get_camera_3d()
	_update_spheres(cam)
	_update_plants()
	_update_resources()


func _update_spheres(cam: Camera3D) -> void:
	var spheres: Array = get_tree().get_nodes_in_group(&"spheres")
	# Las esferas se mueven por time-slice (cada `SPHERE_STRIDE` frames): se
	# interpola su posición entre el extremo previo y el actual según los frames
	# transcurridos desde su último paso, para que el modelo se vea fluido.
	var tick: int = SimulationClock.get_tick_count()
	var stride: float = float(SimulationClock.SPHERE_STRIDE)
	for s in spheres:
		if not is_instance_valid(s) or not s._alive:
			continue
		var frac: float = clampf(float(tick - s._interp_tick) / stride, 0.0, 1.0)
		var pos: Vector3 = s._interp_from.lerp(s._interp_to, frac)
		# Cada ser coloca y anima su propio modelo humanoide (el cuerpo ya no se
		# batch-dibuja aquí). La cámara va resuelta para toda la población.
		s.drive_model(pos, cam)


func _update_plants() -> void:
	var plants: Array = get_tree().get_nodes_in_group(&"plants")
	_ensure_capacity(_mm_plant, plants.size())
	var i: int = 0
	for p in plants:
		# El grupo `plants` incluye también a los cadáveres (`Corpse`), que NO
		# son `Plant` y conservan su propio nodo de malla: se omiten aquí.
		if not is_instance_valid(p) or not (p is Plant):
			continue
		var scale: float = _plant_scale(p.stage)
		var xform := Transform3D(
			Basis.IDENTITY.scaled(Vector3.ONE * scale),
			p.global_position + PLANT_BODY_OFFSET)
		_mm_plant.set_instance_transform(i, xform)
		i += 1
	_mm_plant.visible_instance_count = i


func _plant_scale(stage: int) -> float:
	match stage:
		Plant.Stage.MATURE: return 1.0
		Plant.Stage.WILTED: return 0.6
		_: return 0.4   # SEED, GROWING (igual que el antiguo _apply_stage_visuals)


# ---------------- CONSTRUCCIÓN ----------------

func _make_multimesh(mesh: Mesh, with_colors: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = with_colors
	mm.mesh = mesh
	mm.instance_count = CAPACITY_CHUNK
	mm.visible_instance_count = 0
	return mm


func _add_mm_instance(mm: MultiMesh, mat: Material) -> void:
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = mat
	# Sin sombras: las entidades son diminutas y se ven casi en cenital; el
	# shadow pass duplicaba su geometría sin aportar lectura (quick win de render).
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# AABB fijo y generoso: las instancias se mueven cada frame y, sin esto, el
	# frustum culling usaría el AABB inicial y podría descartar TODO el lote al
	# salir de cuadro el origen. Cubrimos el mundo entero + margen.
	var half: float = SimConfig.world_size * 0.5 + 5.0
	node.custom_aabb = AABB(
		Vector3(-half, -20.0, -half),
		Vector3(half * 2.0, 60.0, half * 2.0))
	add_child(node)


func _ensure_capacity(mm: MultiMesh, needed: int) -> void:
	if mm.instance_count >= needed:
		return
	mm.instance_count = int(ceil(float(needed) / float(CAPACITY_CHUNK))) * CAPACITY_CHUNK


func _plant_mesh() -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = 0.25
	m.height = 0.5
	m.radial_segments = 8
	m.rings = 4
	return m


func _plant_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.45, 0.78, 0.32)
	m.roughness = 0.6
	return m


# ---------------- RECURSOS DE ECONOMÍA ----------------

## Refresca los lotes de madera/piedra/oro. Mismo patrón "pull" que las plantas:
## recorre el grupo de escena de cada tipo y reescribe su buffer.
func _update_resources() -> void:
	_update_resource_group(_mm_wood, &"wood_nodes", WOOD_BODY_OFFSET)
	_update_resource_group(_mm_stone, &"stone_nodes", STONE_BODY_OFFSET)
	_update_resource_group(_mm_gold, &"gold_nodes", GOLD_BODY_OFFSET)


func _update_resource_group(mm: MultiMesh, group: StringName, offset: Vector3) -> void:
	var nodes: Array = get_tree().get_nodes_in_group(group)
	_ensure_capacity(mm, nodes.size())
	var i: int = 0
	for n in nodes:
		if not is_instance_valid(n):
			continue
		# El árbol encoge mientras rebrota (sin madera disponible); el resto va a 1.
		var scale: float = 1.0
		if n is TreeNode and n.stage != TreeNode.Stage.MATURE:
			scale = 0.5
		mm.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3.ONE * scale),
			(n as Node3D).global_position + offset))
		i += 1
	mm.visible_instance_count = i


func _simple_material(albedo: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = roughness
	m.metallic = metallic
	return m


func _wood_mesh() -> CylinderMesh:
	# Árbol maduro: más alto que cualquier entidad (ver jerarquía en `VisualScale`).
	var m := CylinderMesh.new()
	m.top_radius = VisualScale.TREE_TOP_RADIUS
	m.bottom_radius = VisualScale.TREE_BOTTOM_RADIUS
	m.height = VisualScale.TREE_HEIGHT
	m.radial_segments = 6
	m.rings = 1
	return m


func _stone_mesh() -> BoxMesh:
	var m := BoxMesh.new()
	m.size = Vector3(0.6, 0.5, 0.6)
	return m


func _gold_mesh() -> PrismMesh:
	var m := PrismMesh.new()
	m.size = Vector3(0.5, 0.6, 0.5)
	return m
