extends Node
## Sistema de grupos con propósito compartido (autoload `Groups`).
##
## Cada grupo guarda: lista de miembros vivos, un líder (el miembro de
## mayor edad), un objetivo activo (`goal`) y una posición objetivo
## (`target_pos`). El líder reevalúa el objetivo periódicamente en base
## al estado promedio del grupo. Los miembros en `FOLLOW_GROUP` se
## dirigen a `target_pos` en vez de al centroide del grupo, lo que
## evita que dos miembros en seguimiento mutuo se queden estáticos.
##
## Objetivos posibles:
##  - GATHER: reagruparse en el centroide actual (estado por defecto).
##  - FORAGE: ir a por la planta madura más cercana al centroide.
##  - MIGRATE: moverse a un punto aleatorio dentro del mundo
##              (cuando llevan tiempo sin objetivo claro).
##
## Cohesión y disolución: cada grupo guarda una `cohesion` (media de afinidades
## internas, recalculada al reevaluar) que decae con los conflictos porque el
## combate baja la afinidad. Un grupo se disuelve si la cohesión cae por debajo
## de `group_cohesion_min`, si se queda con < 2 miembros, o si es demasiado
## grande para el alimento local y pasa hambre de forma sostenida.
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Grupos").

enum Goal { GATHER, FORAGE, MIGRATE, BUILD_FARM, INVADE }

const FARM_SCENE: PackedScene = preload("res://entities/Farm.tscn")

# Tuning de grupos centralizado en SimTuning (GlobalParams.tuning).

var _groups: Dictionary = {}  # id -> {members:Array[Sphere], leader_id:int, goal:Goal, target_pos:Vector3, cooldown:float, cohesion:float, hungry_streak:int}
var _rng: RandomNumberGenerator


func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	SimulationClock.tick.connect(_on_tick)


func register_member(group_id: int, sphere) -> void:
	if group_id == -1 or sphere == null:
		return
	var is_new: bool = not _groups.has(group_id)
	var g: Dictionary = _groups.get(group_id, _make_group(group_id))
	if not g.members.has(sphere):
		g.members.append(sphere)
		# Bolsa común: el recién llegado vuelca su inventario personal a la bolsa
		# del grupo (los recursos pasan a ser colectivos al integrarse).
		_drain_inventory_to_pool(sphere, g.pool)
	_groups[group_id] = g
	if is_new:
		EventLog.log_event(&"group_formed", {
			"group_id": group_id,
			"name": g.name,
			"species": String(sphere.genome.get("species", &"?")),
		}, &"groups")

func unregister_member(group_id: int, sphere) -> void:
	if not _groups.has(group_id):
		return
	var g: Dictionary = _groups[group_id]
	g.members.erase(sphere)
	if g.members.size() <= 1:
		_groups.erase(group_id)


func get_target_pos(group_id: int) -> Vector3:
	## Devuelve la posición objetivo activa del grupo, o INF si no hay grupo.
	## En modo FORAGE valida que la planta referenciada siga viva; si ya fue
	## comida, limpia el objetivo para que el grupo reevalúe antes.
	if not _groups.has(group_id):
		return Vector3(INF, INF, INF)
	var g: Dictionary = _groups[group_id]
	if g.goal == Goal.FORAGE:
		var plant = g.forage_plant
		if plant == null or not is_instance_valid(plant) \
				or not (plant is Plant) or plant.stage != Plant.Stage.MATURE \
				or plant.bites_left <= 0:
			g.forage_plant = null
			g.goal = Goal.GATHER
			g.cooldown = 0.0   # reevaluar en el próximo tick
			return Vector3(INF, INF, INF)
	return g.target_pos


func get_goal(group_id: int) -> int:
	if not _groups.has(group_id):
		return Goal.GATHER
	return _groups[group_id].goal


## Cohesión actual del grupo (media de afinidades internas entre miembros), o 0
## si el grupo no existe. Se recalcula al ritmo de reevaluación del líder.
func get_cohesion(group_id: int) -> float:
	if not _groups.has(group_id):
		return 0.0
	return float(_groups[group_id].cohesion)


## Centroide cacheado del grupo (actualizado cada tick), o INF si no existe. Lo
## usa la huida-hacia-grupo de `Sphere._flee_from`.
func get_centroid(group_id: int) -> Vector3:
	if not _groups.has(group_id):
		return Vector3(INF, INF, INF)
	return _groups[group_id].centroid


## Radio dentro del cual un miembro cuenta como "agrupado" en GATHER (fracción del
## stray radius, siempre < expulsión). Cacheado cada tick. 0 si el grupo no existe.
func get_cohesion_radius(group_id: int) -> float:
	if not _groups.has(group_id):
		return 0.0
	return float(_groups[group_id].cohesion_radius)


## ¿El grupo `a_gid` es hostil al `b_gid` ahora mismo? (rivalidad vigente, no
## caducada). Lo consulta `Sphere` para el bono de pelea contra rivales.
func is_hostile(a_gid: int, b_gid: int) -> bool:
	if not _groups.has(a_gid):
		return false
	var rivals: Dictionary = _groups[a_gid].rivals
	return rivals.has(b_gid) and int(rivals[b_gid]) > SimulationClock.get_tick_count()


## ¿El grupo tiene ALGUNA rivalidad vigente? Comprobación barata para gatear la
## búsqueda de granjas enemigas (acción ATTACK_FARM) sin recorrer la escena cuando
## el grupo no está en conflicto. Ver `Sphere._decide_action`.
func has_rivals(group_id: int) -> bool:
	if not _groups.has(group_id):
		return false
	var now: int = SimulationClock.get_tick_count()
	for ogid in _groups[group_id].rivals:
		if int(_groups[group_id].rivals[ogid]) > now:
			return true
	return false


## Miembros vivos del grupo (copia; el llamador no debe mutarla), o [] si el
## grupo no existe. Lo usa el overlay de resaltado para marcarlos en el plano.
func get_members(group_id: int) -> Array:
	if not _groups.has(group_id):
		return []
	return _groups[group_id].members.duplicate()


## Resumen de los grupos VIVOS para visualización (gráfico del HUD). Una entrada
## por grupo: tamaño, color, cohesión, objetivo y nombre. Ordenado por tamaño
## descendente, con desempate por id para que el orden de las barras sea estable
## entre frames (evita parpadeo cuando dos grupos tienen el mismo tamaño).
func get_groups_summary() -> Array:
	var out: Array = []
	for gid in _groups:
		var g: Dictionary = _groups[gid]
		out.append({
			"id": gid,
			"name": g.name,
			"size": g.members.size(),
			"color": g.color,
			"cohesion": g.cohesion,
			"goal": g.goal,
		})
	# Acceso con corchetes a "size": como clave colisiona de nombre con el método
	# Dictionary.size(); los corchetes dejan claro que es la clave, no el método.
	out.sort_custom(func(a, b):
		if a["size"] != b["size"]:
			return a["size"] > b["size"]
		return a["id"] < b["id"])
	return out


