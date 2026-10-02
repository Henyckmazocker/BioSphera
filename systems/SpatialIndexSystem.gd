extends Node
## Índice espacial global de la simulación (autoload `SpatialIndex`).
##
## Mantiene varios hash grids: uno de esferas y uno por cada tipo de recurso
## (`ResourceNode.Type`). Cualquier entidad debe llamar a `register_*` al spawnear
## y `update_*` cuando se mueve. Las queries por radio son O(k) en lugar de O(n).
##
## La COMIDA conserva su grid y su API histórica (`register_plant`/`query_plants`)
## como alias del tipo FOOD, para no tocar el camino de alimentación ya existente
## (ver `GroupSystem`, `Sphere`). Madera/piedra/oro tienen un grid propio cada uno,
## de modo que buscar un recurso no escanea los de otro tipo.

const SpatialHashGridScript: GDScript = preload("res://systems/SpatialHashGrid.gd")

const SPHERE_CELL_SIZE: float = 5.0
const RESOURCE_CELL_SIZE: float = 4.0

var _spheres: SpatialHashGrid
# type:int (ResourceNode.Type) -> SpatialHashGrid
var _resource_grids: Dictionary = {}


func _ready() -> void:
	_spheres = SpatialHashGridScript.new(SPHERE_CELL_SIZE)
	for t in [ResourceNode.Type.FOOD, ResourceNode.Type.WOOD,
			ResourceNode.Type.STONE, ResourceNode.Type.GOLD]:
		_resource_grids[t] = SpatialHashGridScript.new(RESOURCE_CELL_SIZE)


func register_sphere(sphere: Node3D) -> void:
	_spheres.insert(sphere, sphere.global_position)


func update_sphere(sphere: Node3D) -> void:
	_spheres.update(sphere, sphere.global_position)


func unregister_sphere(sphere: Node3D) -> void:
	_spheres.remove(sphere)


# ---------------- RECURSOS (genérico por tipo) ----------------

func register_resource(node: Node3D, type: int) -> void:
	(_resource_grids[type] as SpatialHashGrid).insert(node, node.global_position)


func update_resource(node: Node3D, type: int) -> void:
	(_resource_grids[type] as SpatialHashGrid).update(node, node.global_position)


func unregister_resource(node: Node3D, type: int) -> void:
	(_resource_grids[type] as SpatialHashGrid).remove(node)


func query_resources(pos: Vector3, radius: float, type: int) -> Array:
	return _query_grid(_resource_grids[type], pos, radius)


# ---------------- COMIDA (alias del tipo FOOD) ----------------

func register_plant(plant: Node3D) -> void:
	register_resource(plant, ResourceNode.Type.FOOD)


func update_plant(plant: Node3D) -> void:
	update_resource(plant, ResourceNode.Type.FOOD)


func unregister_plant(plant: Node3D) -> void:
	unregister_resource(plant, ResourceNode.Type.FOOD)


func query_plants(pos: Vector3, radius: float) -> Array:
	return query_resources(pos, radius, ResourceNode.Type.FOOD)


# ---------------- ESFERAS / HELPER ----------------

func query_spheres(pos: Vector3, radius: float) -> Array:
	return _query_grid(_spheres, pos, radius)


## Recorre las celdas del grid que solapan el círculo (pos, radius) y filtra por
## distancia real al cuadrado. Compartido por todas las queries por radio.
func _query_grid(grid: SpatialHashGrid, pos: Vector3, radius: float) -> Array:
	var r2: float = radius * radius
	var result: Array = []
	for bucket in grid.query_cells(pos, radius):
		for item in bucket:
			var ip: Vector3 = (item as Node3D).global_position
			var dx: float = ip.x - pos.x
			var dz: float = ip.z - pos.z
			if dx * dx + dz * dz <= r2:
				result.append(item)
	return result
