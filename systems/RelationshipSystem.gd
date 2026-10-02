extends Node
## Memoria social de las esferas (autoload `Relationships`).
##
## Mantiene un mapa por individuo de afinidades hacia otros individuos.
## La capacidad por esfera es la `GlobalParams.social_memory_capacity`:
## cuando se excede, se purgan los recuerdos más débiles.
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Relaciones interpersonales").

const AFFINITY_MIN: float = -100.0
const AFFINITY_MAX: float = 100.0

var _memory: Dictionary = {}  # sphere_id -> Dictionary[other_id -> float]


func adjust(a_id: int, b_id: int, delta: float) -> void:
	if a_id == b_id:
		return
	_set_affinity(a_id, b_id, _get_affinity(a_id, b_id) + delta)
	_set_affinity(b_id, a_id, _get_affinity(b_id, a_id) + delta)


## Ajuste asimétrico: solo `from_id` cambia su opinión sobre `to_id`.
## Útil cuando un evento es perceptible por un lado pero no por el otro
## (ej. ceder un alimento: el cedente resiente al rival; el rival ni se
## entera de que "ganó").
func adjust_one_way(from_id: int, to_id: int, delta: float) -> void:
	if from_id == to_id:
		return
	_set_affinity(from_id, to_id, _get_affinity(from_id, to_id) + delta)


func get_affinity(a_id: int, b_id: int) -> float:
	return _get_affinity(a_id, b_id)


## Mapa completo `other_id → afinidad` de las relaciones que la esfera
## `sphere_id` recuerda. Copia: el llamador puede modificarlo sin afectar
## a la memoria social interna. Usado por la visualización (líneas de
## relación al inspeccionar) y por la UI (lista de afinidades).
func get_all(sphere_id: int) -> Dictionary:
	var book: Dictionary = _memory.get(sphere_id, {})
	return book.duplicate()


func forget(sphere_id: int) -> void:
	_memory.erase(sphere_id)
	for other_id in _memory.keys():
		var book: Dictionary = _memory[other_id]
		book.erase(sphere_id)


func _get_affinity(a: int, b: int) -> float:
	var book: Dictionary = _memory.get(a, {})
	return float(book.get(b, 0.0))


func _set_affinity(a: int, b: int, value: float) -> void:
	value = clampf(value, AFFINITY_MIN, AFFINITY_MAX)
	var book: Dictionary = _memory.get(a, {})
	book[b] = value
	_enforce_capacity(book)
	_memory[a] = book


func _enforce_capacity(book: Dictionary) -> void:
	var cap: int = GlobalParams.social_memory_capacity
	if book.size() <= cap:
		return
	# Purga los recuerdos con menor magnitud absoluta.
	var entries: Array = []
	for k in book.keys():
		entries.append([k, absf(book[k])])
	entries.sort_custom(func(a, b): return a[1] < b[1])
	var to_remove: int = book.size() - cap
	for i in to_remove:
		book.erase(entries[i][0])