func get_group_name(group_id: int) -> String:
	if not _groups.has(group_id):
		return ""
	return _groups[group_id].name


func _make_group(id: int) -> Dictionary:
	return {
		"id": id,
		"members": [],
		"leader_id": 0,
		"goal": Goal.GATHER,
		"target_pos": Vector3.ZERO,
		"pool": {        # bolsa común de recursos del grupo (claves ResourceNode.Type)
			ResourceNode.Type.WOOD: 0,
			ResourceNode.Type.STONE: 0,
			ResourceNode.Type.GOLD: 0,
		},
		"farm_cooldown_until": 0,  # tick hasta el que NO reintentar construir granja
		"build_started_tick": 0,   # tick en que empezó la obra de granja en curso
		"forage_plant": null,   # referencia a la planta objetivo (puede invalidarse)
		"cooldown": 0.0,
		"cohesion": 0.0,        # media de afinidades internas; se recalcula al reevaluar
		"hungry_streak": 0,     # reevaluaciones seguidas con hambre + comida insuficiente
		"migrate_until_tick": 0,   # tick límite de la etapa de migración en curso (timeout)
		"centroid": Vector3.ZERO,  # cacheado cada tick (lo usa la huida-hacia-grupo)
		"cohesion_radius": 0.0,    # radio de "agrupado" en GATHER, cacheado cada tick
		"away_ticks": {},       # member_id -> ticks acumulados lejos del centroide
		"rivals": {},           # other_group_id -> tick hasta el que dura la rivalidad
		"relations": {},        # other_group_id -> afinidad de grupo [-100,100] (libro propio)
		"war_target_gid": -1,   # grupo enemigo objetivo en INVADE (-1 = ninguno)
		"war_leader": false,    # ¿el objetivo de guerra apunta al LÍDER enemigo? (extrema)
		"name": _generate_name(),
		"color": _color_for_id(id),
	}


## Tono distintivo por grupo. Secuencia de razón áurea sobre el id: cada
## grupo recibe un hue separado del anterior con saturación y valor altos,
## para que la pertenencia a un grupo se vea a simple vista en el plano
## (todos los miembros se tiñen con este color en `Sphere._refresh_body_color`).
func _color_for_id(id: int) -> Color:
	var h: float = fposmod(float(id) * 0.6180339887498949, 1.0)
	return Color.from_hsv(h, 0.7, 0.95)


## Devuelve el color del grupo, o `Color(0,0,0,0)` si el grupo ya no existe
## (los miembros que aún apuntan a un grupo disuelto reciben este sentinel
## para revertir a su color de genoma).
func get_group_color(id: int) -> Color:
	if not _groups.has(id):
		return Color(0.0, 0.0, 0.0, 0.0)
	return _groups[id].color


func has_group(id: int) -> bool:
	return _groups.has(id)


# ---------------- BOLSA COMÚN ----------------

## Suma `amount` unidades de `type` a la bolsa del grupo (la alimenta la
## recolección de los miembros).
func add_to_pool(group_id: int, type: int, amount: int) -> void:
	if amount <= 0 or not _groups.has(group_id):
		return
	var pool: Dictionary = _groups[group_id].pool
	pool[type] = int(pool.get(type, 0)) + amount


## Existencias de `type` en la bolsa del grupo (0 si no existe).
func pool_amount(group_id: int, type: int) -> int:
	if not _groups.has(group_id):
		return 0
	return int(_groups[group_id].pool.get(type, 0))


## Intenta cobrar un coste `{type:amount}` de la bolsa de forma atómica (todo o
## nada). Devuelve true si había suficiente y se descontó.
func pool_spend(group_id: int, costs: Dictionary) -> bool:
	if not _groups.has(group_id):
		return false
	var pool: Dictionary = _groups[group_id].pool
	for t in costs:
		if int(pool.get(t, 0)) < int(costs[t]):
			return false
	for t in costs:
		pool[t] = int(pool[t]) - int(costs[t])
	return true


## Copia de la bolsa del grupo para visualización/IA (el llamador no la muta).
func get_pool(group_id: int) -> Dictionary:
	if not _groups.has(group_id):
		return {}
	return _groups[group_id].pool.duplicate()


## Resumen del grupo para la ventana de inspección de grupo (`GroupInspectPanel`):
## líder, tamaño, objetivo, cohesión, poder, bolsa, nº con arma y nº de granjas.
## Diccionario vacío si el grupo no existe.
func get_group_info(group_id: int) -> Dictionary:
	if not _groups.has(group_id):
		return {}
	var g: Dictionary = _groups[group_id]
	var leader_name: String = ""
	var armed: int = 0
	for m in g.members:
		if not is_instance_valid(m):
			continue
		if m.get_instance_id() == int(g.leader_id):
			leader_name = m.full_name()
		if int(m.weapon_level) > 0:
			armed += 1
	if leader_name == "" and not g.members.is_empty() and is_instance_valid(g.members[0]):
		leader_name = g.members[0].full_name()
	var pool: Dictionary = g.pool
	return {
		"name": g.get("name", ""),
		"leader": leader_name,
		"size": g.members.size(),
		"goal": g.goal,
		"cohesion": float(g.get("cohesion", 0.0)),
		"power": power(group_id),
		"wood": int(pool.get(ResourceNode.Type.WOOD, 0)),
		"stone": int(pool.get(ResourceNode.Type.STONE, 0)),
		"gold": int(pool.get(ResourceNode.Type.GOLD, 0)),
		"armed": armed,
		"farms": _count_group_farms(group_id),
		"war_target": get_group_name(int(g.get("war_target_gid", -1))),
		"war_leader": bool(g.get("war_leader", false)),
	}


## Nº de granjas pertenecientes al grupo (recorre el grupo de escena `&"farms"`).
func _count_group_farms(group_id: int) -> int:
	var n: int = 0
	for f in get_tree().get_nodes_in_group(&"farms"):
		if is_instance_valid(f) and int(f.group_id) == group_id:
			n += 1
	return n


## Registra que `thief` (ajeno) ha comido de una granja del grupo `owner_gid`: baja
## la opinión del dueño hacia el GRUPO del ladrón (libro de grupo) y hacia el
## INDIVIDUO ladrón (el líder dueño le coge manía). Lo llama `Sphere._eat`.
func register_theft(owner_gid: int, thief) -> void:
	if not _groups.has(owner_gid) or thief == null or not is_instance_valid(thief):
		return
	var thief_gid: int = thief.group_id
	if thief_gid != -1 and thief_gid != owner_gid and _groups.has(thief_gid):
		adjust_group_affinity(owner_gid, thief_gid, -GlobalParams.tuning.theft_group_penalty)
	var leader = _leader_of(owner_gid)
	if leader != null and leader != thief:
		Relationships.adjust_one_way(leader.get_instance_id(), thief.get_instance_id(),
			-GlobalParams.tuning.theft_individual_penalty)
	EventLog.log_event(&"farm_theft", {
		"owner_group": owner_gid,
		"thief": thief.full_name(),
		"thief_group": thief_gid,
	}, &"groups")


