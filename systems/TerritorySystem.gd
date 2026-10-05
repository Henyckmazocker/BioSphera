extends Node
## Mapa de dominancia territorial (autoload `TerritorySystem`).
##
## Rejilla de INFLUENCIA 2D sobre el plano XZ: cada celda acumula cuánta
## "presencia" ha dejado allí cada especie y cada grupo. Las esferas depositan
## influencia en su celda durante su cadencia de decisión y la influencia
## DECAE con el tiempo, así que una zona sigue "siendo de los suyos" unos
## segundos tras marcharse (efecto rastro). De ahí emergen territorios.
##
## A partir del mapa, dos consultas O(1) alimentan la IA (ver BehaviorSystem y
## Sphere):
##  - `rival_pressure_at`: cuánto territorio AJENO pisa una entidad → reluctancia
##    a moverse allí (coste blando) y miedo amplificado ante una amenaza real.
##  - `ownership_at`: cuánto domina una entidad su celda → ventaja de dueño
##    (más arrojo para pelear, menos miedo: defiende su zona).
##
## Decaimiento PEREZOSO: no hay tick periódico ni lista global de esferas. Cada
## celda guarda el instante de su último refresco; al depositar o consultar se
## la pone al día multiplicando por `0.5^(dt/half_life)`. Coste O(1) por celda
## tocada, memoria acotada (las celdas vacías se purgan al consultarlas).
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Territorialidad").

## Tamaño de celda territorial (m). Estructural: más gruesa que el hash de
## proximidad (esferas 5.0) — el territorio es una noción de zona, no de vecino.
const TERRITORY_CELL_SIZE: float = 8.0

## Influencia por debajo de la cual una entrada se considera nula y se purga.
const EPSILON: float = 0.001

# Vector2i celda -> { "species": {StringName -> float}, "groups": {int -> float}, "last_t": float }
var _cells: Dictionary = {}

# Vector2i celda -> nº de plantas vivas en ella. Reutiliza la misma rejilla que la
# influencia territorial para acotar la densidad de plantas por chunk (ver
# `cell_has_room_for_plant`). Independiente de `_cells` (no decae).
var _plant_counts: Dictionary = {}

# Total de plantas vivas en el escenario (silvestres + granja). Lo mantienen en
# O(1) los mismos hooks que `_plant_counts` y alimenta el tope global
# `plants_total_max` (ver `cell_has_room_for_plant`).
var _plant_total: int = 0

## Cadencia (s de simulación) del snapshot de dominio que se vuelca al log para
## análisis offline de comportamientos territoriales. El territorio cambia despacio
## (half-life de segundos), así que un muestreo espaciado basta y el fichero queda
## ligero. Una entrada por especie con celda dominada (relevante) se considera en
## disputa: ver `snapshot_summary`.
const LOG_INTERVAL: float = 5.0
## Fracción de `territory_dominance_full` por encima de la cual una especie cuenta
## como "presente de forma relevante" en una celda (para detectar fronteras).
const CONTESTED_FRACTION: float = 0.25
var _log_timer: float = 0.0


func _ready() -> void:
	# ÚNICO uso del tick aquí: logging diagnóstico periódico. El decaimiento sigue
	# siendo perezoso (sin recorrer celdas por frame); este tick solo acumula el
	# temporizador y, cada `LOG_INTERVAL`, vuelca un resumen al EventLog.
	SimulationClock.tick.connect(_on_tick)


func _on_tick(dt_sim: float) -> void:
	_log_timer += dt_sim
	if _log_timer < LOG_INTERVAL:
		return
	_log_timer = 0.0
	if _cells.is_empty():
		return
	EventLog.log_event(&"territory_snapshot", snapshot_summary(), &"territory")


## Vacía el mapa (p. ej. al iniciar una simulación nueva sin reiniciar la app).
func clear() -> void:
	_cells.clear()
	_plant_counts.clear()
	_plant_total = 0
	_log_timer = 0.0


func _cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / TERRITORY_CELL_SIZE)),
		int(floor(pos.z / TERRITORY_CELL_SIZE)))


