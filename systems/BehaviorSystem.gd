class_name BehaviorSystem
extends RefCounted
## Utility AI por esfera — selección con histéresis explícita.
##
## Cada acción candidata se evalúa en dos ejes INDEPENDIENTES:
##  - factibilidad (`is_feasible`): ¿puede el agente hacerla ahora? (binario)
##  - utilidad (`utility`): cuánto la desea, en [0..1] (0 = indiferente,
##    1 = urgencia máxima).
##
## Separarlos evita la clase de bug en que un `return 0.0` significaba a la
## vez "imposible" y "no me apetece".
##
## La selección NO es estocástica. Se elige la acción factible de mayor
## utilidad, pero solo se CAMBIA respecto a la actual si la supera por
## `switch_margin`. Esa histéresis hace el thrashing imposible por
## construcción: para oscilar entre A y B, cada una tendría que superar a la
## otra por el margen a la vez — contradicción. No depende de equilibrar una
## temperatura de softmax con un bonus de pegajosidad (el modelo anterior).
##
## Las escalas de utilidad se diseñan para que la PRIORIDAD emerja sola, sin
## un sistema de prioridad aparte: `flee` y `seek_food` pueden llegar a 1.0;
## `fight` se limita a FIGHT_MAX; `seek_mate` se auto-limita por hambre;
## `follow_group` a FOLLOW_GROUP_MAX; `wander` es el suelo. Así sobrevivir
## siempre gana a cortejar o pelear sin depender de números finos.
##
## Stateless: el estado vive en la `Sphere`; aquí solo funciones puras de
## factibilidad/utilidad, testeables de forma aislada. El tuning (márgenes,
## curvas) vive en `GlobalParams.tuning` (SimTuning).
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Decisiones de diseño cerradas").

enum Action { WANDER, SEEK_FOOD, SEEK_MATE, FLEE, FIGHT, FOLLOW_GROUP, GATHER, ATTACK_FARM }

const ALL_ACTIONS: Array[int] = [
	Action.WANDER, Action.SEEK_FOOD, Action.SEEK_MATE,
	Action.FLEE, Action.FIGHT, Action.FOLLOW_GROUP, Action.GATHER, Action.ATTACK_FARM,
]

## Tope de utilidad de `fight`: por debajo de 1.0 a propósito, para que
## pelear nunca gane a huir de una amenaza fuerte ni a comer en inanición.
const FIGHT_MAX: float = 0.7
## Tope de utilidad de `follow_group`: actividad social de prioridad media.
const FOLLOW_GROUP_MAX: float = 0.5
## Tope de utilidad de `gather`: recolectar es una actividad de PROSPERIDAD, no de
## supervivencia. Por debajo de 1.0 a propósito, para que comer/huir siempre ganen
## a recolectar (un agente hambriento o amenazado no se pone a picar piedra).
const GATHER_MAX: float = 0.65
## Tope de utilidad de `attack_farm`: por debajo de FIGHT_MAX a propósito, para que
## pelear contra unidades enemigas (defenderse) gane a arrasar una estructura, y que
## comer/huir siempre ganen. Arrasar es un acto de conflicto, no de supervivencia.
const RAID_MAX: float = 0.6


static func action_name(action: int) -> String:
	match action:
		Action.WANDER: return "wander"
		Action.SEEK_FOOD: return "seek_food"
		Action.SEEK_MATE: return "seek_mate"
		Action.FLEE: return "flee"
		Action.FIGHT: return "fight"
		Action.FOLLOW_GROUP: return "follow_group"
		Action.GATHER: return "gather"
		Action.ATTACK_FARM: return "attack_farm"
		_: return "unknown"


## Elige la acción para este tick. `ctx` describe el estado del agente (ver
## las claves leídas más abajo). Devuelve `current_action` salvo que otra
## acción factible la supere por `switch_margin`; si la acción actual dejó
## de ser factible, cambia sin más.
static func select(ctx: Dictionary, current_action: int, tuning: SimTuning,
		rng: RandomNumberGenerator) -> int:
	var best_action: int = Action.WANDER
	var best_u: float = -1.0
	var current_u: float = -1.0
	for action in ALL_ACTIONS:
		if not is_feasible(action, ctx):
			continue
		# Ruido pequeño para desempatar acciones casi iguales (variedad "no
		# robótica"); por diseño muy por debajo de switch_margin, así nunca
		# provoca un cambio por sí solo.
		var u: float = utility(action, ctx, tuning) + rng.randf() * tuning.exploration_noise
		if action == current_action:
			current_u = u
		if u > best_u:
			best_u = u
			best_action = action
	# Histéresis: mantener la acción actual mientras siga siendo factible y
	# nadie la supere por el margen. current_u < 0 ⇒ dejó de ser factible.
	if current_u >= 0.0 and best_action != current_action \
			and best_u <= current_u + tuning.switch_margin:
		return current_action
	return best_action


