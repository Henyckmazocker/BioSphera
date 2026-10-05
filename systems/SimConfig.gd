extends Node
## Configuración de simulación fijada antes de arrancar.
##
## Autoload `SimConfig`. La pantalla de inicio (`StartScreen`) escribe estos
## valores y `World` / `Spawner` los leen una sola vez al construir el mundo.
## A diferencia de `GlobalParams` (ajustable en vivo durante la partida), estos
## parámetros solo tienen efecto al generar el mundo: cambiarlos después no
## redimensiona el terreno ni reubica entidades.

const WORLD_SIZE_DEFAULT: float = 160.0
# Densidad escalada al mapa de 160 u (~7× el área de 60): conteos sublineales (~×2.5)
# para que el mundo grande quede poblado pero rentable. La POBLACIÓN no escala (ver
# POPULATION_PER_SPECIES_DEFAULT): el tope de 100 esferas es el objetivo de rendimiento.
const INITIAL_PLANTS_DEFAULT: int = 500
const POPULATION_PER_SPECIES_DEFAULT: int = 50
const MIN_PLANT_SEEDS_DEFAULT: int = 100
const INITIAL_TRAIT_MEAN_DEFAULT: float = 0.5
# Yacimientos iniciales de los recursos de economía (madera/piedra/oro). La madera
# se mantiene con respawn de rescate (renovable); piedra y oro son finitos.
const INITIAL_WOOD_DEFAULT: int = 160
const INITIAL_STONE_DEFAULT: int = 160
const INITIAL_GOLD_DEFAULT: int = 75
# Mínimos que el rescate lento de recursos mantiene en el mundo (piedra/oro finitos
# regeneran despacio hasta estos topes para que la economía no se extinga).
const MIN_STONE_DEFAULT: int = 75
const MIN_GOLD_DEFAULT: int = 30

## Rasgos de comportamiento configurables al arrancar (espejo de
## `Traits.BEHAVIOR_KEYS`). La pantalla de inicio expone una media por cada uno.
const BEHAVIOR_TRAITS: Array[StringName] = [
	&"aggression", &"sociability", &"loyalty", &"bravery",
	&"reproductive_appetite", &"selectivity", &"territoriality",
]

# Lado del plano cuadrado, en unidades de mundo.
var world_size: float = WORLD_SIZE_DEFAULT
# Plantas sembradas al arrancar la simulación.
var initial_plants: int = INITIAL_PLANTS_DEFAULT
# Esferas iniciales de cada especie (A y B).
var initial_population_per_species: int = POPULATION_PER_SPECIES_DEFAULT
# Plantas mínimas que el Spawner mantiene vivas mediante respawn de rescate.
var min_plant_seeds: int = MIN_PLANT_SEEDS_DEFAULT
# Nodos iniciales de cada recurso de economía (ver constantes *_DEFAULT).
var initial_wood: int = INITIAL_WOOD_DEFAULT
var initial_stone: int = INITIAL_STONE_DEFAULT
var initial_gold: int = INITIAL_GOLD_DEFAULT
# Mínimos que mantiene el rescate lento de piedra/oro (regeneración).
var min_stone: int = MIN_STONE_DEFAULT
var min_gold: int = MIN_GOLD_DEFAULT
# Media de cada rasgo de comportamiento al spawnear la población inicial, AHORA
# POR ESPECIE: la pantalla de inicio permite fijar medias distintas para cada
# especie (A, B…), de modo que el jugador pueda SEMBRAR diferencias de partida.
# Por defecto todas las especies arrancan iguales → divergencia emergente; si el
# jugador las cambia, la divergencia inicial es deliberada. Lo lee
# `Traits.random_genome(rng, species)` vía `get_trait_means(species)`.
# Estructura: { species(StringName) -> { trait(StringName) -> media(float) } }.
# Se rellena de forma perezosa por especie en `get_trait_means`.
var initial_trait_means: Dictionary = {}

# --- Configuración derivada de presets (ver SimPreset / apply_preset) ---
# Semilla del mapa de biomas: -1 = aleatoria; >=0 = reproducible. La lee Spawner.
var biome_seed: int = -1
# Layout de spawn. spawn_split: A en la mitad -X, B en la +X ("Dos tribus").
var spawn_split: bool = false
# Individuo gigante adicional ("Depredador apex").
var apex_enabled: bool = false
var apex_size: float = 3.0
var apex_species: StringName = &"A"
# Cap de tamaño para el resto de la población (Traits.SIZE_MAX = 3.0 = sin cap).
var population_size_max: float = 3.0