# ---------------- DENSIDAD DE PLANTAS POR CELDA ----------------
# Tope compartido (silvestres + granja) por celda de la rejilla. Lo mantienen los
# hooks de ciclo de vida de `Plant` (`activate`/`_exit_tree`) en O(1).

## Registra una planta en la celda de `pos` (la llama `Plant.activate`).
func add_plant_at(pos: Vector3) -> void:
	var cell: Vector2i = _cell_of(pos)
	_plant_counts[cell] = int(_plant_counts.get(cell, 0)) + 1
	_plant_total += 1


## Da de baja una planta de la celda de `pos` (la llama `Plant._exit_tree`).
func remove_plant_at(pos: Vector3) -> void:
	var cell: Vector2i = _cell_of(pos)
	var n: int = int(_plant_counts.get(cell, 0)) - 1
	if n <= 0:
		_plant_counts.erase(cell)
	else:
		_plant_counts[cell] = n
	_plant_total = maxi(0, _plant_total - 1)


## Nº de plantas vivas en la celda de `pos`.
func plant_count_at(pos: Vector3) -> int:
	return int(_plant_counts.get(_cell_of(pos), 0))


## Total de plantas vivas en todo el escenario (silvestres + granja).
func total_plant_count() -> int:
	return _plant_total


## ¿Cabe una planta más en `pos`? Dos topes: la densidad por celda
## (`plants_per_cell_max`) y el tope GLOBAL del escenario (`plants_total_max`).
## Lo consultan todas las rutas de siembra orgánica (polinización y granjas).
func cell_has_room_for_plant(pos: Vector3) -> bool:
	if _plant_total >= GlobalParams.tuning.plants_total_max:
		return false
	return plant_count_at(pos) < GlobalParams.tuning.plants_per_cell_max


## Suma influencia a la celda de `pos`. La llaman las esferas al decidir acción.
func deposit(pos: Vector3, species: StringName, group_id: int, weight: float = 1.0) -> void:
	var now: float = SimulationClock.get_sim_time()
	var cell: Dictionary = _touch(_cell_of(pos), now, true)
	var sp: StringName = StringName(species)
	var species_inf: Dictionary = cell["species"]
	species_inf[sp] = float(species_inf.get(sp, 0.0)) + weight
	if group_id != -1:
		var group_inf: Dictionary = cell["groups"]
		group_inf[group_id] = float(group_inf.get(group_id, 0.0)) + weight


## Suma influencia SOLO a la dimensión de GRUPO de la celda de `pos` (sin tocar la
## de especie). La usan las granjas: proyectan territorio de su grupo, no de una
## especie (la territorialidad es noción de grupo; ver `group_ownership_at`).
func deposit_group(pos: Vector3, group_id: int, weight: float) -> void:
	if group_id == -1 or weight <= 0.0:
		return
	var now: float = SimulationClock.get_sim_time()
	var cell: Dictionary = _touch(_cell_of(pos), now, true)
	var group_inf: Dictionary = cell["groups"]
	group_inf[group_id] = float(group_inf.get(group_id, 0.0)) + weight


## Proyecta dominancia de GRUPO en un radio (la llaman las granjas cada tick lento)
## para que una zona "siga siendo del grupo" aunque no haya unidades allí.
##
## El peso se AUTO-CALIBRA por equilibrio: una celda alimentada cada `dt` con
## decaimiento `f = 0.5^(dt/half_life)` se estabiliza en `w/(1-f)`. Para sostener
## una dominancia objetivo `target = dominance_full · strength · falloff`, se
## deposita `w = target · (1 - f)`. Así la dominancia mantenida no depende de la
## cadencia del tick. El `falloff` cae linealmente del centro (1.0) al borde (0.4).
func project_group_influence(center: Vector3, group_id: int, radius: float,
		strength: float, dt: float) -> void:
	if group_id == -1 or radius <= 0.0 or strength <= 0.0 or dt <= 0.0:
		return
	var half_life: float = maxf(GlobalParams.tuning.territory_half_life, 0.01)
	var f: float = pow(0.5, dt / half_life)
	var full: float = maxf(GlobalParams.tuning.territory_dominance_full, 0.001)
	var center_cell: Vector2i = _cell_of(center)
	var reach: int = int(ceil(radius / TERRITORY_CELL_SIZE))
	var r2: float = radius * radius
	for cx in range(center_cell.x - reach, center_cell.x + reach + 1):
		for cy in range(center_cell.y - reach, center_cell.y + reach + 1):
			# Centro mundial de la celda (XZ); la Y no influye en la rejilla.
			var wx: float = (float(cx) + 0.5) * TERRITORY_CELL_SIZE
			var wz: float = (float(cy) + 0.5) * TERRITORY_CELL_SIZE
			var d2: float = (wx - center.x) * (wx - center.x) + (wz - center.z) * (wz - center.z)
			if d2 > r2:
				continue
			var falloff: float = lerpf(1.0, 0.4, sqrt(d2) / radius)
			var w: float = full * strength * falloff * (1.0 - f)
			deposit_group(Vector3(wx, center.y, wz), group_id, w)


