extends Node
## Sistema de herencia + mutación (autoload `Genetics`).
##
## Cruce sexual de dos progenitores: cría = media + ruido gaussiano por rasgo.
## La tasa de mutación efectiva se modula por estrés, edad, endogamia y
## volatilidad intrínseca del rasgo. La tasa base la controla el jugador
## desde `GlobalParams.mutation_base_rate`.
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Modelo de mutación").

const TraitsScript: GDScript = preload("res://data/traits.gd")

var _rng: RandomNumberGenerator


func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.randomize()


func cross(parent_a: Dictionary, parent_b: Dictionary,
		stress_avg: float = 0.0, age_factor: float = 0.0) -> Dictionary:
	var child: Dictionary = {}
	var sigma: float = _effective_sigma(parent_a, parent_b, stress_avg, age_factor)

	child["species"] = parent_a.get("species", parent_b.get("species", &""))
	child["size"] = _mix_clamped(parent_a, parent_b, "size", sigma * (TraitsScript.SIZE_MAX - TraitsScript.SIZE_MIN), TraitsScript.SIZE_MIN, TraitsScript.SIZE_MAX)
	child["speed"] = _mix_clamped(parent_a, parent_b, "speed", sigma * (TraitsScript.SPEED_MAX - TraitsScript.SPEED_MIN), TraitsScript.SPEED_MIN, TraitsScript.SPEED_MAX)
	child["vision"] = _mix_clamped(parent_a, parent_b, "vision", sigma * (TraitsScript.VISION_MAX - TraitsScript.VISION_MIN), TraitsScript.VISION_MIN, TraitsScript.VISION_MAX)
	child["metabolism"] = _mix_clamped(parent_a, parent_b, "metabolism", sigma * (TraitsScript.METABOLISM_MAX - TraitsScript.METABOLISM_MIN), TraitsScript.METABOLISM_MIN, TraitsScript.METABOLISM_MAX)
	child["longevity"] = _mix_clamped(parent_a, parent_b, "longevity", sigma * (TraitsScript.LONGEVITY_MAX - TraitsScript.LONGEVITY_MIN), TraitsScript.LONGEVITY_MIN, TraitsScript.LONGEVITY_MAX)
	for key in TraitsScript.BEHAVIOR_KEYS:
		child[String(key)] = clampf(_mix(parent_a, parent_b, String(key)) + _rng.randfn(0.0, sigma * 0.5), 0.0, 1.0)
	child["color"] = _mix_color(parent_a.get("color", Color.WHITE), parent_b.get("color", Color.WHITE), sigma)
	# Apellido heredado del primer progenitor (convención provisional).
	child["lineage"] = parent_a.get("lineage", parent_b.get("lineage", "Unk"))
	return child


func _mix(a: Dictionary, b: Dictionary, key: String) -> float:
	var va: float = float(a.get(key, 0.0))
	var vb: float = float(b.get(key, 0.0))
	return (va + vb) * 0.5


func _mix_clamped(a: Dictionary, b: Dictionary, key: String, sigma: float, lo: float, hi: float) -> float:
	return clampf(_mix(a, b, key) + _rng.randfn(0.0, sigma), lo, hi)


func _mix_color(a: Color, b: Color, sigma: float) -> Color:
	var mixed: Color = a.lerp(b, 0.5)
	# Ruido HSV.
	var h: float = wrapf(mixed.h + _rng.randfn(0.0, sigma * 0.5), 0.0, 1.0)
	var s: float = clampf(mixed.s + _rng.randfn(0.0, sigma * 0.2), 0.2, 0.9)
	var v: float = clampf(mixed.v + _rng.randfn(0.0, sigma * 0.2), 0.5, 1.0)
	return Color.from_hsv(h, s, v)


func _effective_sigma(a: Dictionary, b: Dictionary,
		stress_avg: float, age_factor: float) -> float:
	var base: float = GlobalParams.mutation_base_rate
	var stress_mod: float = GlobalParams.mutation_stress_factor * clampf(stress_avg / 100.0, 0.0, 1.0)
	var age_mod: float = GlobalParams.mutation_age_factor * clampf(age_factor, 0.0, 1.0)
	var inbreeding: float = _genetic_distance(a, b)
	# Endogamia ALTA = distancia BAJA → mutación SUBE.
	var inbreeding_mod: float = GlobalParams.mutation_inbreeding_factor * (1.0 - clampf(inbreeding, 0.0, 1.0))
	return clampf(base * (1.0 + stress_mod + age_mod + inbreeding_mod), 0.0, 1.0)


func _genetic_distance(a: Dictionary, b: Dictionary) -> float:
	# Distancia normalizada [0..1] entre dos genomas sobre los rasgos clave.
	var keys: Array[String] = ["size", "speed", "vision", "metabolism"]
	var total: float = 0.0
	for k in keys:
		var va: float = float(a.get(k, 0.0))
		var vb: float = float(b.get(k, 0.0))
		var range_size: float = 1.0
		match k:
			"size": range_size = TraitsScript.SIZE_MAX - TraitsScript.SIZE_MIN
			"speed": range_size = TraitsScript.SPEED_MAX - TraitsScript.SPEED_MIN
			"vision": range_size = TraitsScript.VISION_MAX - TraitsScript.VISION_MIN
			"metabolism": range_size = TraitsScript.METABOLISM_MAX - TraitsScript.METABOLISM_MIN
		total += absf(va - vb) / range_size
	return total / float(keys.size())
