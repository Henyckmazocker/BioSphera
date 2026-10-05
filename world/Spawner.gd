class_name Spawner
extends Node3D
## Genera la población inicial de esferas (dos especies) y siembra plantas.
##
## Espera la señal `World.terrain_ready` antes de colocar entidades, de modo
## que el collider del suelo y la rejilla de alturas ya existen al spawnear.
##
## Ver docs: docs/GDD/Mecánicas.md (plantas) y docs/GDD/Mundo y Niveles.md.

## Se emite justo tras restaurar un save (rama de carga de `_on_terrain_ready`), antes
## de cualquier tick posterior: quien quiera comparar el estado recién cargado (el
## arnés `tools/save_load_test.gd`) debe hacerlo en este callback, de forma síncrona.
## `node_of` = nodos restaurados por índice de save (ver `SaveGame.restore`).
signal save_restored(node_of: Array)

const SPHERE_SCENE: PackedScene = preload("res://entities/Sphere.tscn")
const PLANT_SCENE: PackedScene = preload("res://entities/Plant.tscn")
const TREE_SCENE: PackedScene = preload("res://entities/Tree.tscn")
const DEPOSIT_SCENE: PackedScene = preload("res://entities/Deposit.tscn")

## Peso de aparición por bioma de cada recurso de economía (rechazo proporcional).
## Crea valor territorial: la madera abunda en bosque, la piedra/oro en zonas
## frías y desérticas (rocosas). Ver decisión de diseño "distribución por bioma".
## Es `var` (no `const`) porque referencia enums de otras clases (`BiomeSystem`,
## `ResourceNode`); como dato fijo de solo lectura, equivale a una constante.
var _resource_biome_weight: Dictionary = {
	ResourceNode.Type.WOOD: {
		BiomeSystem.Biome.FOREST: 1.0, BiomeSystem.Biome.PLAIN: 0.35,
		BiomeSystem.Biome.COLD: 0.2, BiomeSystem.Biome.DESERT: 0.05,
	},
	ResourceNode.Type.STONE: {
		BiomeSystem.Biome.COLD: 1.0, BiomeSystem.Biome.DESERT: 0.9,
		BiomeSystem.Biome.PLAIN: 0.45, BiomeSystem.Biome.FOREST: 0.3,
	},
	ResourceNode.Type.GOLD: {
		BiomeSystem.Biome.COLD: 1.0, BiomeSystem.Biome.DESERT: 0.5,
		BiomeSystem.Biome.PLAIN: 0.1, BiomeSystem.Biome.FOREST: 0.05,
	},
}

@export var initial_population_per_species: int = 50
@export var initial_plants: int = 200
@export var initial_wood: int = 60
@export var initial_stone: int = 40
@export var initial_gold: int = 18
@export var min_plant_seeds: int = 80
@export var min_stone: int = 30
@export var min_gold: int = 12
@export var seed_rescue_interval: float = 8.0
@export var world_bounds: Vector2 = Vector2(60.0, 60.0)
## Margen interior (en metros) que se descuenta a cada borde al spawnear plantas.
## Las esferas se auto-claman su movimiento a `world_bounds/2 - 2.0` (ver
## `Sphere._seek_avoid_corners`), por lo que cualquier planta más allá de ese
## margen queda inalcanzable. Mantener `plant_border_padding >= 2.0`.
@export var plant_border_padding: float = 2.0
@export var spheres_parent_path: NodePath
@export var plants_parent_path: NodePath

# Layout de spawn derivado del preset (ver SimConfig / SimPreset).
var spawn_split: bool = false
var apex_enabled: bool = false
var apex_size: float = 3.0
var apex_species: StringName = &"A"
var population_size_max: float = Traits.SIZE_MAX

var _rng: RandomNumberGenerator
## true cuando el mundo ya está sembrado o restaurado (final de `_on_terrain_ready`).
## Antes no se guarda: la foto sería un mundo vacío y pisaría `auto.sav` (ver `World.save_game`).
var populated: bool = false
var _seed_timer: float = 0.0
var _resource_timer: float = 0.0   # rescate LENTO de yacimientos finitos (piedra/oro)


