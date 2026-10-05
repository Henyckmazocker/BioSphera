class_name Plague
extends RefCounted
## Reglas de la plaga (evento del entorno, modelo SIR): debilidad, pacientes cero y
## contagio. Solo funciones estáticas, sin estado: el estado de cada infección vive
## en `Sphere` (`_plague_*`) y la ventana de contagio y la cepa, en `Climate`
## (`plague_strength()`, `plague_strain()`). No es autoload.
##
## Ver docs: docs/GDD/Mecánicas.md (eventos del entorno) · plan «Eventos del Entorno».


## Debilidad 0..1 de `s` frente a la plaga: elige a los pacientes cero y pondera el
## contagio y el daño. Mezcla la vitalidad del momento (salud × energía) con la
## genética de «aguante» (tamaño y longevidad), con peso `plague_genetic_weight`.
static func frailty(s: Sphere) -> float:
	var vitality: float = clampf(s.health / Sphere.MAX_HEALTH, 0.0, 1.0) \
		* clampf(s.energy / Sphere.MAX_ENERGY, 0.0, 1.0)
	var size_01: float = inverse_lerp(Traits.SIZE_MIN, Traits.SIZE_MAX, s._t_size)
	var longevity_01: float = inverse_lerp(Traits.LONGEVITY_MIN, Traits.LONGEVITY_MAX, s._t_longevity)
	var genetic: float = 0.5 * clampf(size_01, 0.0, 1.0) + 0.5 * clampf(longevity_01, 0.0, 1.0)
	var w: float = GlobalParams.tuning.plague_genetic_weight
	return clampf(1.0 - ((1.0 - w) * vitality + w * genetic), 0.0, 1.0)


## Pacientes cero de una plaga a `intensity`: las `max(1, ceil(i × plague_max_zeros))`
## esferas vivas más débiles de `spheres`. Un solo orden, O(n log n).
static func pick_zeros(spheres: Array, intensity: float) -> Array[Sphere]:
	var scored: Array = []   # [debilidad, esfera]
	for n in spheres:
		var s: Sphere = n as Sphere
		if s != null and s._alive:
			scored.append([frailty(s), s])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var n_zeros: int = mini(maxi(1, ceili(intensity * GlobalParams.tuning.plague_max_zeros)),
		scored.size())
	var out: Array[Sphere] = []
	for idx in n_zeros:
		out.append(scored[idx][1])
	return out


## Intento de contagio de `target` con la cepa `strain`: falla si no está vivo, ya está
## infectado o es inmune a esa cepa; si no, se contagia con
## `p = Climate.plague_strength() × plague_contagion × debilidad(target)`, tirando
## con `rng` (el del infectado). Devuelve si se contagió.
static func try_infect(target: Sphere, strain: int, rng: RandomNumberGenerator) -> bool:
	if not target._alive or target.is_plague_infected() or target._plague_immune_strain == strain:
		return false
	var p: float = Climate.plague_strength() * GlobalParams.tuning.plague_contagion * frailty(target)
	if rng.randf() >= p:
		return false
	target.infect_plague(strain)
	return true
