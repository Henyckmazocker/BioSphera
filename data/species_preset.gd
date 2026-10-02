class_name SpeciesPreset
extends Resource
## Arquetipo de especie: medias de rasgos de comportamiento + modificadores ×.
##
## Igual que `SimPreset` describe un escenario de mundo, `SpeciesPreset` describe
## el "carácter" de una especie. La pantalla de inicio (`StartScreen`) ofrece un
## desplegable por especie; al elegir un arquetipo, sus valores rellenan los
## sliders de esa especie (editables), y al iniciar lo que esté en los sliders es
## lo que manda (medias → SimConfig, modificadores → GlobalParams).
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Rasgos de una esfera").

# --- Metadatos ---
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

# --- Medias de rasgos de comportamiento (trait -> media [0..1]) ---
## Vacío = default 0.5 para todos. Claves = SimConfig.BEHAVIOR_TRAITS.
@export var trait_means: Dictionary = {}

# --- Modificadores por especie (clave -> multiplicador ×) ---
## Vacío = neutro 1.0 para todos. Claves = GlobalParams.SPECIES_MOD_KEYS.
@export var species_mods: Dictionary = {}
