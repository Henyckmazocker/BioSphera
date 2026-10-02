class_name SpatialHashGrid
extends RefCounted
## Spatial hash grid 2D (plano XZ) para queries de radio en O(k).
##
## Necesario para escalar el `vision` query y combate cuando hay ≥ 200 esferas.
## Reemplaza el scan O(n²) que usaba la Fase 1. Ver docs: docs/Programación.md
## (sección "Espacial: detección de vecinos").

var cell_size: float
var _cells: Dictionary = {}   # Vector2i -> Array[Variant]
var _positions: Dictionary = {}  # item -> Vector2i


func _init(p_cell_size: float = 4.0) -> void:
	cell_size = p_cell_size


func clear() -> void:
	_cells.clear()
	_positions.clear()


func _cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / cell_size)), int(floor(pos.z / cell_size)))


func insert(item: Variant, pos: Vector3) -> void:
	var cell: Vector2i = _cell_of(pos)
	var bucket: Array = _cells.get(cell, [])
	bucket.append(item)
	_cells[cell] = bucket
	_positions[item] = cell


func remove(item: Variant) -> void:
	if not _positions.has(item):
		return
	var cell: Vector2i = _positions[item]
	var bucket: Array = _cells.get(cell, [])
	bucket.erase(item)
	if bucket.is_empty():
		_cells.erase(cell)
	else:
		_cells[cell] = bucket
	_positions.erase(item)


func update(item: Variant, pos: Vector3) -> void:
	var new_cell: Vector2i = _cell_of(pos)
	var old_cell: Variant = _positions.get(item)
	if old_cell == new_cell:
		return
	if old_cell != null:
		var old_bucket: Array = _cells.get(old_cell, [])
		old_bucket.erase(item)
		if old_bucket.is_empty():
			_cells.erase(old_cell)
	var bucket: Array = _cells.get(new_cell, [])
	bucket.append(item)
	_cells[new_cell] = bucket
	_positions[item] = new_cell


## Devuelve los buckets (POR REFERENCIA, sin copiar items) de las celdas que
## solapan el AABB del radio. El llamante itera estos buckets y aplica el filtro
## de distancia exacta, evitando construir un array intermedio con TODOS los
## candidatos (antes: un array aquí + otro filtrado en SpatialIndex → ahora solo
## el array final filtrado). No modificar los buckets devueltos.
func query_cells(pos: Vector3, radius: float) -> Array:
	var buckets: Array = []
	var min_c: Vector2i = _cell_of(Vector3(pos.x - radius, 0.0, pos.z - radius))
	var max_c: Vector2i = _cell_of(Vector3(pos.x + radius, 0.0, pos.z + radius))
	for cx in range(min_c.x, max_c.x + 1):
		for cy in range(min_c.y, max_c.y + 1):
			var bucket: Variant = _cells.get(Vector2i(cx, cy))
			if bucket != null:
				buckets.append(bucket)
	return buckets
