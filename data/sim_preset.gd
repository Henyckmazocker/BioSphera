class_name SimPreset
extends Resource
## Escenario de partida: configuración inicial con la que el jugador arranca una
## simulación sin partir de cero.
##
## La pantalla de inicio (`StartScreen`) ofrece un selector de presets; al elegir
## uno, sus valores rellenan los sliders (editables) y, al iniciar, se vuelcan a
## `SimConfig` (ver `SimConfig.apply_preset`). Mismo patrón de Resource que
## `SimTuning`: editable en el inspector, tipado, sin parsear JSON.
##
## Ver docs: docs/GDD/Mundo y Niveles.md (sección "Escenarios (presets)").

# --- Metadatos ---
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

# --- Mundo y spawn (espejo de SimConfig) ---
@export var world_size: float = 160.0
@export var initial_plants: int = 500
@export var initial_population_per_species: int = 50
@export var min_plant_seeds: int = 100
## Semilla del mapa de biomas. -1 = aleatoria cada arranque; >=0 = reproducible.
@export var biome_seed: int = -1

# Nota: los rasgos por especie (medias de conducta y modificadores ×) NO viven en
# el escenario; son presets de especie independientes (ver SpeciesPreset y el
# desplegable por especie de StartScreen). El escenario solo define mundo/spawn.

# --- Overrides de GlobalParams (defaults = los de GlobalParams → "Personalizado" no cambia nada) ---
@export var food_respawn_per_second: float = 8.0
@export var target_food: int = 200
@export var mutation_base_rate: float = 0.06
@export var lifespan_multiplier: float = 1.0

# --- Layout de spawn ---
## Dos tribus: especie A en la mitad -X del mundo, especie B en la mitad +X.
@export var spawn_split: bool = false
## Depredador apex: spawnea un individuo gigante adicional.
@export var apex_enabled: bool = false
@export var apex_size: float = 3.0
@export var apex_species: StringName = &"A"
## Cap de tamaño para el resto de la población (Traits.SIZE_MAX = 3.0 = sin cap).
@export var population_size_max: float = 3.0
