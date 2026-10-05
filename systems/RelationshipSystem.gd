extends Node
## Memoria social de las esferas (autoload `Relationships`).
##
## Mantiene un mapa por individuo de afinidades hacia otros individuos.
## La capacidad por esfera es la `GlobalParams.social_memory_capacity`:
## cuando se excede, se purgan los recuerdos más débiles.
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Relaciones interpersonales").

## Una afinidad mutua cruza `BOND_THRESHOLD` hacia arriba (la emite `adjust`). La escucha
## EffectsDirector para el bloom de afinidad alta.
signal bond_formed(a_id: int, b_id: int)

## Umbral de «afinidad alta»: 75, raro y vistoso (plan «Game Feel y Efectos Juicy»).
const BOND_THRESHOLD: float = 75.0
const AFFINITY_MIN: float = -100.0
const AFFINITY_MAX: float = 100.0

var _memory: Dictionary = {}  # sphere_id -> Dictionary[other_id -> float]


func adjust(a_id: int, b_id: int, delta: float) -> void:
	if a_id == b_id:
		return
	var old_ab: float = _get_affinity(a_id, b_id)
	var old_ba: float = _get_affinity(b_id, a_id)
	_set_affinity(a_id, b_id, old_ab + delta)
	_set_affinity(b_id, a_id, old_ba + delta)
	# Vínculo mutuo: cuenta la dirección más baja. Se compara el valor YA fijado
	# (clamp a ±100 y posible purga por capacidad), no la suma. Solo aquí: un ajuste
	# unilateral (`adjust_one_way`) no forma un vínculo mutuo, y `from_save` no pasa
	# por `adjust`, así que cargar una partida no emite nada.
	if delta > 0.0 and minf(old_ab, old_ba) < BOND_THRESHOLD \
			and minf(_get_affinity(a_id, b_id), _get_affinity(b_id, a_id)) >= BOND_THRESHOLD:
		bond_formed.emit(a_id, b_id)


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
	# Camino rápido (rendimiento): `_set_affinity` añade como mucho una clave, así
	# que casi siempre sobra UNA y el sort del libro entero (cientos de miles de
	# purgas por minuto con ~380 esferas) es coste puro. Si el mínimo de |afinidad|
	# es ÚNICO, cualquier ordenación correcta lo deja en la posición 0, así que
	# borrarlo directamente es idéntico al sort de abajo. Con EMPATE en el mínimo
	# (o un NaN) el sort de Godot no es estable y la clave borrada depende de su
	# algoritmo interno: ahí se sigue ordenando como siempre.
	if book.size() - cap == 1:
		var min_key: Variant = null
		var min_mag: float = INF
		var unique: bool = false
		for k in book:
			var mag: float = absf(book[k])
			if is_nan(mag):
				unique = false
				break
			if mag < min_mag:
				min_mag = mag
				min_key = k
				unique = true
			elif mag == min_mag:
				unique = false
		if unique:
			book.erase(min_key)
			return
	# Purga los recuerdos con menor magnitud absoluta.
	var entries: Array = []
	for k in book.keys():
		entries.append([k, absf(book[k])])
	entries.sort_custom(func(a, b): return a[1] < b[1])
	var to_remove: int = book.size() - cap
	for i in to_remove:
		book.erase(entries[i][0])


# ---------------- GUARDADO ----------------
# Ver `SaveGame`. `_memory` va por `instance_id`, que cambia en cada proceso: se
# traduce a índice de save y de vuelta. Un libro o recuerdo de una esfera que no entró
# en la foto (muerta, en cola de borrado) se descarta.

## `{idx: {idx: afinidad}}`.
func to_save(ids: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for a in _memory:
		if not ids.has(a):
			continue
		var book: Dictionary = _memory[a]
		var saved: Dictionary = {}
		for b in book:
			if ids.has(b):
				saved[int(ids[b])] = float(book[b])
		out[int(ids[a])] = saved
	return out


## Sustituye la memoria por la del save, con las claves resueltas a los `instance_id`
## de las esferas restauradas. Los libros se guardaron ya acotados por
## `social_memory_capacity` y se cargan tal cual (sin `_enforce_capacity`).
func from_save(d: Dictionary, node_of: Array) -> void:
	_memory.clear()
	for a_idx in d:
		var a: Node = _node_idx(node_of, int(a_idx))
		if a == null:
			continue
		var book: Dictionary = {}
		var saved: Dictionary = d[a_idx]
		for b_idx in saved:
			var b: Node = _node_idx(node_of, int(b_idx))
			if b != null:
				book[b.get_instance_id()] = float(saved[b_idx])
		_memory[a.get_instance_id()] = book


static func _node_idx(node_of: Array, idx: int) -> Node:
	if idx < 0 or idx >= node_of.size() or not is_instance_valid(node_of[idx]):
		return null
	return node_of[idx]