# Overrides de GlobalParams que el preset aplica al arrancar (defaults = los de
# GlobalParams, de modo que sin preset / "Personalizado" no cambian nada).
var food_respawn_per_second: float = 8.0
var target_food: int = 200
var mutation_base_rate: float = 0.06
var lifespan_multiplier: float = 1.0

# Eventos del entorno aleatorios (ver `SimPreset` y la tirada diaria de `Climate`).
# El ritmo es override de `GlobalParams.random_events_per_year` (parámetro vivo); el
# pool va como rutas de `.tres` (el save es texto `var_to_str`, no lleva recursos) y
# `Climate` lo carga una vez por partida. Sin preset («Personalizado»): 0 y vacío.
var random_events_per_year: float = 0.0
var random_event_pool_paths: PackedStringArray = PackedStringArray()
var random_intensity_range: Vector2 = Vector2(0.3, 0.7)

# Nombre del escenario con que se arrancó (`display_name` del preset, o
# "Personalizado"). Lo fija `StartScreen._on_start_pressed`; viaja en la sección
# `config` del save para que una partida cargada mande el mismo `preset` a Analytics.
var preset_name: String = ""

# Autoguardado de `World` (Timer y cierre de ventana). Las mediciones
# (`tools/measure_run.gd`) lo apagan: simulan el cierre y, en paralelo, pisarían el
# `auto.sav` del jugador y compartirían su `.tmp`. No viaja en el save.
var autosave_enabled: bool = true

# Partida a cargar (ver `SaveGame`): el diccionario leído con `SaveGame.read`, o vacío
# para una partida nueva. Lo rellena quien arranca la carga ANTES de cambiar a la
# escena del mundo, y lo consume (y vacía) `Spawner._on_terrain_ready`, que restaura
# el save en lugar de spawnear la población inicial. No se guarda nunca.
var pending_save: Dictionary = {}

## Vuelca un preset de ESCENARIO a esta configuración. Los campos con slider en la
## pantalla de inicio (world_size, plantas, población, comida mínima) los escribe
## igualmente StartScreen desde sus sliders; aquí se copian los EXTRAS no expuestos
## en sliders (semilla, layout, overrides de GlobalParams). Los rasgos por especie
## NO viven aquí: son presets de especie (ver SpeciesPreset). Llamar antes de
## `change_scene_to_file`.
func apply_preset(preset: SimPreset) -> void:
	world_size = preset.world_size
	initial_plants = preset.initial_plants
	initial_population_per_species = preset.initial_population_per_species
	min_plant_seeds = preset.min_plant_seeds
	biome_seed = preset.biome_seed
	spawn_split = preset.spawn_split
	apex_enabled = preset.apex_enabled
	apex_size = preset.apex_size
	apex_species = preset.apex_species
	population_size_max = preset.population_size_max
	food_respawn_per_second = preset.food_respawn_per_second
	target_food = preset.target_food
	mutation_base_rate = preset.mutation_base_rate
	lifespan_multiplier = preset.lifespan_multiplier
	random_events_per_year = preset.random_events_per_year
	random_event_pool_paths = PackedStringArray()
	for ev in preset.random_event_pool:
		if ev != null:
			random_event_pool_paths.append(ev.resource_path)
	random_intensity_range = preset.random_intensity_range


## Empuja los overrides del preset a GlobalParams (parámetros vivos). Idempotente:
## con los valores por defecto no cambia nada. Llamar al iniciar la simulación.
func apply_to_global_params() -> void:
	GlobalParams.set_param(&"food_respawn_per_second", food_respawn_per_second)
	GlobalParams.set_param(&"target_food", float(target_food))
	GlobalParams.set_param(&"mutation_base_rate", mutation_base_rate)
	GlobalParams.set_param(&"lifespan_multiplier", lifespan_multiplier)
	GlobalParams.set_param(&"random_events_per_year", random_events_per_year)


## Medias de rasgos de una especie (sub-dict trait→media). Si la especie aún no
## está inicializada, crea su entrada con el default para todos los rasgos. Así
## no depende del orden de los autoloads (no necesita `GlobalParams` al arrancar).
func get_trait_means(species) -> Dictionary:
	var s: StringName = StringName(String(species))
	if not initial_trait_means.has(s):
		var means: Dictionary = {}
		for t in BEHAVIOR_TRAITS:
			means[t] = INITIAL_TRAIT_MEAN_DEFAULT
		initial_trait_means[s] = means
	return initial_trait_means[s]


## Fija la media de un rasgo para una especie (lo usa la pantalla de inicio).
func set_trait_mean(species, trait_key: StringName, value: float) -> void:
	get_trait_means(species)[trait_key] = value
