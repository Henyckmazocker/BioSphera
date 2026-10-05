extends Node
## Parámetros globales editables en tiempo real por el jugador.
##
## Autoload `GlobalParams`. Sliders del panel de parámetros y modificadores
## globales que afectan a toda la simulación. Cualquier sistema lee de aquí
## en lugar de hardcodear valores.
##
## Ver docs: docs/GDD/UI - UX.md (sección "Panel global / parámetros")
## y docs/GDD/Mecánicas.md (sección "Modelo de mutación").

signal changed(key: StringName, value: float)

## Constantes de comportamiento centralizadas. Fuente única de tuning;
## cualquier sistema lee de `GlobalParams.tuning.<campo>`. Ver SimTuning.
var tuning: SimTuning = preload("res://data/sim_tuning.tres")

# Mutación
var mutation_base_rate: float = 0.06     # σ base sobre rasgos normalizados [0..1]
var mutation_stress_factor: float = 0.6
var mutation_inbreeding_factor: float = 0.5
var mutation_age_factor: float = 0.4
# Factores ambientales: pesan la presión climática (Climate.mutation_pressure, 0..1)
# y la hostilidad del bioma de nacimiento ("mutation_mod" de BIOME_EFFECTS, 0..1).
var mutation_climate_factor: float = 0.4
var mutation_biome_factor: float = 0.5

# Modificadores globales de comportamiento (multiplicadores)
var aggression_modifier: float = 1.0
var sociability_modifier: float = 1.0
var reproductive_appetite_modifier: float = 1.0
var territoriality_modifier: float = 1.0

# Mundo
var food_respawn_per_second: float = 8.0
var target_food: int = 200

# Reglas sociales
var social_memory_capacity: int = 12
var lifespan_multiplier: float = 1.0

# Eventos del entorno: media de eventos aleatorios por año (0 = ninguno). La fija el
# preset (`SimConfig.apply_to_global_params`) y la cambia en vivo el panel de eventos.
# Qué eventos y con qué intensidad lo decide el preset (`SimConfig.random_event_pool_paths`).
var random_events_per_year: float = 0.0

# Modo experimentación (god mode)
var experimentation_mode: bool = false

# ---------------- MODIFICADORES POR ESPECIE ----------------
# Multiplicadores que se combinan con los globales. 1.0 = neutro.
# Claves soportadas: metabolism, aggression, sociability, reproductive_appetite, lifespan.
const SPECIES_KEYS: Array[StringName] = [&"A", &"B"]
const SPECIES_MOD_KEYS: Array[StringName] = [
	&"metabolism", &"aggression", &"sociability", &"reproductive_appetite", &"lifespan", &"territoriality",
]
## Etiquetas de UI por modificador (fuente única para StartScreen y SpeciesPanel).
const SPECIES_MOD_LABELS: Dictionary = {
	&"metabolism": "Metabolismo",
	&"aggression": "Agresividad",
	&"sociability": "Sociabilidad",
	&"reproductive_appetite": "Apetito repro",
	&"lifespan": "Longevidad",
	&"territoriality": "Territorialidad",
}
# Se rellena de forma perezosa por especie (entrada neutra con todas las claves a
# 1.0) en `_ensure_species`. No hay valores por especie hardcodeados: las
# diferencias se siembran desde presets / sliders del menú inicial y se editan en
# vivo desde `SpeciesPanel`.
var species_modifiers: Dictionary = {}

signal species_changed(species: StringName, key: StringName, value: float)


## Crea la entrada neutra (todas las claves a 1.0) de una especie si no existe.
func _ensure_species(s: StringName) -> void:
	if species_modifiers.has(s):
		return
	var mods: Dictionary = {}
	for k in SPECIES_MOD_KEYS:
		mods[k] = 1.0
	species_modifiers[s] = mods


func get_species_mod(species, key: StringName) -> float:
	var s: StringName = StringName(String(species))
	_ensure_species(s)
	return float(species_modifiers[s].get(key, 1.0))


func set_species_mod(species: StringName, key: StringName, value: float) -> void:
	var s: StringName = StringName(String(species))
	_ensure_species(s)
	species_modifiers[s][key] = value
	species_changed.emit(s, key, value)


func set_param(key: StringName, value: float) -> void:
	match key:
		&"mutation_base_rate": mutation_base_rate = value
		&"aggression_modifier": aggression_modifier = value
		&"sociability_modifier": sociability_modifier = value
		&"reproductive_appetite_modifier": reproductive_appetite_modifier = value
		&"territoriality_modifier": territoriality_modifier = value
		&"food_respawn_per_second": food_respawn_per_second = value
		&"target_food": target_food = int(value)
		&"social_memory_capacity": social_memory_capacity = int(value)
		&"lifespan_multiplier": lifespan_multiplier = value
		&"random_events_per_year": random_events_per_year = value
		_: return
	changed.emit(key, value)