## Presión [0..1] que un ajeno siente en la celda de `pos`: combina la
## dominancia de especies distintas a la suya y la del grupo ajeno más fuerte
## (intimidación de un clan a los no-miembros, incluso de su misma especie).
func rival_pressure_at(pos: Vector3, species: StringName, group_id: int) -> float:
	var cell: Dictionary = _touch(_cell_of(pos), SimulationClock.get_sim_time(), false)
	if cell.is_empty():
		return 0.0
	var full: float = maxf(GlobalParams.tuning.territory_dominance_full, 0.001)
	# Especie: suma de la influencia de todas las especies ≠ la propia.
	var species_inf: Dictionary = cell["species"]
	var rival_sp: float = 0.0
	for sp in species_inf:
		if String(sp) != String(species):
			rival_sp += float(species_inf[sp])
	var s: float = clampf(rival_sp / full, 0.0, 1.0)
	# Grupo: el grupo ajeno con más presencia (el propio no intimida).
	var group_inf: Dictionary = cell["groups"]
	var foreign_grp: float = 0.0
	for gid in group_inf:
		if int(gid) != group_id:
			foreign_grp = maxf(foreign_grp, float(group_inf[gid]))
	var g: float = clampf(foreign_grp / full, 0.0, 1.0) \
		* GlobalParams.tuning.territory_group_intimidation
	# OR saturante: ambas fuentes empujan hacia 1 sin pasarse.
	return clampf(1.0 - (1.0 - s) * (1.0 - g), 0.0, 1.0)


## Cuánto [0..1] domina la entidad su celda (por especie o por grupo). Base de
## la ventaja de dueño: defender la propia zona da arrojo y quita miedo.
func ownership_at(pos: Vector3, species: StringName, group_id: int) -> float:
	var cell: Dictionary = _touch(_cell_of(pos), SimulationClock.get_sim_time(), false)
	if cell.is_empty():
		return 0.0
	var full: float = maxf(GlobalParams.tuning.territory_dominance_full, 0.001)
	var species_inf: Dictionary = cell["species"]
	var own_sp: float = clampf(float(species_inf.get(StringName(species), 0.0)) / full, 0.0, 1.0)
	var own_grp: float = 0.0
	if group_id != -1:
		own_grp = clampf(float((cell["groups"] as Dictionary).get(group_id, 0.0)) / full, 0.0, 1.0)
	return maxf(own_sp, own_grp)


## Dominancia [0..1] del PROPIO GRUPO en la celda de `pos` (sin la dimensión de
## especie). Base del ARRAIGO: cuánto "es mía" esta zona como miembro del grupo.
## La territorialidad es una noción de grupo (ver GDD → Territorialidad), así que
## un loner (group_id == -1) no tiene zona propia → 0.
func group_ownership_at(pos: Vector3, group_id: int) -> float:
	if group_id == -1:
		return 0.0
	var cell: Dictionary = _touch(_cell_of(pos), SimulationClock.get_sim_time(), false)
	if cell.is_empty():
		return 0.0
	var full: float = maxf(GlobalParams.tuning.territory_dominance_full, 0.001)
	return clampf(float((cell["groups"] as Dictionary).get(group_id, 0.0)) / full, 0.0, 1.0)


