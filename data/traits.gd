class_name Traits
extends RefCounted
## Definición de rasgos heredables de una esfera.
##
## Rasgos físicos (continuos) + rasgos de comportamiento normalizados [0..1].
## Toda mutación se hace sobre estos rangos (ver `GeneticsSystem`).
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Rasgos de una esfera").

const SIZE_MIN: float = 0.5
const SIZE_MAX: float = 3.0

const SPEED_MIN: float = 1.0
const SPEED_MAX: float = 6.0

const VISION_MIN: float = 3.0
const VISION_MAX: float = 12.0

const METABOLISM_MIN: float = 0.5
const METABOLISM_MAX: float = 2.0

const LONGEVITY_MIN: float = 60.0   # segundos de simulación
const LONGEVITY_MAX: float = 240.0

# Rangos para rasgos de comportamiento (todos normalizados 0..1).
const BEHAVIOR_KEYS: Array[StringName] = [
	&"aggression",
	&"sociability",
	&"loyalty",
	&"bravery",
	&"reproductive_appetite",
	&"selectivity",
	&"territoriality",
	# Laboriosidad/codicia: empuje a recolectar recursos de economía (madera/piedra/
	# oro) cuando no apremia el hambre. Modula la utilidad de la acción GATHER.
	&"industriousness",
]

# Diferenciación de las dos especies iniciales:
# - forma distinta (A = esfera, B = pirámide triangular).
# El color depende de la familia (lineage), no de la especie, de modo que
# las mezclas entre familias se vean en el color de la cría.
# Los rasgos de comportamiento parten de las medias POR ESPECIE configuradas
# en la pantalla de inicio (SimConfig.get_trait_means). Por defecto iguales para
# todas → divergencia emergente; el jugador puede sembrar diferencias de partida.


static func lineage_hue(surname: String) -> float:
	## Tono base estable por apellido. Mismo apellido → mismo tono.
	var h: int = hash(surname)
	return float(h & 0xFFFF) / 65535.0


static func color_from_lineage(rng: RandomNumberGenerator, surname: String) -> Color:
	var base_h: float = lineage_hue(surname)
	# Pequeña variación individual alrededor del tono familiar.
	var h: float = wrapf(base_h + rng.randfn(0.0, 0.025), 0.0, 1.0)
	var s: float = clampf(rng.randf_range(0.55, 0.85), 0.0, 1.0)
	var v: float = clampf(rng.randf_range(0.75, 1.0), 0.0, 1.0)
	return Color.from_hsv(h, s, v)


static func random_genome(rng: RandomNumberGenerator, species: StringName = &"") -> Dictionary:
	var surname: String = _random_surname(rng)
	var genome: Dictionary = {
		"species": species,
		"size": rng.randf_range(SIZE_MIN, SIZE_MAX),
		"color": color_from_lineage(rng, surname),
		"speed": rng.randf_range(SPEED_MIN, SPEED_MAX),
		"vision": rng.randf_range(VISION_MIN, VISION_MAX),
		"metabolism": rng.randf_range(METABOLISM_MIN, METABOLISM_MAX),
		"longevity": rng.randf_range(LONGEVITY_MIN, LONGEVITY_MAX),
		"lineage": surname,
	}
	# Media por rasgo configurable POR ESPECIE desde la pantalla de inicio
	# (SimConfig). Por defecto iguales para todas las especies → divergencia
	# emergente; el jugador puede sembrar diferencias de partida por especie.
	var trait_means: Dictionary = SimConfig.get_trait_means(species)
	for key in BEHAVIOR_KEYS:
		var mean: float = float(trait_means.get(key, 0.5))
		genome[String(key)] = clampf(rng.randfn(mean, 0.18), 0.0, 1.0)
	return genome


static func _random_surname(rng: RandomNumberGenerator) -> String:
	# Pool provisional - el estilo definitivo está aplazado en docs/GDD/Personajes.md.
	const POOL: PackedStringArray = [
		"Aldo", "Bren", "Cyra", "Dyl", "Eda", "Fenn", "Gor", "Hila",
		"Iro", "Jara", "Kelt", "Lun", "Myr", "Nox", "Ory", "Pell",
		"Quor", "Rin", "Sal", "Tav", "Uli", "Ven", "Wex", "Yor", "Zan",
	]
	return POOL[rng.randi() % POOL.size()]


static func random_given_name(rng: RandomNumberGenerator) -> String:
	const POOL: PackedStringArray = [
		"Ada", "Bo", "Cy", "Di", "Em", "Fa", "Gi", "Ha", "Ily", "Ju",
		"Ka", "Li", "Mo", "Ni", "Oz", "Pa", "Qi", "Ro", "Si", "Tu",
		"Uv", "Vi", "Wo", "Xi", "Yu", "Za",
	]
	return POOL[rng.randi() % POOL.size()]