## Registra que `eater` (ajeno pero AFÍN) ha comido de una granja del grupo
## `owner_gid`: en vez de robo es COMPARTIR → sube la afinidad grupo↔grupo y la
## individual con el líder dueño (refuerza la alianza). Lo llama `Sphere._eat`.
func register_share(owner_gid: int, eater) -> void:
	if not _groups.has(owner_gid) or eater == null or not is_instance_valid(eater):
		return
	var bonus: float = GlobalParams.tuning.share_group_bonus
	var eater_gid: int = eater.group_id
	if eater_gid != -1 and eater_gid != owner_gid and _groups.has(eater_gid):
		adjust_group_affinity(owner_gid, eater_gid, bonus)
		adjust_group_affinity(eater_gid, owner_gid, bonus)
	var leader = _leader_of(owner_gid)
	if leader != null and leader != eater:
		Relationships.adjust(leader.get_instance_id(), eater.get_instance_id(), bonus * 0.5)
	EventLog.log_event(&"farm_share", {
		"owner_group": owner_gid,
		"eater": eater.full_name(),
		"eater_group": eater_gid,
	}, &"groups")


## Vuelca el inventario personal de una esfera a `pool` y lo deja a cero. Lo usa
## `register_member` al integrar a un nuevo miembro.
func _drain_inventory_to_pool(sphere, pool: Dictionary) -> void:
	if sphere == null or not is_instance_valid(sphere):
		return
	var inv: Dictionary = sphere.inventory
	for t in inv:
		var amount: int = int(inv[t])
		if amount != 0:
			pool[t] = int(pool.get(t, 0)) + amount
			inv[t] = 0


const _NAME_PREFIX: PackedStringArray = [
	"Clan", "Banda", "Tribu", "Manada", "Círculo", "Hueste", "Coro", "Linaje",
]
const _NAME_ROOT: PackedStringArray = [
	"Or", "Vex", "Lum", "Kir", "Tav", "Zhe", "Mor", "Pyr", "Sol", "Nim",
	"Hel", "Ash", "Bru", "Cael", "Drev", "Eth", "Fyr", "Gor", "Ith", "Jav",
]
const _NAME_SUFFIX: PackedStringArray = [
	"an", "ek", "is", "ora", "un", "yth", "al", "or", "ena", "ix",
]


func _generate_name() -> String:
	var p: String = _NAME_PREFIX[_rng.randi() % _NAME_PREFIX.size()]
	var r: String = _NAME_ROOT[_rng.randi() % _NAME_ROOT.size()]
	var s: String = _NAME_SUFFIX[_rng.randi() % _NAME_SUFFIX.size()]
	return "%s %s%s" % [p, r, s]


func _on_tick(dt_sim: float) -> void:
	var dead_groups: Array = []   # [[gid, reason], ...]
	for gid in _groups.keys():
		# Un grupo puede haber sido absorbido por una fusión iniciada por otro
		# grupo en este mismo tick: ya no existe.
		if not _groups.has(gid):
			continue
		var g: Dictionary = _groups[gid]
		_prune_dead(g)
		if g.members.size() < 2:
			dead_groups.append([gid, "depopulated"])
			continue
		# Centroide cacheado cada tick: lo usan la huida-hacia-grupo (Sphere) y la
		# erosión por dispersión. Barato (grupos pequeños).
		g.centroid = _centroid(g)
		# Radio de cohesión cacheado: fracción del stray radius (< expulsión). Lo
		# consulta el reagrupamiento de Sphere por miembro; cacheado evita O(n²)/tick.
		g.cohesion_radius = _stray_radius(g) * GlobalParams.tuning.group_cohesion_radius_ratio
		g.cooldown -= dt_sim
		if g.cooldown <= 0.0:
			g.cooldown = GlobalParams.tuning.group_reeval_interval
			# Acoplamiento individuo→grupo (al ritmo de reevaluación, no cada tick):
			# la distancia erosiona la afinidad hacia los alejados (M3/M4) y los
			# díscolos crónicos se expulsan (M6). Luego se recomputa la cohesión.
			_erode_strays(g, GlobalParams.tuning.group_reeval_interval)
			_expel_disliked(g)
			if g.members.size() < 2:
				dead_groups.append([gid, "depopulated"])
				continue
			# Cohesión y sostenibilidad: acota el coste O(n²) de la cohesión y
			# evita el thrash forma/disuelve. Si se disuelve, no malgastamos reeval.
			g.cohesion = _compute_cohesion(g)
			var reason: String = _dissolution_reason(g)
			if reason != "":
				dead_groups.append([gid, reason])
				continue
			_reevaluate_goal(g)
			# Relaciones entre grupos: fusión con grupos afines o marca de
			# rivalidad con hostiles cercanos. Si g es absorbido en una fusión,
			# deja de existir y no seguimos tocándolo.
			if _process_intergroup(g):
				continue
		# Construcción de granja: si el grupo está reunido en la obra y la bolsa
		# llega, se levanta la granja (cada tick, no solo al reevaluar).
		if g.goal == Goal.BUILD_FARM:
			_try_build_farm(g)
		# Invasión: seguir al enemigo (su centroide o su líder) cada tick.
		elif g.goal == Goal.INVADE:
			_refresh_invade_target(g)
		# Aunque no reevaluemos el goal, mantener target_pos actualizado
		# para GATHER (centroide se mueve con el grupo).
		elif g.goal == Goal.GATHER:
			g.target_pos = g.centroid
	for entry in dead_groups:
		var gid: int = entry[0]
		var dg: Dictionary = _groups.get(gid, {})
		if dg.is_empty():
			continue
		EventLog.log_event(&"group_dissolved", {
			"group_id": gid,
			"name": dg.get("name", ""),
			"reason": entry[1],
			"cohesion": snappedf(float(dg.get("cohesion", 0.0)), 0.1),
			"size": dg.members.size(),
		}, &"groups")
		_groups.erase(gid)
		_purge_group_relations(gid)


func _prune_dead(g: Dictionary) -> void:
	var live: Array = []
	for m in g.members:
		if m != null and is_instance_valid(m) and m._alive:
			live.append(m)
	g.members = live


func _centroid(g: Dictionary) -> Vector3:
	var sum: Vector3 = Vector3.ZERO
	for m in g.members:
		sum += m.global_position
	return sum / float(g.members.size())


