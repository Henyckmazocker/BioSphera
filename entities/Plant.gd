class_name Plant
extends ResourceNode
## Planta con ciclo de vida y polinización (Fase 2).
##
## Sustituye al placeholder `Food` de Fase 1. Crece, da energía al ser
## comida, puede agotarse y se reproduce vía polinización (necesita
## plantas vecinas y/o presencia de esferas que la visiten).
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Plantas: ciclo de vida y polinización")
## y docs/GDD/Mundo y Niveles.md (sección "Modificación del entorno por las esferas").

signal consumed(amount: float)
signal died

enum Stage { SEED, GROWING, MATURE, WILTED }

const GROW_TIME: float = 12.0
const MATURE_LIFETIME: float = 45.0
const POLLINATION_RADIUS: float = 10.0
const VISIT_BOOST: float = 0.02
const NEIGHBOR_RATE: float = 0.005
const SEED_THRESHOLD: float = 1.0
const ENERGY_PER_BITE: float = 18.0
const MAX_BITES: int = 3
## Distancia mínima a otra planta al germinar una semilla (evita solapes). La
## densidad de área la limita el tope por celda de la rejilla territorial
## (`TerritorySystem.cell_has_room_for_plant`, tuning `plants_per_cell_max`).
const MIN_SEED_DISTANCE: float = 1.2

# `world_bounds`, `type`, `_rng` y `_world` viven ahora en `ResourceNode`.
@export var stage: Stage = Stage.SEED
var age: float = 0.0
var pollination: float = 0.0
var bites_left: int = MAX_BITES
var visited_this_tick: bool = false
# Grupo propietario si la planta la sembró una granja (-1 = silvestre). Comerla
# siendo ajeno cuenta como ROBO (ver Sphere._eat / GroupSystem.register_theft).
# Las semillas de polinización de esta planta NO heredan la propiedad.
var owner_group_id: int = -1
# El robo se cobra UNA sola vez por planta (no por bocado): evita inundar la
# penalización de afinidad cuando varias esferas la mordisquean.
var theft_charged: bool = false
# ¿Esta planta está contabilizada en el contador por celda de TerritorySystem? Se
# marca en activate() y se usa en _exit_tree() para no restar si se liberó antes
# de activar (evita conteos negativos).
var _counted: bool = false


func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	_world = get_tree().get_first_node_in_group("world") as World
	add_to_group(&"plants")


## Activación explícita: la llama quien instancia la planta como ÚLTIMO paso,
## una vez asignados posición y estado definitivos. Centraliza en un único
## momento todo lo que depende de esos datos (registro espacial, visuales,
## tick, log), eliminando la clase de bug "registrada antes de posicionar".
func activate() -> void:
	# Cadencia lenta: crecimiento/polinización son procesos de segundos; no
	# necesitan tickear cada frame (la query de polinización es cara).
	SimulationClock.register_entity(self, true)
	SpatialIndex.register_plant(self)
	TerritorySystem.add_plant_at(global_position)
	_counted = true
	EventLog.log_state_change(&"plants", &"spawn", {
		"id": get_instance_id(),
		"stage": _stage_name(stage),
		"position": [global_position.x, global_position.y, global_position.z],
	})


func _exit_tree() -> void:
	SimulationClock.unregister_entity(self)
	SpatialIndex.unregister_plant(self)
	if _counted:
		TerritorySystem.remove_plant_at(global_position)
		_counted = false


func consume() -> float:
	if stage != Stage.MATURE or bites_left <= 0:
		return 0.0
	bites_left -= 1
	consumed.emit(ENERGY_PER_BITE)
	# Visitar madura aporta polinización (mini boost).
	pollination += VISIT_BOOST
	if bites_left <= 0:
		_die()
	return ENERGY_PER_BITE


## API común de ResourceNode: para la comida, extraer == comer un bocado. El
## camino de alimentación de `Sphere` sigue llamando a `consume()` directamente;
## esto solo homogeneiza el trato genérico del recurso.
func harvest() -> float:
	var amount: float = consume()
	if amount > 0.0:
		harvested.emit(Type.FOOD, amount)
	return amount


func is_harvestable() -> bool:
	return stage == Stage.MATURE and bites_left > 0


func register_visit() -> void:
	visited_this_tick = true


func _on_tick(dt_sim: float) -> void:
	var biome_growth: float = Biomes.get_mod(Biomes.biome_at(global_position), "plant_growth_mod")
	var season_mod: float = Climate.plant_growth_modifier()
	# Los eventos del entorno (sequía) aceleran solo la marchitez de las maduras.
	var wilt_mod: float = Climate.plant_wilt_modifier() if stage == Stage.MATURE else 1.0
	age += dt_sim * biome_growth * season_mod * wilt_mod
	match stage:
		Stage.SEED, Stage.GROWING:
			if age >= GROW_TIME:
				_transition_to(Stage.MATURE)
		Stage.MATURE:
			# Polinización: recibe contribución de vecinos maduros + visitas.
			var neighbors: Array = SpatialIndex.query_plants(global_position, POLLINATION_RADIUS)
			var mature_count: int = 0
			for n in neighbors:
				if n != self and n is Plant and n.stage == Stage.MATURE:
					mature_count += 1
			# Estación compuesta con los eventos del entorno (ver `Climate`).
			var pollination_mod: float = Climate.pollination_modifier()
			pollination += NEIGHBOR_RATE * mature_count * dt_sim * pollination_mod
			if visited_this_tick:
				pollination += VISIT_BOOST * dt_sim * pollination_mod
				visited_this_tick = false
			if pollination >= SEED_THRESHOLD:
				pollination = 0.0
				_try_spawn_seed()
			if age >= MATURE_LIFETIME:
				_transition_to(Stage.WILTED)
		Stage.WILTED:
			_die()