func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	# La pantalla de inicio fija la configuración en SimConfig; se lee aquí,
	# antes de generar biomas o spawnear, para que todo use el mismo tamaño.
	world_bounds = Vector2(SimConfig.world_size, SimConfig.world_size)
	initial_plants = SimConfig.initial_plants
	initial_population_per_species = SimConfig.initial_population_per_species
	initial_wood = SimConfig.initial_wood
	initial_stone = SimConfig.initial_stone
	initial_gold = SimConfig.initial_gold
	min_plant_seeds = SimConfig.min_plant_seeds
	min_stone = SimConfig.min_stone
	min_gold = SimConfig.min_gold
	spawn_split = SimConfig.spawn_split
	apex_enabled = SimConfig.apex_enabled
	apex_size = SimConfig.apex_size
	apex_species = SimConfig.apex_species
	population_size_max = SimConfig.population_size_max
	# Garantizar que el mapa de biomas existe (el Spawner corre antes que
	# World._ready porque es hijo; World podría no haber generado los biomas aún).
	# La semilla del preset (-1 = aleatoria) hace reproducibles los escenarios.
	if not Biomes.is_generated:
		Biomes.generate(world_bounds, SimConfig.biome_seed)
	# Esperar a que World termine de construir el terreno y el collider antes
	# de spawnear entidades. World emite terrain_ready al final de _ready().
	var world := get_parent() as World
	if world != null:
		world.terrain_ready.connect(_on_terrain_ready, CONNECT_ONE_SHOT)
	else:
		_on_terrain_ready()


func _on_terrain_ready() -> void:
	# Esperar a que el NavigationServer haya sincronizado el mapa: si
	# spawneamos antes, (a) la validación contra el navmesh falla en silencio
	# por no estar listo, (b) la primera llamada de `_wander`/`_seek` de una
	# esfera recién creada provoca el ERROR "navigation map query failed
	# before first map synchronization".
	var world := get_parent() as World
	if world != null:
		await world.await_nav_ready()
	# Rama de carga: si hay un save pendiente (ver `SimConfig.pending_save`), se
	# restaura en lugar de sembrar el mundo inicial: el save trae todas las entidades
	# (esferas, plantas, árboles, yacimientos, granjas y cadáveres) y los temporizadores
	# de rescate de este Spawner, así que aquí no se siembra nada.
	if not SimConfig.pending_save.is_empty():
		var node_of: Array = SaveGame.restore(self, SimConfig.pending_save)
		SimConfig.pending_save = {}
		save_restored.emit(node_of)
	else:
		_spawn_initial_plants()
		_spawn_initial_resources()
		_spawn_initial_population()
	SimulationClock.tick.connect(_on_tick)
	populated = true


func _spawn_initial_population() -> void:
	# Depredador apex: un individuo gigante adicional entre la población pequeña.
	if apex_enabled:
		_spawn_sphere(apex_species, 0, apex_size, true)
	# Dos tribus: A en la mitad -X, B en la +X (x_side). Sin split, ambas en todo
	# el plano (x_side = 0).
	var side_a: int = -1 if spawn_split else 0
	var side_b: int = 1 if spawn_split else 0
	for i in initial_population_per_species:
		_spawn_sphere(&"A", side_a)
		_spawn_sphere(&"B", side_b)


func _spawn_initial_plants() -> void:
	# Reparto en rejilla con jitter para cubrir el plano uniformemente.
	# Encogemos el área disponible por `plant_border_padding` en cada borde
	# para no sembrar comida fuera del alcance efectivo de las esferas.
	var usable_x: float = max(0.0, world_bounds.x - 2.0 * plant_border_padding)
	var usable_z: float = max(0.0, world_bounds.y - 2.0 * plant_border_padding)
	var cols: int = int(ceil(sqrt(float(initial_plants))))
	var rows: int = int(ceil(float(initial_plants) / float(cols)))
	var step_x: float = usable_x / float(cols)
	var step_z: float = usable_z / float(rows)
	var half_x: float = usable_x * 0.5
	var half_z: float = usable_z * 0.5
	var jitter_x: float = step_x * 0.4
	var jitter_z: float = step_z * 0.4
	var placed: int = 0
	for r in rows:
		for c in cols:
			if placed >= initial_plants:
				return
			var cx: float = -half_x + (c + 0.5) * step_x
			var cz: float = -half_z + (r + 0.5) * step_z
			var pos: Vector3 = Vector3(
				cx + _rng.randf_range(-jitter_x, jitter_x),
				0.0,
				cz + _rng.randf_range(-jitter_z, jitter_z),
			)
			# Fijar Y al terreno ANTES de validar contra navmesh: el navmesh
			# sigue al terreno y `map_get_closest_point` con Y=0 contra
			# polígonos en pendiente devuelve un snap desplazado lateralmente
			# (proyección sobre el plano inclinado) → todas las celdas
			# parecerían "fuera del navmesh" aunque estén justo encima de él.
			pos.y = _terrain_height(pos.x, pos.z) + 0.25
			if not Biomes.is_walkable_at(pos):
				# No penalizar placed: la celda de agua no ocupa cupo de planta.
				continue
			# Además del bioma, exigir que el navmesh alcance esa posición:
			# franjas walkable-pero-sin-navmesh (orillas, picos recortados)
			# producirían comida fantasma que nadie puede comer.
			if not _world_ref().is_navmesh_reachable(pos):
				continue
			_spawn_plant_at(pos, true)
			placed += 1