## Radio de alejamiento DINÁMICO: (visión media + offset) escalado por el tamaño
## del grupo. Si un miembro sale de este radio del centroide, el grupo "lo pierde
## de vista" (out of sight, out of mind) y empieza a olvidarlo. El escalado por
## tamaño (√miembros, como el forrajeo colectivo) evita que las manadas grandes
## expulsen en masa por dispersarse de un único centroide.
func _stray_radius(g: Dictionary) -> float:
	var sum: float = 0.0
	for m in g.members:
		sum += float(m.genome.get("vision", 6.0))
	var n: int = g.members.size()
	var mean_vision: float = sum / float(maxi(1, n))
	var base: float = mean_vision + GlobalParams.tuning.group_stray_vision_offset
	# n=2 → ×1; crece con √(n/2), atenuado por group_stray_size_scaling.
	var scale: float = lerpf(1.0, sqrt(float(n) / 2.0), GlobalParams.tuning.group_stray_size_scaling)
	return base * scale


## Erosiona la afinidad que el resto tiene hacia los miembros alejados (M3
## dispersión + M4 ausencia). Un miembro a más de `_stray_radius` del centroide
## durante > `group_stray_grace` empieza a ser olvidado: cada otro miembro le baja
## la afinidad, escalado por distancia y por (1 - su lealtad) — un alejado leal se
## perdona más. `dt` = intervalo entre reevaluaciones.
func _erode_strays(g: Dictionary, dt: float) -> void:
	var members: Array = g.members
	if members.size() < 2:
		return
	var stray_r: float = _stray_radius(g)
	var reeval_ticks: int = int(round(
		GlobalParams.tuning.group_reeval_interval * SimulationClock.TICKS_PER_SECOND))
	var grace_ticks: float = GlobalParams.tuning.group_stray_grace * SimulationClock.TICKS_PER_SECOND
	for m in members:
		var mid: int = m.get_instance_id()
		var d: float = Vector2(m.global_position.x - g.centroid.x,
			m.global_position.z - g.centroid.z).length()
		if d <= stray_r:
			g.away_ticks[mid] = 0
			continue
		g.away_ticks[mid] = int(g.away_ticks.get(mid, 0)) + reeval_ticks
		if float(g.away_ticks[mid]) < grace_ticks:
			continue
		var dist_factor: float = clampf((d - stray_r) / stray_r, 0.0, 2.0)
		var loy: float = float(m.genome.get("loyalty", 0.5))
		var decay: float = GlobalParams.tuning.group_stray_affinity_decay * dt * dist_factor * (1.0 - loy)
		if decay <= 0.0:
			continue
		var forgive_ref: float = GlobalParams.tuning.group_kin_forgive_affinity
		for o in members:
			if o == m:
				continue
			var o_id: int = o.get_instance_id()
			# Perdón por afinidad: quien ya quiere mucho a `m` (familia) lo olvida
			# mucho más despacio; un extraño (afinidad ~0 o negativa) lo erosiona
			# pleno. Suelo del 10 % para que ni la familia retenga a un ausente eterno.
			var aff: float = Relationships.get_affinity(o_id, mid)
			var forgive: float = clampf(1.0 - aff / forgive_ref, 0.1, 1.0)
			Relationships.adjust_one_way(o_id, mid, -decay * forgive)


## Expulsa a los miembros cuya afinidad media RECIBIDA del resto cae por debajo de
## `group_expel_affinity` (solo en grupos de 3+; con 2 lo gestiona la regla de < 2
## miembros). Es la expulsión individual (M6): el grupo limpia ausentes/díscolos
## sin colapsar entero.
func _expel_disliked(g: Dictionary) -> void:
	var members: Array = g.members
	var n: int = members.size()
	if n <= 2:
		return
	var threshold: float = GlobalParams.tuning.group_expel_affinity
	var to_expel: Array = []   # [[member, incoming], ...]
	for m in members:
		var mid: int = m.get_instance_id()
		var sum: float = 0.0
		for o in members:
			if o == m:
				continue
			sum += Relationships.get_affinity(o.get_instance_id(), mid)
		var incoming: float = sum / float(n - 1)
		if incoming < threshold:
			to_expel.append([m, incoming])
	for entry in to_expel:
		if g.members.size() <= 2:
			break   # no vaciar el grupo por debajo de 2 con expulsiones múltiples
		_expel_member(g, entry[0], float(entry[1]))


## Saca a un miembro del grupo conservándolo. Como el grupo sigue existiendo, el
## miembro NO se autolimpia (eso solo ocurre al disolverse): hay que resetear su
## group_id y refrescar etiqueta/color aquí. La expulsión también enfría la
## opinión del expulsado hacia el grupo (estrangamiento mutuo) para que no intente
## reincorporarse de inmediato (evita el thrash expulsa/reingresa).
func _expel_member(g: Dictionary, m, incoming: float) -> void:
	var mid: int = m.get_instance_id()
	var away_s: float = float(g.away_ticks.get(mid, 0)) / SimulationClock.TICKS_PER_SECOND
	g.members.erase(m)
	g.away_ticks.erase(mid)
	for o in g.members:
		Relationships.adjust(mid, o.get_instance_id(), GlobalParams.tuning.group_expel_affinity)
	var mname: String = ""
	if is_instance_valid(m):
		mname = m.full_name()
		m.group_id = -1
		m._refresh_group_tag()
	EventLog.log_event(&"member_expelled", {
		"group_id": g.id,
		"name": g.get("name", ""),
		"member": mname,
		"member_id": mid,
		"incoming_affinity": snappedf(incoming, 0.1),
		"away_s": snappedf(away_s, 0.1),
	}, &"groups")


# ---------------- PODER (ORO) ----------------

## Poder [0..1] del grupo, derivado del oro acumulado en su bolsa común. Aumenta
## la afinidad ajena hacia el grupo y facilita absorber grupos pequeños (ver
## decisión de diseño "oro → poder"). 0 si el grupo no existe.
func power(group_id: int) -> float:
	if not _groups.has(group_id):
		return 0.0
	var gold: int = int(_groups[group_id].pool.get(ResourceNode.Type.GOLD, 0))
	return clampf(float(gold) * GlobalParams.tuning.gold_power_scale_group, 0.0, 1.0)


## Líder del grupo (Sphere) o null. Wrapper público de `_leader_of` para que la IA
## de comida (robo/compartir) pueda identificar al dueño de una granja.
func leader_of(group_id: int):
	return _leader_of(group_id)


