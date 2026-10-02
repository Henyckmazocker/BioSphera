class_name ResourceNode
extends Node3D
## Base común de los recursos cosechables del mundo (Fase de economía).
##
## Unifica los cuatro recursos del juego bajo un mismo tipo y una misma API de
## extracción, para que la recolección, el índice espacial y el render los traten
## de forma homogénea:
##   - FOOD  → `Plant`: regenerable con polinización (sin cambios respecto a antes).
##   - WOOD  → `TreeNode`: regenerable simple (crece, se extrae, rebrota).
##   - STONE/GOLD → `Deposit`: yacimiento FINITO (se agota y desaparece).
##
## El registro en el índice espacial se hace POR TIPO (ver SpatialIndexSystem):
## buscar madera no escanea piedra ni comida. La comida conserva su propio grid
## (`register_plant`/`query_plants`) por compatibilidad con el camino de alimentación.
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Economía y recursos").

enum Type { FOOD, WOOD, STONE, GOLD }

## Tipo y cantidad obtenidos en cada extracción (los consume el recolector).
signal harvested(type: int, amount: float)
## El recurso se agotó (yacimiento finito) o murió (regenerable).
signal depleted

@export var world_bounds: Vector2 = Vector2(60.0, 60.0)

## Tipo de recurso. Las subclases lo fijan en su `_ready` (FOOD por defecto para
## que `Plant`, que no toca este campo, siga clasificándose como comida).
var type: int = Type.FOOD

var _rng: RandomNumberGenerator
var _world: World   # referencia cacheada al mundo (altura de terreno, navmesh)


## Nombre de grupo de escena por tipo. La comida reutiliza el grupo histórico
## `&"plants"` (lo recorren EntityRenderer y GroupSystem); los demás tienen el suyo.
static func group_for(t: int) -> StringName:
	match t:
		Type.WOOD: return &"wood_nodes"
		Type.STONE: return &"stone_nodes"
		Type.GOLD: return &"gold_nodes"
		_: return &"plants"


static func type_name(t: int) -> String:
	match t:
		Type.FOOD: return "food"
		Type.WOOD: return "wood"
		Type.STONE: return "stone"
		Type.GOLD: return "gold"
		_: return "unknown"


## Inicialización compartida: la invocan las subclases al inicio de su `_ready()`.
## Cachea el RNG y la referencia al mundo (igual que hacía `Plant._ready`).
func _init_resource_node() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	_world = get_tree().get_first_node_in_group("world") as World


## Baja del índice espacial y del reloj al salir del árbol. `Plant` mantiene su
## propio `_exit_tree` (equivalente vía alias FOOD); `Tree`/`Deposit` lo heredan.
## `unregister_entity` es idempotente, así que sirve también para recursos que no
## tickean (yacimientos finitos).
func _exit_tree() -> void:
	SimulationClock.unregister_entity(self)
	SpatialIndex.unregister_resource(self, type)


## Extrae recurso. Las subclases la implementan; devuelve la cantidad obtenida
## (0.0 si ahora mismo no hay nada que extraer) y emiten `harvested`.
func harvest() -> float:
	return 0.0


## ¿Queda algo que extraer ahora mismo? Lo concretan las subclases. Lo usa la IA
## de recolección para descartar nodos agotados/inmaduros al elegir objetivo.
func is_harvestable() -> bool:
	return false