## Siembra los recursos de economía (madera/piedra/oro) sesgados por bioma. Se
## parentean al propio Spawner (no al nodo de plantas) para no contaminar el conteo
## del respawn de rescate de comida. El render los recoge por grupo, no por padre.
func _spawn_initial_resources() -> void:
	_spawn_resource_type(initial_wood, ResourceNode.Type.WOOD)
	_spawn_resource_type(initial_stone, ResourceNode.Type.STONE)
	_spawn_resource_type(initial_gold, ResourceNode.Type.GOLD)


## Coloca `count` nodos de `type` por muestreo con RECHAZO según el peso de bioma
## (RESOURCE_BIOME_WEIGHT). Reusa `_random_position` (walkable) y exige navmesh,
## igual que el sembrado de plantas, para no generar recursos inalcanzables.
func _spawn_resource_type(count: int, type: int) -> void:
	if count <= 0:
		return
	var weights: Dictionary = _resource_biome_weight.get(type, {})
	var placed: int = 0
	var attempts: int = 0
	var max_attempts: int = count * 40
	while placed < count and attempts < max_attempts:
		attempts += 1
		var pos: Vector3 = _random_position(plant_border_padding)
		var w: float = float(weights.get(Biomes.biome_at(pos), 0.0))
		if w <= 0.0 or _rng.randf() > w:
			continue
		pos.y = _terrain_height(pos.x, pos.z) + 0.25
		if not _world_ref().is_navmesh_reachable(pos):
			continue
		if type == ResourceNode.Type.WOOD:
			_spawn_tree_at(pos)
		else:
			_spawn_deposit_at(pos, type)
		placed += 1


func _spawn_tree_at(pos: Vector3) -> void:
	var tree: TreeNode = TREE_SCENE.instantiate()
	add_child(tree)
	tree.world_bounds = world_bounds
	tree.global_position = pos
	# Arrancan maduros con edad repartida (no maduran/rebrotan en bloque).
	tree.stage = TreeNode.Stage.MATURE
	tree.age = _rng.randf() * TreeNode.REGROW_TIME
	tree.activate()


func _spawn_deposit_at(pos: Vector3, type: int) -> void:
	var dep: Deposit = DEPOSIT_SCENE.instantiate()
	add_child(dep)
	dep.world_bounds = world_bounds
	dep.deposit_type = type
	if type == ResourceNode.Type.GOLD:
		# El oro es escaso pero debe dar para que el poder actúe: yacimientos algo
		# más ricos, una unidad por extracción.
		dep.units_total = _rng.randi_range(3, 8)
		dep.units_per_harvest = 1
	else:
		# La piedra es abundante: cada yacimiento rinde mucho y suelta varias
		# unidades por extracción para que no exija decenas de viajes.
		dep.units_total = _rng.randi_range(20, 40)
		dep.units_per_harvest = 3
	dep.global_position = pos
	dep.activate()


func _on_tick(dt_sim: float) -> void:
	# Regeneración LENTA de piedra/oro: los yacimientos finitos se agotan; este
	# rescate los repone despacio hasta un mínimo para que la economía no muera.
	_resource_timer += dt_sim
	if _resource_timer >= GlobalParams.tuning.resource_rescue_interval:
		_resource_timer = 0.0
		_rescue_resource(&"stone_nodes", min_stone, ResourceNode.Type.STONE)
		_rescue_resource(&"gold_nodes", min_gold, ResourceNode.Type.GOLD)

	_seed_timer += dt_sim
	if _seed_timer < seed_rescue_interval:
		return
	_seed_timer = 0.0
	var parent: Node = _resolve_parent(plants_parent_path)
	var current: int = parent.get_child_count()
	# El suelo escala con la polinización de los eventos (una sequía no se tapa con
	# el rescate), pero no sube con la abundancia: el tope es `plants_total_max`.
	var min_seeds: int = int(min_plant_seeds * Climate.food_supply_scale())
	if current >= min_seeds:
		return
	for i in (min_seeds - current):
		_spawn_plant(false)


## Repone yacimientos de `type` hasta `minimum` si el mundo cae por debajo (cuenta
## los nodos vivos del grupo de escena). Reusa el sembrado por bioma.
func _rescue_resource(group: StringName, minimum: int, type: int) -> void:
	var current: int = get_tree().get_nodes_in_group(group).size()
	if current >= minimum:
		return
	_spawn_resource_type(minimum - current, type)