## Empuja la afinidad de los miembros del grupo MENOS poderoso hacia los del más
## poderoso (admiración/atracción por el poder), proporcional a la diferencia de
## poder. Una sola dirección (el poderoso no "admira" de vuelta). Se ejecuta al
## ritmo de reevaluación, así que el nudge es modesto pero acumulativo.
func _apply_power_affinity(g: Dictionary, other: Dictionary,
		power_g: float, power_other: float, tuning: SimTuning) -> void:
	var diff: float = power_g - power_other
	if absf(diff) < 0.05:
		return
	var delta: float = tuning.power_affinity_weight * absf(diff)
	# Admiradores = miembros del grupo más débil; ídolos = del más fuerte.
	var admirers: Array = other.members if diff > 0.0 else g.members
	var idols: Array = g.members if diff > 0.0 else other.members
	for a in admirers:
		var aid: int = a.get_instance_id()
		for idol in idols:
			Relationships.adjust_one_way(aid, idol.get_instance_id(), delta)


# ---------------- RELACIONES ENTRE GRUPOS ----------------

## Ids de otros grupos con miembros dentro de `group_interact_radius` del
## centroide de `g` (vía índice espacial; coste acotado por proximidad).
func _nearby_group_ids(g: Dictionary) -> Array:
	var seen: Dictionary = {}
	for s in SpatialIndex.query_spheres(g.centroid, GlobalParams.tuning.group_interact_radius):
		if not (s is Sphere) or not s._alive:
			continue
		var ogid: int = s.group_id
		if ogid == -1 or ogid == g.id or seen.has(ogid):
			continue
		if _groups.has(ogid):
			seen[ogid] = true
	return seen.keys()


## Afinidad media cruzada entre dos grupos (espejo de la cohesión, pero entre
## grupos): media de `get_affinity` en AMBAS direcciones sobre todos los pares
## cruzados de miembros.
func _inter_group_affinity(a: Dictionary, b: Dictionary) -> float:
	var am: Array = a.members
	var bm: Array = b.members
	if am.is_empty() or bm.is_empty():
		return 0.0
	var sum: float = 0.0
	for x in am:
		var xid: int = x.get_instance_id()
		for y in bm:
			var yid: int = y.get_instance_id()
			sum += Relationships.get_affinity(xid, yid) + Relationships.get_affinity(yid, xid)
	return sum / float(2 * am.size() * bm.size())


# ---------------- AFINIDAD DE GRUPO (libro propio) ----------------

## Opinión que el grupo `a` tiene del grupo `b` (libro de grupo, asimétrico). 0 si
## no hay registro. Es un estado PROPIO del grupo, distinto de la media de las
## afinidades individuales (que sigue contando vía `_effective_inter_affinity`).
func group_affinity(a_gid: int, b_gid: int) -> float:
	if not _groups.has(a_gid):
		return 0.0
	return float(_groups[a_gid].relations.get(b_gid, 0.0))


## Ajusta (acotado a [-100,100]) la opinión de `a_gid` sobre `b_gid` en su libro.
func adjust_group_affinity(a_gid: int, b_gid: int, delta: float) -> void:
	if a_gid == b_gid or not _groups.has(a_gid):
		return
	var rel: Dictionary = _groups[a_gid].relations
	rel[b_gid] = clampf(float(rel.get(b_gid, 0.0)) + delta, -100.0, 100.0)


## Afinidad EFECTIVA entre grupos: mezcla la media de afinidades individuales
## cruzadas con el libro de grupo de `g` hacia `other`, ponderada por
## `group_relation_weight`. Es la entrada de fusión/hostilidad/escalada.
func _effective_inter_affinity(g: Dictionary, other: Dictionary) -> float:
	var w: float = GlobalParams.tuning.group_relation_weight
	var individual: float = _inter_group_affinity(g, other)
	var ledger: float = float(g.relations.get(other.id, 0.0))
	return (1.0 - w) * individual + w * ledger


## Olvido lento: acerca todas las entradas del libro de `g` hacia 0 un paso. Sin
## nuevos agravios, las enemistades (y las guerras) se enfrían. Purga las que
## quedan en ~0. Se llama al ritmo de reevaluación.
func _decay_group_relations(g: Dictionary) -> void:
	var step: float = GlobalParams.tuning.group_relation_decay
	if step <= 0.0:
		return
	var rel: Dictionary = g.relations
	for k in rel.keys():
		var v: float = move_toward(float(rel[k]), 0.0, step)
		if absf(v) < 0.01:
			rel.erase(k)
		else:
			rel[k] = v


## Elimina toda referencia a `gid` en los libros de los demás grupos (al disolver
## o fusionar). Evita que opiniones apunten a un grupo inexistente.
func _purge_group_relations(gid: int) -> void:
	for other_gid in _groups:
		var rel: Dictionary = _groups[other_gid].relations
		if rel.has(gid):
			rel.erase(gid)


## Umbral de afinidad efectivo para fusionar dos grupos de los tamaños dados.
## Parte de `group_merge_affinity` y lo rebaja según la disparidad de tamaño
## (small/large): grupos parejos → umbral pleno; muy dispares → umbral reducido
## (un grupo pequeño se integra más fácil en uno grande).
func _merge_threshold(size_a: int, size_b: int, tuning: SimTuning) -> float:
	var small_size: int = mini(size_a, size_b)
	var large_size: int = maxi(size_a, size_b)
	if large_size <= 0:
		return tuning.group_merge_affinity
	var disparity: float = 1.0 - float(small_size) / float(large_size)  # 0 iguales → →1 muy dispares
	return tuning.group_merge_affinity * (1.0 - tuning.group_merge_size_bias * disparity)


## Procesa las relaciones de `g` con los grupos cercanos: fusión (afinidad alta)
## u hostilidad (afinidad baja). Devuelve true si `g` fue ABSORBIDO en una fusión
## (y por tanto ya no existe en `_groups`).
func _process_intergroup(g: Dictionary) -> bool:
	var tuning: SimTuning = GlobalParams.tuning
	var rival_until: int = SimulationClock.get_tick_count() \
		+ int(round(tuning.group_rival_ttl * SimulationClock.TICKS_PER_SECOND))
	for ogid in _nearby_group_ids(g):
		var other: Dictionary = _groups[ogid]
		# Poder (oro de la bolsa): atrae a los demás y facilita absorciones.
		var power_g: float = power(g.id)
		var power_other: float = power(ogid)
		_apply_power_affinity(g, other, power_g, power_other, tuning)
		var aff: float = _effective_inter_affinity(g, other)
		# Un grupo poderoso rebaja el umbral de fusión (absorbe pequeños más fácil).
		var merge_th: float = _merge_threshold(g.members.size(), other.members.size(), tuning) \
			* (1.0 - tuning.power_merge_bias * maxf(power_g, power_other))
		if aff >= merge_th:
			# El grande absorbe al pequeño (desempate: id menor absorbe).
			var g_absorbs: bool = g.members.size() > other.members.size() \
				or (g.members.size() == other.members.size() and g.id < ogid)
			if g_absorbs:
				_merge_groups(g.id, ogid, aff)
			else:
				_merge_groups(ogid, g.id, aff)
				return true   # g fue el absorbido
		elif aff <= tuning.group_hostility_affinity:
			# Rivalidad mutua con caducidad. Log solo al pasar de no-rival a rival.
			var was_rival: bool = is_hostile(g.id, ogid)
			g.rivals[ogid] = rival_until
			other.rivals[g.id] = rival_until
			if not was_rival:
				EventLog.log_event(&"group_rivalry", {
					"a_id": g.id, "b_id": ogid,
					"a_name": g.get("name", ""), "b_name": other.get("name", ""),
					"inter_affinity": snappedf(aff, 0.1),
				}, &"groups")
	return false