## Grupo con mayor influencia BRUTA en la celda de `pos` (-1 si no hay ninguno).
## Mismo criterio que el overlay (`get_overlay_cells`). Complementa a
## `group_ownership_at`, que recorta a 1.0 y no distingue quién manda cuando varios
## grupos solapados superan `territory_dominance_full`.
func dominant_group_at(pos: Vector3) -> int:
	var cell: Dictionary = _touch(_cell_of(pos), SimulationClock.get_sim_time(), false)
	if cell.is_empty():
		return -1
	var top_gid: int = -1
	var top_inf: float = 0.0
	for gid in cell["groups"]:
		var inf: float = float(cell["groups"][gid])
		if inf > top_inf:
			top_inf = inf
			top_gid = int(gid)
	return top_gid


## Para el overlay de visualización: una entrada por celda NO vacía, puesta al
## día por decaimiento. Cada entrada da la especie y el grupo dominantes de la
## celda con su fuerza [0..1] (normalizada por `territory_dominance_full`).
##   [{ "cell": Vector2i, "species": StringName, "species_strength": float,
##      "group": int, "group_strength": float }]
func get_overlay_cells() -> Array:
	var now: float = SimulationClock.get_sim_time()
	var full: float = maxf(GlobalParams.tuning.territory_dominance_full, 0.001)
	var out: Array = []
	# keys() devuelve una copia → seguro aunque `_touch` purgue celdas vacías.
	for cell_key in _cells.keys():
		var cell: Dictionary = _touch(cell_key, now, false)
		if cell.is_empty():
			continue
		var top_sp: StringName = &""
		var top_sp_inf: float = 0.0
		for sp in cell["species"]:
			var inf: float = float(cell["species"][sp])
			if inf > top_sp_inf:
				top_sp_inf = inf
				top_sp = sp
		var top_gid: int = -1
		var top_gid_inf: float = 0.0
		for gid in cell["groups"]:
			var inf: float = float(cell["groups"][gid])
			if inf > top_gid_inf:
				top_gid_inf = inf
				top_gid = int(gid)
		out.append({
			"cell": cell_key,
			"species": top_sp,
			"species_strength": clampf(top_sp_inf / full, 0.0, 1.0),
			"group": top_gid,
			"group_strength": clampf(top_gid_inf / full, 0.0, 1.0),
		})
	return out