## Factibilidad binaria: ¿puede el agente ejecutar esta acción ahora?
static func is_feasible(action: int, ctx: Dictionary) -> bool:
	match action:
		Action.WANDER:
			return true
		Action.SEEK_FOOD:
			return true  # siempre se puede ir a buscar comida
		Action.SEEK_MATE:
			return bool(ctx.get("mate_in_sight", false)) \
				and not bool(ctx.get("repro_on_cooldown", false))
		Action.FLEE:
			# Factibilidad = EXISTE una amenaza, no que su presión supere un
			# umbral. La presión es una magnitud continua que oscila en torno
			# a 0 → gatear la factibilidad con ella hace parpadear flee. La
			# intensidad la modula la utilidad (→0 si la amenaza está lejos).
			return bool(ctx.get("threat_present", false))
		Action.FIGHT:
			return bool(ctx.get("fight_in_range", false))
		Action.FOLLOW_GROUP:
			return bool(ctx.get("has_group", false))
		Action.GATHER:
			# Hay un recurso cosechable a la vista y alguna necesidad que cubrir
			# (fabricar arma, aportar a una granja, o impulso laborioso si saciado).
			return bool(ctx.get("resource_in_sight", false)) \
				and float(ctx.get("resource_need_01", 0.0)) > 0.0
		Action.ATTACK_FARM:
			# Hay una granja de un grupo HOSTIL al alcance (la adquisición ya filtra
			# hostilidad + alcanzabilidad en la Sphere).
			return bool(ctx.get("enemy_farm_in_range", false))
	return false


## Utilidad [0..1] de una acción factible. No se llama si no es factible.
static func utility(action: int, ctx: Dictionary, tuning: SimTuning) -> float:
	match action:
		Action.WANDER:
			return tuning.wander_utility
		Action.SEEK_FOOD:
			# Sube de forma continua con el hambre; → 1 cerca de la inanición.
			return smoothstep(0.1, tuning.hunger_critical, float(ctx.get("hunger_01", 0.0)))
		Action.SEEK_MATE:
			return _utility_seek_mate(ctx, tuning)
		Action.FLEE:
			# Aliados cerca alivian el miedo (M2: el grupo da coraje).
			var relief: float = 1.0 - float(ctx.get("ally_support", 0.0)) * tuning.support_fear_relief
			# Territorio: invadir zona ajena amplifica el miedo ante una amenaza
			# real; dominar la propia lo apacigua (el dueño aguanta). No crea flee
			# por sí solo (sigue exigiendo amenaza presente), solo modula su
			# intensidad. Factor acotado a ≥0.
			var terr: float = maxf(1.0
				+ float(ctx.get("territory_rival_pressure", 0.0)) * tuning.territory_fear_weight
				- float(ctx.get("territory_ownership", 0.0)) * tuning.territory_home_courage
						* _territory_defense_mult(ctx), 0.0)
			return clampf(float(ctx.get("threat_pressure", 0.0))
				* (1.2 - float(ctx.get("bravery", 0.5))) * relief * terr, 0.0, 1.0)
		Action.FIGHT:
			return _utility_fight(ctx, tuning)
		Action.FOLLOW_GROUP:
			return _utility_follow_group(ctx, tuning)
		Action.GATHER:
			# Crece con la necesidad de recurso (drive de arma/granja u oportunista)
			# y la laboriosidad del agente; acotada por GATHER_MAX (< supervivencia).
			var need: float = float(ctx.get("resource_need_01", 0.0))
			var ind: float = float(ctx.get("industriousness", 0.5))
			return clampf(need * (0.5 + 0.5 * ind), 0.0, GATHER_MAX)
		Action.ATTACK_FARM:
			# Ganas de arrasar: mezcla de agresividad y territorialidad, amplificada
			# por la hostilidad inter-grupo (misma chispa que el bono de pelea). El
			# objetivo siempre es de un grupo hostil (lo garantiza la adquisición).
			var aggression: float = float(ctx.get("aggression", 0.5)) * GlobalParams.aggression_modifier
			var territoriality: float = float(ctx.get("territoriality", 0.5))
			var drive: float = 0.5 * aggression + 0.5 * territoriality
			var hostility: float = 0.6 + tuning.group_hostility_fight_bonus
			return clampf(drive * hostility * tuning.farm_raid_weight, 0.0, RAID_MAX)
	return 0.0