## Fusiona `from_id` dentro de `into_id`: reasigna los miembros del pequeño al
## grande (que conserva id/nombre/color) y disuelve el pequeño.
func _merge_groups(into_id: int, from_id: int, aff: float) -> void:
	if into_id == from_id or not _groups.has(into_id) or not _groups.has(from_id):
		return
	var into: Dictionary = _groups[into_id]
	var from: Dictionary = _groups[from_id]
	var into_name: String = into.get("name", "")
	var from_name: String = from.get("name", "")
	var into_size_before: int = into.members.size()
	var from_size: int = from.members.size()
	# La bolsa del grupo absorbido se suma a la del absorbente.
	var into_pool: Dictionary = into.pool
	for t in from.pool:
		into_pool[t] = int(into_pool.get(t, 0)) + int(from.pool[t])
	for m in from.members.duplicate():
		if m == null or not is_instance_valid(m):
			continue
		m.group_id = into_id
		if not into.members.has(m):
			into.members.append(m)
		m._refresh_group_tag()   # recolorea al color del grupo absorbente
	_groups.erase(from_id)
	_purge_group_relations(from_id)
	EventLog.log_event(&"groups_merged", {
		"into_id": into_id, "from_id": from_id,
		"into_name": into_name, "from_name": from_name,
		"into_size": into_size_before, "from_size": from_size,
		"inter_affinity": snappedf(aff, 0.1),
	}, &"groups")


func _avg_hunger(g: Dictionary) -> float:
	var members: Array = g.members
	if members.is_empty():
		return 0.0
	var sum: float = 0.0
	for m in members:
		sum += clampf(1.0 - m.energy / Sphere.MAX_ENERGY, 0.0, 1.0)
	return sum / float(members.size())


## Cohesión = media de la afinidad entre cada par ORDENADO de miembros (ambas
## direcciones, porque la afinidad puede ser asimétrica). Un par cuyo recuerdo
## se haya purgado de la memoria social cuenta como 0 (neutral). O(n²) pero los
## grupos son pequeños y solo se calcula al reevaluar.
func _compute_cohesion(g: Dictionary) -> float:
	var members: Array = g.members
	var n: int = members.size()
	if n < 2:
		return 0.0
	var sum: float = 0.0
	var pairs: int = 0
	for i in n:
		var a_id: int = members[i].get_instance_id()
		for j in n:
			if i == j:
				continue
			sum += Relationships.get_affinity(a_id, members[j].get_instance_id())
			pairs += 1
	return sum / float(pairs) if pairs > 0 else 0.0


## Bocados maduros disponibles dentro de `radius` del centro: capacidad
## alimentaria local con la que se mide la sostenibilidad del grupo.
func _available_bites(center: Vector3, radius: float) -> int:
	var total: int = 0
	for p in SpatialIndex.query_plants(center, radius):
		if p is Plant and p.stage == Plant.Stage.MATURE and p.bites_left > 0:
			total += p.bites_left
	return total


## Motivo por el que el grupo debe disolverse, o "" si sobrevive (ver GDD →
## Agrupación y grupos). Dos causas:
##  - "low_cohesion": la afinidad media interna cae por debajo del umbral
##    (`group_cohesion_min`) — un grupo que pelea consigo mismo se rompe.
##  - "food_unsustainable": un grupo de 3+ miembros que pasa hambre y no tiene
##    bocados suficientes en su radio de visión colectiva durante VARIAS
##    reevaluaciones seguidas (`hungry_streak`) se rompe para que los miembros
##    se dispersen y busquen comida por su cuenta. El streak evita romper por un
##    bajón puntual y el thrash forma/disuelve (un grupo recién formado parte de
##    streak 0). Side-effect a propósito: actualiza `g.hungry_streak`.
func _dissolution_reason(g: Dictionary) -> String:
	if g.cohesion < GlobalParams.tuning.group_cohesion_min:
		return "low_cohesion"
	var n: int = g.members.size()
	if n >= 3 and _avg_hunger(g) > GlobalParams.tuning.group_hunger_trigger:
		var radius: float = minf(17.0 * sqrt(float(n)), 60.0)
		if _available_bites(_centroid(g), radius) < n:
			g.hungry_streak = int(g.hungry_streak) + 1
			if g.hungry_streak >= 2:
				return "food_unsustainable"
			return ""
	g.hungry_streak = 0
	return ""