## Resumen agregado del dominio territorial para el log (categoría `territory`),
## pensado para analizar comportamientos: reparto de territorio por especie, zonas
## en disputa (fronteras) y los grupos con más territorio. Lee el mapa puesto al
## día por decaimiento (mismo patrón seguro que `get_overlay_cells`: itera sobre
## una copia de las claves porque `_touch` puede purgar celdas vacías).
##   {
##     "occupied_cells": int, "cell_size": float, "contested_cells": int,
##     "species": { "A": {"cells": int, "influence": float, "strength_avg": float}, … },
##     "top_groups": [ {"group": int, "cells": int, "influence": float}, … ]  # hasta 5
##   }
## "cells" = nº de celdas donde la especie/grupo es dominante; "influence" = suma de
## su presencia en TODO el mapa; "strength_avg" = dominancia media [0..1] de las
## celdas que domina; "contested_cells" = celdas con ≥2 especies por encima de
## `CONTESTED_FRACTION × territory_dominance_full` (fronteras activas).
func snapshot_summary() -> Dictionary:
	var now: float = SimulationClock.get_sim_time()
	var full: float = maxf(GlobalParams.tuning.territory_dominance_full, 0.001)
	var relevant_min: float = full * CONTESTED_FRACTION
	var sp_cells: Dictionary = {}        # StringName -> nº celdas dominadas
	var sp_influence: Dictionary = {}    # StringName -> influencia total
	var sp_strength: Dictionary = {}     # StringName -> suma de dominancia [0..1]
	var grp_cells: Dictionary = {}       # int -> nº celdas dominadas
	var grp_influence: Dictionary = {}   # int -> influencia total
	var occupied: int = 0
	var contested: int = 0
	for cell_key in _cells.keys():
		var cell: Dictionary = _touch(cell_key, now, false)
		if cell.is_empty():
			continue
		occupied += 1
		# Especies: dominante de la celda + acumulados + recuento de disputa.
		var species_inf: Dictionary = cell["species"]
		var top_sp: StringName = &""
		var top_inf: float = 0.0
		var relevant: int = 0
		for sp in species_inf:
			var inf: float = float(species_inf[sp])
			sp_influence[sp] = float(sp_influence.get(sp, 0.0)) + inf
			if inf >= relevant_min:
				relevant += 1
			if inf > top_inf:
				top_inf = inf
				top_sp = sp
		if top_sp != &"":
			sp_cells[top_sp] = int(sp_cells.get(top_sp, 0)) + 1
			sp_strength[top_sp] = float(sp_strength.get(top_sp, 0.0)) + clampf(top_inf / full, 0.0, 1.0)
		if relevant >= 2:
			contested += 1
		# Grupos: dominante de la celda + influencia total.
		var group_inf: Dictionary = cell["groups"]
		var top_gid: int = -1
		var top_g: float = 0.0
		for gid in group_inf:
			var inf: float = float(group_inf[gid])
			grp_influence[gid] = float(grp_influence.get(gid, 0.0)) + inf
			if inf > top_g:
				top_g = inf
				top_gid = int(gid)
		if top_gid != -1:
			grp_cells[top_gid] = int(grp_cells.get(top_gid, 0)) + 1
	# Por especie.
	var species_out: Dictionary = {}
	for sp in sp_cells:
		var c: int = int(sp_cells[sp])
		species_out[String(sp)] = {
			"cells": c,
			"influence": float(sp_influence.get(sp, 0.0)),
			"strength_avg": (float(sp_strength[sp]) / float(c)) if c > 0 else 0.0,
		}
	# Grupos con más territorio (top 5 por celdas dominadas).
	var gids: Array = grp_cells.keys()
	gids.sort_custom(func(a, b): return int(grp_cells[a]) > int(grp_cells[b]))
	var top_groups: Array = []
	for i in mini(5, gids.size()):
		var gid: int = int(gids[i])
		top_groups.append({
			"group": gid,
			"cells": int(grp_cells[gid]),
			"influence": float(grp_influence.get(gid, 0.0)),
		})
	return {
		"occupied_cells": occupied,
		"cell_size": TERRITORY_CELL_SIZE,
		"contested_cells": contested,
		"species": species_out,
		"top_groups": top_groups,
	}


## Devuelve la celda puesta al día por decaimiento. Con `create`=true crea la
## celda si no existe (depósito); con false NO la crea y, si quedó vacía tras
## decaer, la purga y devuelve un diccionario vacío como "no hay nada aquí".
func _touch(cell_key: Vector2i, now: float, create: bool) -> Dictionary:
	var cell: Variant = _cells.get(cell_key)
	if cell == null:
		if not create:
			return {}
		var fresh: Dictionary = {"species": {}, "groups": {}, "last_t": now}
		_cells[cell_key] = fresh
		return fresh
	_decay(cell, now)
	if not create and (cell["species"] as Dictionary).is_empty() \
			and (cell["groups"] as Dictionary).is_empty():
		_cells.erase(cell_key)
		return {}
	return cell


func _decay(cell: Dictionary, now: float) -> void:
	var dt: float = now - float(cell["last_t"])
	if dt <= 0.0:
		return
	var half_life: float = maxf(GlobalParams.tuning.territory_half_life, 0.01)
	var factor: float = pow(0.5, dt / half_life)
	cell["last_t"] = now
	_decay_map(cell["species"], factor)
	_decay_map(cell["groups"], factor)


func _decay_map(m: Dictionary, factor: float) -> void:
	for k in m.keys():
		var v: float = float(m[k]) * factor
		if v < EPSILON:
			m.erase(k)
		else:
			m[k] = v


# ---------------- GUARDADO ----------------
# Ver `SaveGame`. Las claves de grupo de cada celda son ids de grupo, estables con el
# contador de `Groups`: van tal cual. `_plant_counts`/`_plant_total` NO se guardan: los
# reconstruye `Plant.activate` al restaurar cada planta.

func to_save() -> Dictionary:
	return {"cells": _cells.duplicate(true), "log_timer": _log_timer}


func from_save(d: Dictionary) -> void:
	_cells = Dictionary(d.get("cells", {})).duplicate(true)
	_log_timer = float(d.get("log_timer", 0.0))