func _transition_to(new_stage: Stage) -> void:
	var prev: Stage = stage
	stage = new_stage
	if new_stage == Stage.MATURE:
		age = 0.0
	# La escala visual por estado (SEED/GROWING/MATURE/WILTED) la aplica
	# `EntityRenderer` leyendo `stage` cada frame.
	EventLog.log_state_change(&"plants", &"stage_change", {
		"id": get_instance_id(),
		"position": [global_position.x, global_position.y, global_position.z],
		"prev_stage": _stage_name(prev),
		"new_stage": _stage_name(new_stage),
		"age": age,
		"pollination": pollination,
		"bites_left": bites_left,
	})


static func _stage_name(s: Stage) -> String:
	match s:
		Stage.SEED: return "seed"
		Stage.GROWING: return "growing"
		Stage.MATURE: return "mature"
		Stage.WILTED: return "wilted"
		_: return "unknown"


# ---------------- GUARDADO ----------------
# Ver `SaveGame` y `Sphere.to_save`. El orden de registro en `SimulationClock._slow` lo
# reproduce `SaveGame.restore` llamando a `from_save` en el orden guardado.

## Foto de esta planta para el save. `_counted` no se guarda: lo pone `activate()`, que
## también la vuelve a sumar a `TerritorySystem._plant_counts`.
func to_save(_ids: Dictionary) -> Dictionary:
	return {
		"k": &"plant",
		"pos": global_position,
		"stage": stage,
		"age": age,
		"pollination": pollination,
		"bites_left": bites_left,
		"owner_group_id": owner_group_id,
		"theft_charged": theft_charged,
	}


## Restaura desde `to_save`. Precondición: ya en el árbol y con `world_bounds` fijado.
## `activate()` no pisa ningún campo guardado, así que va al final sin sobrescrituras.
func from_save(d: Dictionary, _node_of: Array) -> void:
	global_position = d.pos
	stage = int(d.stage) as Stage
	age = float(d.age)
	pollination = float(d.pollination)
	bites_left = int(d.bites_left)
	owner_group_id = int(d.owner_group_id)
	theft_charged = bool(d.theft_charged)
	activate()


func _try_spawn_seed() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	# La descendencia puede arraigar en CUALQUIER punto del mapa, sin relación con
	# la posición de la madre: así la reproducción no concentra la vegetación
	# alrededor de los cúmulos de plantas maduras. Probamos varias posiciones
	# uniformes dentro del plano jugable y descartamos las inválidas (agua, fuera
	# de navmesh, celda llena, solape con otra planta).
	var half_x: float = world_bounds.x * 0.5
	var half_z: float = world_bounds.y * 0.5
	for attempt in 6:
		var spawn_pos: Vector3 = Vector3(
			_rng.randf_range(-half_x, half_x), 0.0, _rng.randf_range(-half_z, half_z))
		# Fijar Y al terreno ANTES de validar contra navmesh: con una Y que no
		# case con la altura del terreno, el snap a un polígono en pendiente se
		# desvía lateralmente y rechazaría posiciones válidas.
		if _world != null:
			spawn_pos.y = _world.get_terrain_height(spawn_pos.x, spawn_pos.z) + 0.25
		# No germinar en agua ni en biomas no aptos (growth = 0).
		if not Biomes.is_walkable_at(spawn_pos):
			continue
		# Y, además, exigir que el navmesh alcance la posición: la rejilla
		# por bioma es más permisiva que el bake (franjas de orilla, picos
		# recortados por agent_radius). Sin esto la semilla puede arraigar
		# en una "celda fantasma" inaccesible — comida que nadie puede comer.
		if _world != null and not _world.is_navmesh_reachable(spawn_pos):
			continue
		# Tope de densidad por celda de la rejilla (silvestres + granja).
		if not TerritorySystem.cell_has_room_for_plant(spawn_pos):
			continue
		# Espaciado mínimo: rechazar si hay otra planta demasiado cerca.
		var too_close: bool = false
		for n in SpatialIndex.query_plants(spawn_pos, MIN_SEED_DISTANCE):
			if n is Plant and n.global_position.distance_to(spawn_pos) < MIN_SEED_DISTANCE:
				too_close = true
				break
		if too_close:
			continue
		# spawn_pos.y ya fijado al terreno antes de las validaciones.
		var plant: Plant = (preload("res://entities/Plant.tscn") as PackedScene).instantiate()
		parent.add_child(plant)
		plant.world_bounds = world_bounds
		plant.global_position = spawn_pos
		plant.stage = Stage.SEED
		plant.activate()
		return


func _die() -> void:
	died.emit()
	queue_free()