func _reevaluate_goal(g: Dictionary) -> void:
	var prev_goal: int = g.goal
	var leader = g.members[0]
	for m in g.members:
		if m.age > leader.age:
			leader = m
	g.leader_id = leader.get_instance_id()

	# Las rencillas entre grupos se enfrían poco a poco si no hay nuevos agravios.
	_decay_group_relations(g)

	var center: Vector3 = _centroid(g)
	var avg_hunger: float = _avg_hunger(g)

	# Conflicto: si hay un enemigo lo bastante odiado, la guerra (INVADE) puede
	# anteponerse a la rutina. La extrema enemistad se impone incluso al hambre.
	var war: Dictionary = _evaluate_war(g, center)
	if not war.is_empty() and (bool(war.extreme) \
			or avg_hunger <= GlobalParams.tuning.group_hunger_trigger):
		_enter_invade(g, war)
		_log_goal_change_if_needed(g, prev_goal, avg_hunger)
		return
	# Sin guerra activa este reeval: soltar cualquier objetivo de guerra previo.
	g.war_target_gid = -1
	g.war_leader = false

	if avg_hunger > GlobalParams.tuning.group_hunger_trigger:
		var plant: Node3D = _nearest_mature_plant(center, leader, g.members.size())
		if plant != null:
			g.goal = Goal.FORAGE
			g.forage_plant = plant
			g.target_pos = plant.global_position
		elif _should_build_farm(g, center):
			# Hambre y sin plantas cerca, pero el grupo tiene ARRAIGO alto en su zona:
			# construir una granja para asegurar comida en el territorio propio se
			# antepone a migrar. Los miembros juntan el material con la intención
			# puesta; el sitio se fija al entrar y se conserva mientras dure la obra.
			g.forage_plant = null
			if prev_goal != Goal.BUILD_FARM:
				g.target_pos = _pick_farm_site(g, center)
				g.build_started_tick = SimulationClock.get_tick_count()
			g.goal = Goal.BUILD_FARM
		else:
			# Hambre y no hay plantas maduras cerca: migrar para buscar mejores zonas.
			# La migración es DIRIGIDA: el grupo se compromete con un rumbo y lo
			# mantiene hasta llegar (o agotar el timeout) antes de re-elegir, en vez
			# de re-sortear dirección cada reevaluación (paseo de borracho). En cuanto
			# aparezca una planta madura en el radio, la rama FORAGE de arriba retoma
			# el control en la siguiente reevaluación.
			g.forage_plant = null
			var now: int = SimulationClock.get_tick_count()
			var arrived: bool = Vector2(g.target_pos.x - center.x,
				g.target_pos.z - center.z).length() <= 4.0
			if prev_goal != Goal.MIGRATE or arrived or now >= int(g.migrate_until_tick):
				# Iniciar etapa nueva (primer salto, llegada, o timeout vencido).
				g.target_pos = _pick_migrate_target(g, leader, center)
				g.migrate_until_tick = now + int(round(
					GlobalParams.tuning.group_migrate_timeout * SimulationClock.TICKS_PER_SECOND))
			# Si ya migraba y no ha llegado, se conserva el target_pos en curso.
			g.goal = Goal.MIGRATE
	elif _should_build_farm(g, center):
		# Sin hambre pero ASENTADO (arraigo alto) y sin granja cerca: construir de
		# forma PROACTIVA. Al no estar hambrientos, los miembros sí priorizan
		# recolectar (madera/piedra) sobre buscar comida, así la obra progresa.
		g.forage_plant = null
		if prev_goal != Goal.BUILD_FARM:
			g.target_pos = _pick_farm_site(g, center)
			g.build_started_tick = SimulationClock.get_tick_count()
		g.goal = Goal.BUILD_FARM
	else:
		# Sin hambre apremiante: el grupo se mantiene cohesionado en su centroide.
		# El movimiento ocioso lo aportan los individuos vía `wander`.
		g.goal = Goal.GATHER
		g.forage_plant = null
		g.target_pos = center

	_log_goal_change_if_needed(g, prev_goal, avg_hunger)


## Emite el evento `goal_changed` si el objetivo cambió respecto al previo.
func _log_goal_change_if_needed(g: Dictionary, prev_goal: int, avg_hunger: float) -> void:
	if g.goal == prev_goal:
		return
	EventLog.log_event(&"goal_changed", {
		"group_id": g.id,
		"name": g.get("name", ""),
		"prev_goal": _goal_name(prev_goal),
		"new_goal": _goal_name(g.goal),
		"size": g.members.size(),
		"avg_hunger": avg_hunger,
		"cohesion": snappedf(float(g.get("cohesion", 0.0)), 0.1),
	}, &"groups")


# ---------------- CONFLICTO ENTRE GRUPOS (guerra / invasión) ----------------

## Busca entre los grupos cercanos el más odiado (peor afinidad efectiva). Si el
## odio supera el umbral de invasión, devuelve el objetivo de guerra; si además es
## extremo, apunta al LÍDER enemigo. Diccionario vacío si no hay enemigo que valga.
func _evaluate_war(g: Dictionary, _center: Vector3) -> Dictionary:
	var tuning: SimTuning = GlobalParams.tuning
	var worst_gid: int = -1
	var worst_aff: float = 0.0
	for ogid in _nearby_group_ids(g):
		var aff: float = _effective_inter_affinity(g, _groups[ogid])
		if aff < worst_aff:
			worst_aff = aff
			worst_gid = ogid
	if worst_gid == -1 or worst_aff > tuning.group_invade_affinity:
		return {}
	var enemy: Dictionary = _groups[worst_gid]
	var extreme: bool = worst_aff <= tuning.group_war_affinity
	var pos: Vector3 = enemy.centroid
	if extreme:
		var leader = _leader_of(worst_gid)
		if leader != null:
			pos = leader.global_position
	return {"gid": worst_gid, "pos": pos, "extreme": extreme}


## Fija el objetivo INVADE hacia el enemigo y marca rivalidad mutua (reutiliza el
## mecanismo de hostilidad → bono de pelea inter-grupo).
func _enter_invade(g: Dictionary, war: Dictionary) -> void:
	g.goal = Goal.INVADE
	g.forage_plant = null
	g.war_target_gid = int(war.gid)
	g.war_leader = bool(war.extreme)
	g.target_pos = war.pos
	var rival_until: int = SimulationClock.get_tick_count() \
		+ int(round(GlobalParams.tuning.group_rival_ttl * SimulationClock.TICKS_PER_SECOND))
	g.rivals[int(war.gid)] = rival_until
	if _groups.has(int(war.gid)):
		_groups[int(war.gid)].rivals[g.id] = rival_until


## Refresca el destino de INVADE siguiendo al enemigo (su centroide o su líder, si
## la guerra es a muerte). El grupo enemigo puede haber desaparecido → vuelve a
## GATHER. Se llama cada tick (el enemigo se mueve).
func _refresh_invade_target(g: Dictionary) -> void:
	var egid: int = int(g.get("war_target_gid", -1))
	if egid == -1 or not _groups.has(egid):
		g.goal = Goal.GATHER
		g.war_target_gid = -1
		g.war_leader = false
		g.target_pos = g.centroid
		return
	if bool(g.get("war_leader", false)):
		var leader = _leader_of(egid)
		g.target_pos = leader.global_position if leader != null else _groups[egid].centroid
	else:
		g.target_pos = _groups[egid].centroid


## Id de instancia del líder enemigo objetivo (solo en INVADE a muerte), o -1. Lo
## consulta `Sphere` para priorizarlo como objetivo de combate.
func war_leader_id(group_id: int) -> int:
	if not _groups.has(group_id):
		return -1
	var g: Dictionary = _groups[group_id]
	if g.goal != Goal.INVADE or not bool(g.get("war_leader", false)):
		return -1
	var egid: int = int(g.get("war_target_gid", -1))
	if not _groups.has(egid):
		return -1
	return int(_groups[egid].leader_id)


## El miembro líder del grupo (por `leader_id`), o el primero vivo, o null.
func _leader_of(group_id: int):
	if not _groups.has(group_id):
		return null
	var g: Dictionary = _groups[group_id]
	var lid: int = int(g.leader_id)
	for m in g.members:
		if is_instance_valid(m) and m.get_instance_id() == lid:
			return m
	if not g.members.is_empty() and is_instance_valid(g.members[0]):
		return g.members[0]
	return null