## Utilidad de seguir al grupo. Base = mezcla de sociabilidad y lealtad (M5),
## acotada por FOLLOW_GROUP_MAX como antes. Término "refugio" (M1): un cobarde
## con una amenaza presente y grupo cerca tira hacia los suyos; solo este término
## puede elevar el tope hasta `follow_group_refuge_max` (sin amenaza no cambia).
static func _utility_follow_group(ctx: Dictionary, tuning: SimTuning) -> float:
	var soc: float = float(ctx.get("sociability", 0.5))
	var loy: float = float(ctx.get("loyalty", 0.5))
	var w: float = tuning.follow_loyalty_weight
	var base: float = clampf(((1.0 - w) * soc + w * loy)
		* GlobalParams.sociability_modifier * FOLLOW_GROUP_MAX, 0.0, FOLLOW_GROUP_MAX)
	var refuge: float = 0.0
	if bool(ctx.get("threat_present", false)):
		refuge = (1.0 - float(ctx.get("bravery", 0.5))) \
			* float(ctx.get("threat_pressure", 0.0)) * tuning.group_refuge_bonus
	return clampf(base + refuge, 0.0, tuning.follow_group_refuge_max)


static func _utility_seek_mate(ctx: Dictionary, tuning: SimTuning) -> float:
	var repro_appetite: float = float(ctx.get("repro_appetite", 0.0))
	# Ventana reproductiva: ni muy joven ni muy viejo (pico en age_01 ≈ 0.4).
	var age_01: float = float(ctx.get("age_01", 0.5))
	var age_window: float = maxf(1.0 - absf(age_01 - 0.4) * 2.0, 0.0)
	# Saciedad: cortejar requiere estar bien alimentado, con rampas suaves
	# (no cortes binarios, que harían parpadear la decisión al cruzarlos).
	var energy_01: float = float(ctx.get("energy_01", 1.0))
	var hunger: float = float(ctx.get("hunger_01", 0.0))
	var energy_ok: float = smoothstep(tuning.mate_min_energy - 0.1,
		tuning.mate_min_energy + 0.1, energy_01)
	var hunger_ok: float = 1.0 - smoothstep(tuning.mate_max_hunger - 0.1,
		tuning.mate_max_hunger + 0.1, hunger)
	return repro_appetite * age_window * energy_ok * hunger_ok


static func _utility_fight(ctx: Dictionary, tuning: SimTuning) -> float:
	var aggression: float = float(ctx.get("aggression", 0.5)) * GlobalParams.aggression_modifier
	var hunger: float = float(ctx.get("hunger_01", 0.0))
	# size_advantage ∈ [-1..1]; lo remapeamos a [0..1] como factor.
	var size_adv: float = clampf(float(ctx.get("size_advantage", 0.0)), -1.0, 1.0)
	var raw: float = aggression * (0.6 + 0.4 * hunger) * (0.55 + 0.45 * (size_adv * 0.5 + 0.5))
	# M2: aliados cerca dan arrojo para plantar cara. Y si el objetivo es de un
	# grupo RIVAL, hostilidad inter-grupo añade más ganas (amplifica el brawl).
	var bonus: float = float(ctx.get("ally_support", 0.0)) * tuning.support_fight_bonus
	if bool(ctx.get("hostile_target", false)):
		bonus += tuning.group_hostility_fight_bonus
	# Ventaja de dueño: defender el propio territorio da arrojo para plantar cara
	# a los intrusos (GDD → territorialidad). Como los bonos de apoyo/hostilidad,
	# puede elevar el tope de fight de forma modesta. El arrojo defensivo escala
	# con `terr_defense` (territorialidad + valentía; ver _territory_defense_mult).
	bonus += float(ctx.get("territory_ownership", 0.0)) * tuning.territory_defense_bonus \
		* _territory_defense_mult(ctx)
	if bool(ctx.get("contesting_food", false)):
		# Disputar un alimento es un motivo de combate de primer orden — la
		# comida es el motor del conflicto (GDD). Se permite superar el tope
		# normal para que la esfera luche por el recurso en vez de cederlo
		# implícitamente al perder la utilidad frente a seek_food.
		return clampf(raw + 0.25 + bonus, 0.0, 0.95)
	# Con apoyo/hostilidad el tope sube de FIGHT_MAX (0.7) hasta ≈0.95, pero sigue
	# por debajo de huir/comer en máximo (1.0): sobrevivir aún manda.
	return clampf(raw + bonus, 0.0, 0.95)


## Multiplicador de la respuesta DEFENSIVA territorial (arrojo en zona propia,
## aguante frente al miedo): combina territorialidad y valentía. Decisión de
## diseño (GDD → Territorialidad): defender el hogar depende de AMBAS. A medias
## 0.5/0.5 da 1.0 → preserva la calibración previa (cuando solo intervenía la
## ventaja de dueño); valores altos amplían la defensa, bajos la anulan. Acotado
## a [0..2].
static func _territory_defense_mult(ctx: Dictionary) -> float:
	return clampf(float(ctx.get("territoriality", 0.5))
		+ float(ctx.get("bravery", 0.5)), 0.0, 2.0)