## Spawnea una esfera. `x_side`: -1 = mitad -X, +1 = mitad +X, 0 = todo el plano
## (para "Dos tribus"). `size_override` > 0 fija el tamaño (apex); si no, se aplica
## el cap `population_size_max`. `apex` sube agresividad y valentía del campeón.
func _spawn_sphere(species: StringName, x_side: int = 0, size_override: float = -1.0, apex: bool = false) -> void:
	var sphere: Sphere = SPHERE_SCENE.instantiate()
	var parent: Node = _resolve_parent(spheres_parent_path)
	parent.add_child(sphere)
	var pos := _random_position(0.0, x_side)
	pos.y = _terrain_height(pos.x, pos.z) + 0.5
	sphere.global_position = pos
	var genome: Dictionary = Traits.random_genome(_rng, species)
	if size_override > 0.0:
		genome["size"] = size_override
	elif population_size_max < Traits.SIZE_MAX:
		genome["size"] = minf(float(genome["size"]), population_size_max)
	if apex:
		genome["aggression"] = maxf(float(genome.get("aggression", 0.5)), 0.85)
		genome["bravery"] = maxf(float(genome.get("bravery", 0.5)), 0.85)
	sphere.setup(genome, world_bounds, 1)
	sphere.activate()


func _spawn_plant(start_mature: bool) -> void:
	# Las semillas de rescate también respetan el padding: si caen demasiado
	# cerca del borde la esfera no logra alcanzarlas y la planta envejece sola.
	_spawn_plant_at(_random_position(plant_border_padding), start_mature)


func _spawn_plant_at(pos: Vector3, start_mature: bool) -> void:
	var plant: Plant = PLANT_SCENE.instantiate()
	var parent: Node = _resolve_parent(plants_parent_path)
	parent.add_child(plant)
	plant.world_bounds = world_bounds
	pos.y = _terrain_height(pos.x, pos.z) + 0.25
	plant.global_position = pos
	if start_mature:
		plant.stage = Plant.Stage.MATURE
		# Distribuir edades para que los 200 iniciales no se marchiten en masa.
		plant.age = _rng.randf() * Plant.MATURE_LIFETIME
	# activate() como último paso: registra la planta ya posicionada y con
	# su estado final (ver Plant.activate()).
	plant.activate()


func _random_position(border_padding: float = 0.0, x_side: int = 0) -> Vector3:
	# NOTA: aquí NO exigimos navmesh-reachable. Esto lo usan tanto plantas
	# como esferas; añadir esa restricción aquí spawneaba TODAS las esferas
	# en (0,0) cuando el seed daba un navmesh muy recortado (caída al
	# fallback espiral → return Vector3.ZERO). Las esferas no la necesitan:
	# si caen en una franja walkable sin navmesh se mueven y la encuentran;
	# las plantas sí la necesitan (son estáticas → "comida fantasma") y
	# añaden la comprobación en su propio sitio de spawn.
	# `border_padding` reduce el área de spawn por cada borde (útil para plantas).
	# `x_side` restringe el eje X a una mitad del plano (para "Dos tribus").
	var half_x: float = max(0.0, world_bounds.x * 0.5 - border_padding)
	var half_z: float = max(0.0, world_bounds.y * 0.5 - border_padding)
	var x_min: float = -half_x
	var x_max: float = half_x
	if x_side < 0:
		x_max = 0.0
	elif x_side > 0:
		x_min = 0.0
	for _attempt in 16:
		var pos := Vector3(
			_rng.randf_range(x_min, x_max),
			0.0,
			_rng.randf_range(-half_z, half_z),
		)
		if Biomes.is_walkable_at(pos):
			return pos
	# Fallback en espiral desde el centro si todos los intentos aleatorios fallan.
	for radius in [2.0, 5.0, 10.0, 20.0]:
		for _i in 8:
			var angle := _rng.randf() * TAU
			var pos := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			if Biomes.is_walkable_at(pos):
				return pos
	return Vector3.ZERO


func _world_ref() -> World:
	return get_parent() as World


## Obtiene la altura del terreno delegando en World, que mantiene la rejilla
## precalculada con interpolación bilineal.
func _terrain_height(x: float, z: float) -> float:
	var world := get_parent() as World
	if world != null:
		return world.get_terrain_height(x, z)
	return 0.0


func _resolve_parent(path: NodePath) -> Node:
	if path.is_empty():
		return self
	var node: Node = get_node_or_null(path)
	return node if node != null else self