## Elige un punto de migración: dirección aleatoria a distancia
## `[8, group_migrate_radius]` del centro, recortado a los límites del mundo. Una
## migración se compone de varias de estas etapas encadenadas mientras el grupo
## sigue hambriento sin comida cerca, cubriendo terreno en busca de mejores zonas.
func _pick_migrate_target(_g: Dictionary, leader, center: Vector3) -> Vector3:
	var angle: float = _rng.randf() * TAU
	var radius: float = _rng.randf_range(8.0, GlobalParams.tuning.group_migrate_radius)
	var bounds: Vector2 = leader.world_bounds
	var target: Vector3 = center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	target.x = clampf(target.x, -bounds.x * 0.5 + 2.0, bounds.x * 0.5 - 2.0)
	target.z = clampf(target.z, -bounds.y * 0.5 + 2.0, bounds.y * 0.5 - 2.0)
	return target


# ---------------- CONSTRUCCIÓN DE GRANJAS ----------------

## ¿Debe el grupo construir una granja en vez de migrar? Requiere ARRAIGO alto
## (dominancia territorial del grupo en su centro), una territorialidad media
## decente de los miembros y recursos suficientes en la bolsa. Es la decisión
## "quedarse y construir" frente a "migrar" (ver GDD → Economía).
func _should_build_farm(g: Dictionary, center: Vector3) -> bool:
	# Cooldown tras abandonar una obra (no se pudo juntar material): no reintentar ya.
	if SimulationClock.get_tick_count() < int(g.get("farm_cooldown_until", 0)):
		return false
	var ownership: float = TerritorySystem.group_ownership_at(center, g.id)
	if ownership < GlobalParams.tuning.farm_build_ownership_min:
		return false
	if _avg_territoriality(g) < 0.4:
		return false
	# Una sola granja por núcleo: si ya hay una del grupo cerca, no construir otra.
	if _has_farm_near(center, g.id):
		return false
	# Es una INTENCIÓN, no una precondición de recursos: los miembros juntarán
	# madera/piedra con el objetivo puesto (su farm_need se activa al fijar
	# BUILD_FARM). La obra se completa cuando la bolsa cubre el coste; un timeout
	# (ver _try_build_farm) evita quedarse atascado si no hay material alcanzable.
	return true


## ¿Hay ya una granja de este grupo cerca del centro? Evita construir granjas en
## cadena. Pocas granjas en el mundo → recorrido del grupo de escena trivial.
func _has_farm_near(center: Vector3, group_id: int) -> bool:
	var r: float = GlobalParams.tuning.farm_radius * 2.0
	var r2: float = r * r
	for f in get_tree().get_nodes_in_group(&"farms"):
		if not is_instance_valid(f) or int(f.group_id) != group_id:
			continue
		if Vector2(f.global_position.x - center.x,
				f.global_position.z - center.z).length_squared() <= r2:
			return true
	return false


func _avg_territoriality(g: Dictionary) -> float:
	var members: Array = g.members
	if members.is_empty():
		return 0.0
	var sum: float = 0.0
	for m in members:
		sum += float(m.genome.get("territoriality", 0.5))
	return sum / float(members.size())


## Sitio de obra: el propio centro del grupo (donde tiene arraigo), recortado a los
## límites del mundo. Construir en el núcleo evita peregrinaciones y aprovecha la
## zona ya dominada.
func _pick_farm_site(g: Dictionary, center: Vector3) -> Vector3:
	var bounds: Vector2 = g.members[0].world_bounds
	var site: Vector3 = center
	site.x = clampf(site.x, -bounds.x * 0.5 + 2.0, bounds.x * 0.5 - 2.0)
	site.z = clampf(site.z, -bounds.y * 0.5 + 2.0, bounds.y * 0.5 - 2.0)
	return site


## Intenta completar la obra: si el grupo está reunido en el sitio y la bolsa
## cubre el coste, paga y levanta la granja. Si no llega, se mantiene en BUILD_FARM
## (los miembros siguen recolectando); la reevaluación decidirá si abandona.
func _try_build_farm(g: Dictionary) -> void:
	var now: int = SimulationClock.get_tick_count()
	var center: Vector3 = g.centroid
	if Vector2(center.x - g.target_pos.x, center.z - g.target_pos.z).length() \
			> GlobalParams.tuning.farm_radius:
		return
	var costs: Dictionary = {
		ResourceNode.Type.WOOD: GlobalParams.tuning.farm_cost_wood,
		ResourceNode.Type.STONE: GlobalParams.tuning.farm_cost_stone,
	}
	if pool_spend(g.id, costs):
		_spawn_farm(g.id, g.target_pos, g.members[0].world_bounds)
		g.goal = Goal.GATHER
		g.target_pos = center
		return
	# Aún no hay material. Si la obra lleva demasiado tiempo sin completarse (no se
	# logra juntar madera/piedra alcanzable), abandonar y fijar un cooldown para no
	# reintentar de inmediato (evita el bucle gather-imposible).
	var timeout_ticks: int = int(round(
		GlobalParams.tuning.farm_build_timeout * SimulationClock.TICKS_PER_SECOND))
	if now >= int(g.get("build_started_tick", 0)) + timeout_ticks:
		g.farm_cooldown_until = now + timeout_ticks
		g.goal = Goal.GATHER
		g.target_pos = center


func _spawn_farm(group_id: int, pos: Vector3, bounds: Vector2) -> void:
	var world: World = get_tree().get_first_node_in_group("world") as World
	if world == null:
		return
	var farm: Farm = FARM_SCENE.instantiate()
	world.add_child(farm)
	farm.group_id = group_id
	farm.world_bounds = bounds
	var ground_y: float = world.get_terrain_height(pos.x, pos.z)
	farm.global_position = Vector3(pos.x, ground_y, pos.z)
	farm.activate()


static func _goal_name(goal: int) -> String:
	match goal:
		Goal.FORAGE: return "forage"
		Goal.MIGRATE: return "migrate"
		Goal.BUILD_FARM: return "build_farm"
		Goal.INVADE: return "invade"
		_: return "gather"


func _nearest_mature_plant(center: Vector3, _leader, member_count: int = 1) -> Node3D:
	# Visión colectiva: más miembros cubren más área → radio crece con √miembros.
	# Base calibrada para que 2 miembros = 24u (radio previo hardcodeado).
	# Ejemplos: 2→24u  4→34u  9→51u  cap=60u
	var search_radius: float = minf(17.0 * sqrt(float(member_count)), 60.0)
	var plants: Array = SpatialIndex.query_plants(center, search_radius)
	var best: Node3D = null
	var best_d: float = INF
	for p in plants:
		# Saltar plantas no comestibles: no-Plant, inmaduras o ya agotadas
		# (bites_left <= 0). Sin el filtro de bites, _reevaluate_goal elige una
		# planta agotada, get_target_pos la rechaza el mismo tick y el grupo
		# thrashea gather<->forage indefinidamente (miembros que no avanzan).
		if not (p is Plant) or p.stage != Plant.Stage.MATURE or p.bites_left <= 0:
			continue
		var d: float = center.distance_squared_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best
