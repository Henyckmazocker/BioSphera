extends Node
## Ciclo natural: día/noche + estaciones + año.
##
## Autoload `Climate`. No editable directamente por el jugador (solo
## acelerable subiendo la velocidad del `SimulationClock`).
##
## - Día: `GlobalParams.tuning.seconds_per_day` (def. 150 s sim).
## - Estación: `GlobalParams.tuning.days_per_season` días (def. 20).
## - Año: 4 estaciones (constante estructural).
##
## Emite señales para que el resto del juego pueda reaccionar y para que
## un nodo de luz (sol) pueda orbitar según `day_progress`.
##
## Ver docs: docs/GDD/Mundo y Niveles.md.

signal day_advanced(day_progress: float)  ## 0..1 dentro del día
signal day_rolled(day_index: int)
signal season_changed(season: int)        ## 0=primavera 1=verano 2=otoño 3=invierno
signal year_rolled(year: int)

# Cadencia (día/estación) configurable en vivo: ver `GlobalParams.tuning`
# (seconds_per_day, days_per_season). El año = 4 estaciones es estructural.
const SEASONS_PER_YEAR: int = 4

const SEASON_NAMES: Array[String] = ["Primavera", "Verano", "Otoño", "Invierno"]

var sim_time: float = 0.0
var day_progress: float = 0.0
var day_index: int = 0
var season_index: int = 0
var year: int = 0

# La estación inicial (Primavera/año 0) se registra en el primer tick, no al
# cambiar: así `world.jsonl` no arranca vacío y el análisis ve el punto de partida.
var _initial_logged: bool = false


func _ready() -> void:
	SimulationClock.tick.connect(_on_tick)


func current_season_name() -> String:
	return SEASON_NAMES[season_index]


## Multiplicador de productividad vegetal según estación.
## Primavera y verano favorecen plantas; otoño/invierno la penalizan.
func plant_growth_modifier() -> float:
	match season_index:
		0: return 1.2  # primavera
		1: return 1.4  # verano
		2: return 0.8  # otoño
		_: return 0.5  # invierno


func is_night() -> bool:
	return day_progress < 0.25 or day_progress > 0.75


func _on_tick(dt_sim: float) -> void:
	sim_time += dt_sim
	var prev_day: int = day_index
	var prev_season: int = season_index
	var prev_year: int = year

	var seconds_per_day: float = GlobalParams.tuning.seconds_per_day
	var days_per_season: int = GlobalParams.tuning.days_per_season
	day_progress = fmod(sim_time, seconds_per_day) / seconds_per_day
	day_index = int(sim_time / seconds_per_day)
	season_index = (day_index / days_per_season) % SEASONS_PER_YEAR
	year = day_index / (days_per_season * SEASONS_PER_YEAR)

	if not _initial_logged:
		_initial_logged = true
		season_changed.emit(season_index)
		EventLog.log_event(&"season", {"season": current_season_name(), "year": year})

	day_advanced.emit(day_progress)
	if day_index != prev_day:
		day_rolled.emit(day_index)
	if season_index != prev_season:
		season_changed.emit(season_index)
		EventLog.log_event(&"season", {"season": current_season_name(), "year": year})
	if year != prev_year:
		year_rolled.emit(year)
