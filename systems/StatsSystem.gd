extends Node
## Sistema de estad\u00edsticas en vivo (autoload `Stats`).
##
## Mantiene contadores acumulados y series temporales de la simulaci\u00f3n
## para alimentar el StatsPanel del HUD. **No** sustituye al log JSONL:
## el log sigue siendo la fuente de verdad para an\u00e1lisis offline; este
## sistema es una capa de lectura para visualizaci\u00f3n en juego.
##
## Estrategia:
## - Escuchamos `EventLog.event_logged` para incrementar contadores de
##   nacimientos / muertes por causa.
## - Cada `SAMPLE_INTERVAL` segundos de simulaci\u00f3n tomamos un snapshot
##   de poblaci\u00f3n / plantas / generaci\u00f3n y lo metemos en un buffer
##   circular de `HISTORY_SIZE` muestras.
## - Emitimos `sample_taken` para que la UI se redibuje sin polling.

signal sample_taken

const SAMPLE_INTERVAL: float = 1.0
const HISTORY_SIZE: int = 300  # 5 min @ 1 muestra/s

var pop_A: int = 0
var pop_B: int = 0
var plants_count: int = 0
var max_generation: int = 1

var total_births: int = 0
var total_deaths: int = 0
var deaths_by_cause: Dictionary = {}     # StringName -> int
var deaths_by_species: Dictionary = {}   # StringName -> int
var births_by_species: Dictionary = {}   # StringName -> int

var history_pop_A: Array[int] = []
var history_pop_B: Array[int] = []
var history_plants: Array[int] = []
var history_t_sim: Array[float] = []

var _sample_timer: float = 0.0


func _ready() -> void:
	EventLog.event_logged.connect(_on_event_logged)
	SimulationClock.tick.connect(_on_tick)


func _on_event_logged(event: Dictionary) -> void:
	var kind: String = event.get("kind", "")
	var data: Dictionary = event.get("data", {})
	match kind:
		"birth":
			total_births += 1
			var sp_b: StringName = _species_from_category(event.get("category", ""))
			births_by_species[sp_b] = int(births_by_species.get(sp_b, 0)) + 1
		"death":
			total_deaths += 1
			var cause: StringName = StringName(str(data.get("cause", "unknown")))
			deaths_by_cause[cause] = int(deaths_by_cause.get(cause, 0)) + 1
			var sp_d: StringName = _species_from_category(event.get("category", ""))
			deaths_by_species[sp_d] = int(deaths_by_species.get(sp_d, 0)) + 1


static func _species_from_category(category: String) -> StringName:
	# "sphere_A" -> &"A"
	if category.begins_with("sphere_"):
		return StringName(category.substr(7))
	return &"?"


func _on_tick(dt_sim: float) -> void:
	_sample_timer += dt_sim
	if _sample_timer < SAMPLE_INTERVAL:
		return
	_sample_timer = 0.0
	_take_sample()


func _take_sample() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var spheres: Array = tree.get_nodes_in_group(&"spheres")
	pop_A = 0
	pop_B = 0
	max_generation = 1
	for s in spheres:
		if not (s is Sphere):
			continue
		var sp: StringName = s.genome.get("species", &"?")
		if sp == &"A":
			pop_A += 1
		elif sp == &"B":
			pop_B += 1
		if s.generation > max_generation:
			max_generation = s.generation
	plants_count = tree.get_nodes_in_group(&"plants").size()

	history_pop_A.append(pop_A)
	history_pop_B.append(pop_B)
	history_plants.append(plants_count)
	history_t_sim.append(SimulationClock.get_sim_time() if SimulationClock.has_method("get_sim_time") else 0.0)
	if history_pop_A.size() > HISTORY_SIZE:
		history_pop_A.pop_front()
		history_pop_B.pop_front()
		history_plants.pop_front()
		history_t_sim.pop_front()

	sample_taken.emit()


func reset() -> void:
	pop_A = 0
	pop_B = 0
	plants_count = 0
	max_generation = 1
	total_births = 0
	total_deaths = 0
	deaths_by_cause.clear()
	deaths_by_species.clear()
	births_by_species.clear()
	history_pop_A.clear()
	history_pop_B.clear()
	history_plants.clear()
	history_t_sim.clear()
	_sample_timer = 0.0
	sample_taken.emit()


# ---------------- GUARDADO ----------------
# Ver `SaveGame`. Se restaura el ÚLTIMO: cada `activate()` de la carga loguea un
# `spawn`, y si este sistema reaccionase a ellos (o a futuros eventos) contaminarían
# los contadores; restaurar al final los deja exactamente como se guardaron.

func to_save() -> Dictionary:
	return {
		"pop_A": pop_A,
		"pop_B": pop_B,
		"plants_count": plants_count,
		"max_generation": max_generation,
		"total_births": total_births,
		"total_deaths": total_deaths,
		"deaths_by_cause": deaths_by_cause.duplicate(),
		"deaths_by_species": deaths_by_species.duplicate(),
		"births_by_species": births_by_species.duplicate(),
		"history_pop_A": history_pop_A.duplicate(),
		"history_pop_B": history_pop_B.duplicate(),
		"history_plants": history_plants.duplicate(),
		"history_t_sim": history_t_sim.duplicate(),
		"sample_timer": _sample_timer,
	}


func from_save(d: Dictionary) -> void:
	pop_A = int(d.get("pop_A", 0))
	pop_B = int(d.get("pop_B", 0))
	plants_count = int(d.get("plants_count", 0))
	max_generation = int(d.get("max_generation", 1))
	total_births = int(d.get("total_births", 0))
	total_deaths = int(d.get("total_deaths", 0))
	deaths_by_cause = Dictionary(d.get("deaths_by_cause", {})).duplicate()
	deaths_by_species = Dictionary(d.get("deaths_by_species", {})).duplicate()
	births_by_species = Dictionary(d.get("births_by_species", {})).duplicate()
	# `assign` y no `=`: las historias son arrays tipados.
	history_pop_A.assign(d.get("history_pop_A", []))
	history_pop_B.assign(d.get("history_pop_B", []))
	history_plants.assign(d.get("history_plants", []))
	history_t_sim.assign(d.get("history_t_sim", []))
	_sample_timer = float(d.get("sample_timer", 0.0))
	sample_taken.emit()
