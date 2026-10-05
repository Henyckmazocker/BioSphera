class_name Sphere
extends CharacterBody3D
## Una esfera viva (Fase 2).
##
## Estado completo + Utility AI. Reemplaza el random walk + scan del prototipo:
## ahora cada tick puntúa acciones candidatas en `BehaviorSystem` y ejecuta la
## elegida. Soporta combate continuo, reproducción sexual y agrupamiento simple.
##
## Ver docs: docs/GDD/Mecánicas.md.

signal died(cause: StringName)
# Sin tipo `Sphere` en el parámetro: auto-referencia circular en el parser
# (la propia clase Sphere aún no está registrada al leer la línea).
signal born(child)

const MAX_ENERGY: float = 100.0
const MAX_HEALTH: float = 100.0
# Alcance para comer: holgado a propósito. El NavigationAgent se da por
# "llegado" a `target_desired_distance` (0.5 m) del destino, y el destino es
# la planta proyectada al navmesh — con un FOOD_REACH ajustado la esfera
# "llega" pero se queda fuera de alcance y muere sin poder comer.
const FOOD_REACH: float = 1.0
# Seguimiento de ruta propio (en XZ). NAV_ADVANCE_DIST: radio XZ para dar por pasado
# un waypoint y avanzar al siguiente. NAV_ARRIVE_DIST: radio XZ al destino final para
# considerar la ruta terminada. Sustituyen a path/target_desired_distance del
# NavigationAgent3D (que comparaban en 3D y se rompían con la Y del navmesh).
const NAV_ADVANCE_DIST: float = 0.6
const NAV_ARRIVE_DIST: float = 0.5
const MATE_REACH: float = 1.2
const FIGHT_REACH: float = 1.2
# Alcance para atacar una granja enemiga (estructura más voluminosa que una esfera).
const FARM_ATTACK_REACH: float = 1.6
# Alcance para recolectar un nodo de recurso (mismo criterio que comer).
const GATHER_REACH: float = 1.0
# Tras un escaneo de recursos sin éxito, espera este tiempo (s sim) antes de volver
# a escanear: evita pagar la query del hash espacial cada decisión cuando no hay
# recurso cerca (frecuente con el oro, escaso). Ver `_decide_action`.
const RESOURCE_SCAN_INTERVAL: float = 1.0
# Tope de niveles de arma que una unidad puede fabricarse.
const WEAPON_LEVEL_MAX: int = 3
# Detección de planta inalcanzable: si un episodio de seek_food dura
# más de TIMEOUT segundos y la esfera ha avanzado menos de MIN_PROGRESS
# metros en total, el target se considera inalcanzable y va a la blacklist.
const SEEK_NO_PROGRESS_TIMEOUT: float = 6.0
const SEEK_MIN_PROGRESS: float = 2.0
const PLANT_BLACKLIST_TICKS: int = 300  # ~10s sim @ 30Hz antes de reconsiderar
const GRAVITY: float = 30.0
const GRAVITY_MAX: float = 60.0   # velocidad terminal de caída
const REPRO_ENERGY_COST: float = 35.0
const REPRO_COOLDOWN: float = 20.0
const REPRO_AFFINITY_THRESHOLD: float = 10.0
# Tope de esferas vivas: por encima, la reproducción no produce cría. Mantiene la
# población —y con ella el coste del tick— dentro del margen que el rendimiento
# sostiene de forma estable. (La densidad de plantas se acota por celda; ver
# `TerritorySystem.cell_has_room_for_plant`.)
const SPHERE_CAP: int = 500
const STRESS_FROM_HUNGER: float = 0.6
const STRESS_FROM_COMBAT: float = 5.0
const STRESS_DECAY: float = 0.3

# Modelos 3D por especie (humanoides animados). Sustituyen al cuerpo primitivo
# (esfera/pirámide) que dibujaba `EntityRenderer` por MultiMesh.
const MODEL_SPECIES_A: PackedScene = preload("res://assets/models/warrior.glb")
const MODEL_SPECIES_B: PackedScene = preload("res://assets/models/scout.glb")
# Giro (yaw) para alinear el "delante" del modelo con el rumbo: el glTF convierte
# Blender(+Y fwd) a Godot(-Z fwd). Ajustable tras verlo en marcha.
const MODEL_YAW_OFFSET: float = 0.0
# Resta al `+0.5` de altura del cuerpo para que los pies del humanoide (origen en
# Y=0 del modelo) queden a ras de suelo en vez del centro del antiguo cuerpo.
const MODEL_FEET_DROP: float = 0.5
# Distancia de cámara a partir de la cual se congela la animación (ahorro de CPU).
const MODEL_ANIM_FREEZE_DIST: float = 60.0
# Cadencia (ms reales) de las chispas de combate por esfera: el daño es continuo, así
# que el «impacto» lo marca la animación de ataque, no la simulación.
const COMBAT_SPARK_INTERVAL_MS: int = 500

@export var world_bounds: Vector2 = Vector2(60.0, 60.0)

var genome: Dictionary = {}
# Rasgos del genoma leídos CADA tick, cacheados como miembros tipados en `setup`.
# El genoma es un Dictionary con claves String: leerlo con `genome.get("clave")`
# por tick por esfera (energía, movimiento, chequeos de muerte) hashea la string
# y devuelve Variant — coste fijo que, agregado a cientos de esferas a 30 Hz,
# pesa en el profiler. Son inmutables tras el nacimiento (la mutación crea un
# genoma nuevo para el hijo, no muta el del padre), así que se cachean una vez.
var _t_size: float = 1.0
var _t_metabolism: float = 1.0
var _t_speed: float = 2.0
var _t_longevity: float = 120.0
var _t_species: StringName = &""
# `aggression` cacheada igual que los anteriores (mismo valor por defecto que el
# `genome.get` al que sustituye): la leen por VECINO `_threat_pressure` (cada
# decisión recorre todos los vecinos) y `_pick_fight_target`.
var _t_aggression: float = 0.5
# Escala VISUAL (independiente del gameplay): normaliza la altura del modelo .glb
# a una banda estrecha en función de `size`, para que no haya enanos/gigantes y
# que ambas especies midan igual a igual `size`. El genoma `size` se sigue usando
# tal cual en las fórmulas de combate/metabolismo/visión. Ver `VisualScale`.
var _t_visual_scale: float = 1.0   # escala uniforme aplicada al modelo
var _visual_height: float = 1.0    # altura final del modelo en u de terreno
# Modificadores por especie usados cada tick (`lifespan`, `metabolism`). La
# especie es fija; estos solo cambian si el jugador mueve un slider de
# `GlobalParams` → se refrescan con la señal `species_changed`.
var _mod_lifespan: float = 1.0
var _mod_metabolism: float = 1.0
var energy: float = MAX_ENERGY
var health: float = MAX_HEALTH
var stress: float = 0.0
var age: float = 0.0
var generation: int = 1
var given_name: String = ""
var group_id: int = -1
var reproduction_cooldown: float = 0.0
# Plaga (modelo SIR, ver `systems/Plague.gd`). Las crías nacen sanas y sin inmunidad.
var _plague_time_left: float = 0.0     # s sim de curso restantes; > 0 → infectado
var _plague_course_s: float = 0.0      # duración total (s sim) del curso actual
var _plague_frailty: float = 0.0       # debilidad al infectarse: fija el daño del curso
var _plague_strain: int = 0            # cepa de la infección actual
var _plague_immune_strain: int = -1    # última cepa superada
var _plague_contagion_acc: float = 0.0 # s sim hacia el próximo intento de contagio
# Inventario PERSONAL de recursos de economía (la comida es energía, no se guarda).
# Cuando la esfera pertenece a un grupo, lo recolectado va a la bolsa común del
# grupo y el gasto sale de ella; como loner usa este inventario. Al unirse a un
# grupo, este inventario se vuelca a la bolsa (ver GroupSystem.register_member).
# Claves: ResourceNode.Type.{WOOD,STONE,GOLD}.
var inventory: Dictionary = {
	ResourceNode.Type.WOOD: 0,
	ResourceNode.Type.STONE: 0,
	ResourceNode.Type.GOLD: 0,
}
# Nivel de arma equipada (0 = sin arma). Persiste hasta la muerte, no se hereda.
# Multiplica el poder de combate (ver `_combat_power`). Se fabrica con madera+piedra.
var weapon_level: int = 0


var _heading: float = 0.0
# Modelo humanoide animado de este individuo (creado en `setup`). Lo dibuja él, no
# el MultiMesh. `_moving` lo fija `_move` para elegir entre animación walk/idle.
var model: EntityModel = null
var _moving: bool = false
## Escala de efectos (pop-in, bounce) que tweenea EffectsDirector. `drive_model` la
## multiplica en la Basis del modelo cada frame: un Tween sobre `model.scale` se pisaría.
var fx_squash: Vector3 = Vector3.ONE
## Tween de EffectsDirector que mueve `fx_squash` ahora mismo (pop-in o bounce), para
## que el siguiente lo componga en vez de pisarlo. Estado visual: no va al save.
var fx_tween: Tween = null
## Próxima chispa de combate permitida (`Time.get_ticks_msec`). Estado visual: no va al save.
var _fx_next_spark_ms: int = 0
var _rng: RandomNumberGenerator
var _alive: bool = true
var _current_action: int = BehaviorSystem.Action.WANDER
var _current_speed_mult: float = 0.7
var _action_changed: bool = false
var _target_plant: Node3D = null
var _target_resource: Node3D = null   # nodo de recurso (Tree/Deposit) que recolecta
var _target_mate: Sphere = null
var _fight_target: Sphere = null
var _target_farm: Node3D = null   # granja de grupo hostil a arrasar (ver ATTACK_FARM)
var _food_rival: Sphere = null   # rival por una planta disputada (ver _pick_food_target)
var _flee_from_pos: Vector3 = Vector3.ZERO
var _flee_target: Sphere = null
var _last_attacker_id: int = 0
var _group_food_hint: Vector3 = Vector3(INF, INF, INF)

var _world: World = null
var _decision_cooldown: float = 0.0  # intervalo en GlobalParams.tuning.decision_interval
var _resource_scan_cooldown: float = 0.0  # backoff del escaneo de recursos sin éxito
var _action_started_t: float = 0.0   # t_sim en que empezó la acción actual
var _eat_count: int = 0              # diagnóstico: nº de veces que ha comido
var _seek_food_seconds: float = 0.0  # tiempo sim acumulado en el episodio actual de seek_food
var _seek_food_distance: float = 0.0 # distancia recorrida en el episodio actual de seek_food
var _seek_food_last_pos: Vector3 = Vector3.ZERO
# Blacklist temporal de plantas que no logró alcanzar: plant_id -> tick a partir
# del cual vuelve a ser elegible. Evita reelegir la misma planta inalcanzable
# inmediatamente. La caducidad permite redescubrirla si la situación cambia
# (la esfera se ha movido, el navmesh sigue siendo el mismo pero el path es
# diferente desde la nueva posición).
var _plant_blacklist: Dictionary = {}

# Color de cuerpo en espacio LINEAL que `EntityRenderer` sube por instancia al
# MultiMesh. Lo calcula `_refresh_body_color` (genoma o color de grupo).
var display_color: Color = Color(1, 1, 1)

# Interpolación visual del cuerpo: la esfera tickea cada `SimulationClock.SPHERE_STRIDE`
# frames (time-slice) y mueve en pasos grandes, así que `global_position` salta. El
# `EntityRenderer` dibuja el cuerpo interpolando entre `_interp_from` (posición antes
# del último paso) e `_interp_to` (después) según los frames transcurridos. La posición
# AUTORITATIVA para la lógica sigue siendo `global_position` (= `_interp_to`).
var _interp_from: Vector3 = Vector3.ZERO
var _interp_to: Vector3 = Vector3.ZERO
var _interp_tick: int = 0

@onready var _name_tag: Label3D = $NameTag
@onready var _group_tag: Label3D = $GroupTag
@onready var _arrow: Node3D = $ArrowIndicator
## Solo se usa como proveedor del RID del mapa de navegación
## (`get_navigation_map`). El seguimiento de ruta es propio y en XZ (ver `_move` /
## `_set_nav_path`): NO se usan target_position/get_next_path_position/
## is_navigation_finished, porque dependían de la Y del navmesh (que ahora es plana).
@onready var _nav_agent: NavigationAgent3D = $NavigationAgent

# Ruta de navegación propia, seguida en XZ ignorando la Y (el navmesh está aplanado a
# Y=0; la altura sale del terreno). `_nav_goal` = último destino pedido (throttle de
# `_seek_if_moved`). Ver `_set_nav_path`, `_nav_finished`, `_move`.
var _nav_path: PackedVector3Array = PackedVector3Array()
var _nav_path_idx: int = 0
var _nav_goal: Vector3 = Vector3(INF, INF, INF)


func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	_heading = _rng.randf() * TAU
	if given_name == "":
		given_name = Traits.random_given_name(_rng)
	_refresh_name_tag()
	# El cuerpo debe poder recorrer CUALQUIER pendiente que el navmesh
	# considere transitable; si no, el pathfinding lo enruta por cuestas que
	# físicamente no puede subir y se queda clavado camino de la comida.
	# Por eso floor_max_angle iguala el agent_max_slope del NavMesh (89°).
	floor_max_angle = deg_to_rad(89.0)
	floor_snap_length = 1.0
	_world = get_tree().get_first_node_in_group("world") as World
	add_to_group(&"spheres")
	# El humanoide encara su rumbo, así que la flecha indicadora es redundante.
	if _arrow != null:
		_arrow.queue_free()
		_arrow = null
	# Los mods por especie solo cambian al mover un slider: refrescar la caché en
	# vez de recalcular `get_species_mod` cada tick. La señal se dispara rara vez,
	# así que conectar todas las esferas no tiene coste por tick.
	GlobalParams.species_changed.connect(_on_species_changed)


## Activación explícita: la llama quien instancia la esfera como ÚLTIMO paso,
## tras posicionarla y configurar su genoma (setup). Conecta el tick y la
## registra en el índice espacial. Ver Plant.activate() para el porqué.
func activate() -> void:
	SpatialIndex.register_sphere(self)
	# Escalona la primera decisión en [0, decision_interval): la población
	# spawneada el mismo frame reevaluaría `_decide_action` en sincronía y
	# provocaría picos donde cientos de esferas hacen queries espaciales (y
	# posibles `map_get_path`) en el mismo frame. La fase se deriva del
	# `instance_id` —estable por esfera— para repartir la carga sin introducir
	# aleatoriedad nueva en el tick (preserva la reproducibilidad del SmokeTest).
	var di: float = GlobalParams.tuning.decision_interval
	_decision_cooldown = di * (float(get_instance_id() % 997) / 997.0)
	# La posición ya es definitiva (activate es el último paso del spawn): sembrar
	# los extremos de interpolación para que el primer render no haga un lerp raro.
	_interp_from = global_position
	_interp_to = global_position
	_interp_tick = SimulationClock.get_tick_count()
	SimulationClock.register_entity(self)


func _exit_tree() -> void:
	SimulationClock.unregister_entity(self)
	SpatialIndex.unregister_sphere(self)
	Relationships.forget(get_instance_id())
	if group_id != -1:
		Groups.unregister_member(group_id, self)


func setup(new_genome: Dictionary, bounds: Vector2, gen: int = 1) -> void:
	genome = new_genome
	world_bounds = bounds
	generation = gen
	# Cachear los rasgos leídos cada tick (ver declaración de `_t_*`).
	_t_size = float(genome.get("size", 1.0))
	_t_metabolism = float(genome.get("metabolism", 1.0))
	_t_speed = float(genome.get("speed", 2.0))
	_t_longevity = float(genome.get("longevity", 120.0))
	_t_species = StringName(String(genome.get("species", &"")))
	_t_aggression = float(genome.get("aggression", 0.5))
	# Escala visual: normalizada por la altura nativa del modelo de la especie.
	var native_h: float = VisualScale.MODEL_NATIVE_HEIGHT_SCOUT if _t_species == &"B" else VisualScale.MODEL_NATIVE_HEIGHT_WARRIOR
	_t_visual_scale = VisualScale.entity_model_scale(_t_size, native_h)
	_visual_height = VisualScale.entity_height(_t_size)
	_refresh_species_mods()
	_ensure_model()
	_apply_genome_visuals()
	_refresh_name_tag()


## Crea (una vez) el modelo humanoide de la especie como hijo de este nodo.
func _ensure_model() -> void:
	if model != null:
		return
	model = EntityModel.new()
	add_child(model)
	model.setup(MODEL_SPECIES_B if _t_species == &"B" else MODEL_SPECIES_A)


func _refresh_species_mods() -> void:
	_mod_lifespan = GlobalParams.get_species_mod(_t_species, &"lifespan")
	_mod_metabolism = GlobalParams.get_species_mod(_t_species, &"metabolism")


func _on_species_changed(species: StringName, _key: StringName, _value: float) -> void:
	if species == _t_species:
		_refresh_species_mods()


func _refresh_name_tag() -> void:
	if _name_tag == null:
		return
	_name_tag.text = full_name()
	# Coloca el tag justo encima de la entidad según su altura visual real.
	_name_tag.position = Vector3(0.0, _visual_height + 0.3, 0.0)
	if _group_tag != null:
		_group_tag.position = Vector3(0.0, _visual_height + 0.6, 0.0)
		_refresh_group_tag()


## Altura visual del modelo en unidades de terreno (ya normalizada por `VisualScale`).
## La usan otros nodos (anillos de grupo, selección de cámara) para no leer el
## `size` crudo del genoma y quedar consistentes con lo que se dibuja.
func visual_height() -> float:
	return _visual_height


## Radio en planta (XZ) aproximado del cuerpo visible, para anillos/selección.
func visual_ground_radius() -> float:
	return 0.45 * _visual_height


func _refresh_group_tag() -> void:
	# El color del cuerpo y la etiqueta del grupo cambian a la vez (ambos
	# reaccionan al estado de pertenencia): centralizar el refresh aquí evita
	# que se desincronicen.
	_refresh_body_color()
	if _group_tag == null:
		return
	if group_id == -1:
		_group_tag.visible = false
		_group_tag.text = ""
		return
	var gname: String = Groups.get_group_name(group_id)
	if gname == "":
		_group_tag.visible = false
		return
	_group_tag.text = gname
	_group_tag.visible = true


## Umbral de hambre del halo: `hunger_01 = 1 - energy/MAX_ENERGY` por encima de esto.
const HALO_HUNGER_01: float = 0.7

const NAME_TAG_MAX_DISTANCE: float = 25.0
const NAME_TAG_FADE_START: float = 18.0

## Coloca y anima el modelo humanoide. Lo invoca `EntityRenderer` cada frame con la
## posición YA interpolada (centro del cuerpo, = terreno + 0.5) y la cámara resuelta.
func drive_model(pos: Vector3, cam: Camera3D) -> void:
	if model != null:
		# Orientar el modelo hacia el rumbo (su "delante" es -Z en Godot), escalar por
		# tamaño y bajar a ras de suelo (los pies del modelo están en Y=0).
		var dir := Vector3(sin(_heading), 0.0, cos(_heading))
		var b: Basis = Transform3D.IDENTITY.looking_at(dir, Vector3.UP).basis
		if MODEL_YAW_OFFSET != 0.0:
			b = b.rotated(Vector3.UP, MODEL_YAW_OFFSET)
		b = b.scaled(Vector3.ONE * _t_visual_scale)
		# Squash de efectos en ejes locales del modelo (Y = vertical del cuerpo).
		if fx_squash != Vector3.ONE:
			b = b * Basis.from_scale(fx_squash)
		model.global_transform = Transform3D(b, Vector3(pos.x, pos.y - MODEL_FEET_DROP, pos.z))

		var st: StringName = &"idle"
		if _fight_target != null and is_instance_valid(_fight_target):
			st = &"attack"
		elif _moving:
			st = &"walk"
		model.set_state(st)
		model.set_weapon_visible(weapon_level > 0)
		if st == &"attack" and EffectsDirector.instance != null:
			_request_hit_sparks()
		# Halo de estado según el modo del jugador (independiente del slider de efectos).
		var halo: int = -1
		match UserSettings.halo_mode:
			UserSettings.HaloMode.ALWAYS:
				halo = _halo_state()
			UserSettings.HaloMode.HOVER:
				if self == Selection.current or self == Selection.hovered:
					halo = _halo_state()
		model.set_halo(halo)
		if cam != null:
			model.set_anim_active(
				cam.global_position.distance_to(global_position) < MODEL_ANIM_FREEZE_DIST)
	update_visuals(cam)


## Estado del halo (`EntityModel.Halo`) o -1. Solo uno, por prioridad:
## combate > plaga > hambre (`hunger_01 > 0.7`) > cortejo. Barato: corre cada frame.
func _halo_state() -> int:
	if _fight_target != null and is_instance_valid(_fight_target):
		return EntityModel.Halo.COMBAT
	if _plague_time_left > 0.0:
		return EntityModel.Halo.PLAGUE
	if energy < MAX_ENERGY * (1.0 - HALO_HUNGER_01):
		return EntityModel.Halo.HUNGER
	if _current_action == BehaviorSystem.Action.SEEK_MATE:
		return EntityModel.Halo.COURTSHIP
	return -1


## Chispas de combate en el punto medio (dibujado) con el rival, cada
## `COMBAT_SPARK_INTERVAL_MS` reales. El gate de distancia/seleccionada lo aplica
## `EffectsDirector.request`; aquí solo la cadencia y el contacto: `attack` se pone
## también mientras se persigue al rival, y entonces no hay impacto que marcar.
func _request_hit_sparks() -> void:
	var now: int = Time.get_ticks_msec()
	if _fx_next_spark_ms > now:
		return
	if _xz_dist(global_position, _fight_target.global_position) > FIGHT_REACH * 1.25:
		return
	_fx_next_spark_ms = now + COMBAT_SPARK_INTERVAL_MS
	var other: Vector3 = _fight_target.model.global_position if _fight_target.model != null \
		else _fight_target.global_position - Vector3.UP * MODEL_FEET_DROP
	var mid: Vector3 = (model.global_position + other) * 0.5 + Vector3.UP * _visual_height * 0.55
	EffectsDirector.instance.request(&"hit_sparks", mid, clampf(_visual_height, 0.6, 1.6))


## Refresco visual por frame. Lo invoca `EntityRenderer` con la cámara ya
## resuelta (una sola consulta para toda la población). Antes vivía repartido
## entre `_process` (nombre) y `_physics_process` (flecha) de cada esfera.
func update_visuals(cam: Camera3D) -> void:
	if cam == null:
		return
	# Una sola consulta de distancia para decidir TODO el trabajo visual por
	# individuo. Etiquetas (`Label3D`) y flecha (`MeshInstance3D`) son nodos por
	# esfera —no batchados en el MultiMesh—: a vista cenital amplia, con cientos
	# de esferas lejos, ocultarlos aquí evita cientos de `look_at` y escrituras
	# de Label3D por frame, además de sus draw calls.
	var d: float = cam.global_position.distance_to(global_position)
	if d >= NAME_TAG_MAX_DISTANCE:
		if _name_tag != null and _name_tag.visible:
			_name_tag.visible = false
		if _group_tag != null and _group_tag.visible:
			_group_tag.visible = false
		if _arrow != null and _arrow.visible:
			_arrow.visible = false
		return
	if _arrow != null and not _arrow.visible:
		_arrow.visible = true
	_update_name_tag_visibility(d)
	_update_arrow()


func _update_arrow() -> void:
	# Solo visual: orienta la flecha indicadora según el rumbo actual
	# (`_heading` se actualiza en `_move`, en lockstep con la simulación).
	if _arrow == null:
		return
	_arrow.look_at(_arrow.global_position + Vector3(cos(_heading), 0.0, sin(_heading)), Vector3.UP)


func _update_name_tag_visibility(d: float) -> void:
	## Solo muestra el nombre cuando la cámara está cerca, para evitar
	## que el plano se llene de texto solapado a vista cenital amplia.
	## La distancia ya viene resuelta desde `update_visuals` (que descarta el
	## caso lejano antes de llamar aquí).
	if _name_tag == null:
		return
	_name_tag.visible = true
	var fade: float = 1.0
	if d > NAME_TAG_FADE_START:
		fade = 1.0 - (d - NAME_TAG_FADE_START) / (NAME_TAG_MAX_DISTANCE - NAME_TAG_FADE_START)
	_name_tag.modulate.a = fade
	_name_tag.outline_modulate.a = fade * 0.8
	if _group_tag != null and group_id != -1 and _group_tag.text != "":
		_group_tag.visible = true
		_group_tag.modulate.a = fade
		_group_tag.outline_modulate.a = fade * 0.8
	elif _group_tag != null:
		_group_tag.visible = false


func full_name() -> String:
	return "%s %s" % [given_name, genome.get("lineage", "Unk")]


func _apply_genome_visuals() -> void:
	# El cuerpo lo dibuja `EntityRenderer` (MultiMesh) leyendo directamente
	# `genome.size` (escala), `genome.species` (forma: A=esfera, B=pirámide) y
	# `display_color`. Aquí solo se calcula el color visible del individuo.
	_refresh_body_color()


## Asigna el color visual del cuerpo: color del grupo si pertenece a uno
## (todos los miembros comparten color → grupos visibles a simple vista),
## o el color del genoma en otro caso. Si el grupo se ha disuelto, el
## sentinel alpha=0 de Groups.get_group_color hace revertir al de genoma.
func _refresh_body_color() -> void:
	var color: Color = genome.get("color", Color(1, 1, 1))
	if group_id != -1:
		var gc: Color = Groups.get_group_color(group_id)
		if gc.a > 0.0:
			color = gc
	# `display_color` se conserva en espacio LINEAL por compatibilidad con quien lo
	# lea. El tinte del modelo usa `albedo_color`, que multiplica la textura: se le
	# pasa el color en sRGB (sin convertir a lineal).
	display_color = color.srgb_to_linear()
	if model != null:
		model.set_tint(color)


# ---------------- TICK ----------------

func _on_tick(dt_sim: float) -> void:
	if not _alive:
		return
	age += dt_sim
	reproduction_cooldown = maxf(0.0, reproduction_cooldown - dt_sim)
	_consume_energy(dt_sim)
	_update_stress(dt_sim)
	if _plague_time_left > 0.0:
		_plague_tick(dt_sim)
	if energy <= 0.0:
		_die(&"hunger")
		return
	# Plaga y combate comparten `health`: si llega a cero estando infectada, es plaga.
	if health <= 0.0:
		_die(&"plague" if _plague_time_left > 0.0 else &"combat")
		return
	if age >= _effective_longevity():
		_die(&"old_age")
		return

	# Limpieza si el grupo se disolvió (el último compañero murió y
	# `Groups.unregister_member` borró la entrada): el `group_id` quedó como
	# referencia colgada → resetear ahora dispara `_refresh_group_tag` que
	# revierte color de cuerpo y etiqueta al estado "sin grupo".
	if group_id != -1 and not Groups.has_group(group_id):
		group_id = -1
		_refresh_group_tag()

	# La histéresis de BehaviorSystem hace inofensivo reevaluar a intervalo
	# fijo: si nada cambia, se mantiene la acción. Ya no hace falta la antigua
	# `_should_interrupt_decision` con sus casos ad-hoc por acción — si la
	# acción actual deja de ser factible, `BehaviorSystem.select` lo detecta.
	_decision_cooldown -= dt_sim
	if _decision_cooldown <= 0.0:
		_decide_action(dt_sim)
		_decision_cooldown = GlobalParams.tuning.decision_interval
	_execute_action(dt_sim)
	_move(dt_sim)
	if _current_action == BehaviorSystem.Action.SEEK_FOOD:
		if _seek_food_seconds > 0.0:
			_seek_food_distance += Vector2(global_position.x - _seek_food_last_pos.x,
				global_position.z - _seek_food_last_pos.z).length()
		_seek_food_seconds += dt_sim
		_seek_food_last_pos = global_position
		# Detector de planta inalcanzable: si llevamos >TIMEOUT s en seek_food
		# y la distancia recorrida total es < MIN_PROGRESS, el target es
		# inalcanzable (path bloqueado físicamente, colisión persistente,
		# orilla del navmesh en zona muerta). Lo blacklisteamos para que la
		# próxima decisión elija otro o degenere a wander/migración.
		if _target_plant != null and is_instance_valid(_target_plant) \
				and _seek_food_seconds >= SEEK_NO_PROGRESS_TIMEOUT \
				and _seek_food_distance < SEEK_MIN_PROGRESS:
			_blacklist_current_plant()
	_enforce_bounds()
	SpatialIndex.update_sphere(self)


## Modificador del entorno sobre `key` (`&"metabolism_mod"`, `&"speed_mod"`,
## `&"vision_mod"`): el del bioma donde está la esfera por el de los eventos activos.
## `Biomes` no sabe de `Climate`; la composición vive aquí.
func _env_mod(key: StringName) -> float:
	return Biomes.get_mod(Biomes.biome_at(global_position), key) * Climate.sphere_mod(key)


## Longevidad efectiva (s sim): rasgo × multiplicador global × modificador de especie.
## La usan la muerte por vejez y la duración del curso de la plaga.
func _effective_longevity() -> float:
	return _t_longevity * GlobalParams.lifespan_multiplier * _mod_lifespan


## Curso de la infección: daño ponderado por la debilidad, contagio a los vecinos
## mientras el evento esté activo (`Climate.plague_strength() > 0`) y, al acabar el
## curso, cura con inmunidad a la cepa. La infección sigue aunque el
## evento haya terminado. Si el daño deja la salud a cero, no se cura: el chequeo de
## muerte de `_on_tick` la cuenta como plaga.
func _plague_tick(dt_sim: float) -> void:
	var tuning: SimTuning = GlobalParams.tuning
	# Daño repartido por igual en el curso, con la debilidad fijada al infectarse: si se
	# recalculara cada tick, la propia pérdida de salud la subiría y el daño total del
	# curso derivaría por encima de `plague_damage_per_course × MAX_HEALTH × (0.5 + d)`.
	health -= tuning.plague_damage_per_course * MAX_HEALTH * (0.5 + _plague_frailty) \
		* dt_sim / _plague_course_s
	if health <= 0.0:
		return
	if Climate.plague_strength() > 0.0:
		_plague_contagion_acc -= dt_sim
		if _plague_contagion_acc <= 0.0:
			_plague_contagion_acc += tuning.plague_contagion_interval
			for n in SpatialIndex.query_spheres(global_position, tuning.plague_radius):
				if n != self:
					Plague.try_infect(n as Sphere, _plague_strain, _rng)
	_plague_time_left -= dt_sim
	if _plague_time_left <= 0.0:
		_plague_time_left = 0.0
		_plague_immune_strain = _plague_strain
		EventLog.log_event(&"plague_cured", {"id": get_instance_id(), "strain": _plague_strain,
			"health": health}, StringName("sphere_%s" % String(genome.get("species", &"?"))))


func is_plague_infected() -> bool:
	return _plague_time_left > 0.0


## Infecta con la cepa `strain` durante `plague_infection_frac` de la longevidad
## efectiva, con la debilidad del momento fijada para todo el curso. El primer intento de
## contagio se desfasa al azar dentro del intervalo para que los infectados no
## consulten a sus vecinos todos en el mismo tick.
func infect_plague(strain: int) -> void:
	var tuning: SimTuning = GlobalParams.tuning
	_plague_course_s = maxf(tuning.plague_infection_frac * _effective_longevity(), 1.0)
	_plague_time_left = _plague_course_s
	_plague_frailty = Plague.frailty(self)
	_plague_strain = strain
	_plague_contagion_acc = _rng.randf() * tuning.plague_contagion_interval
	EventLog.log_event(&"plague_infected", {"id": get_instance_id(), "strain": strain,
		"frailty": _plague_frailty}, StringName("sphere_%s" % String(genome.get("species", &"?"))))


func _consume_energy(dt_sim: float) -> void:
	var metabolism: float = _t_metabolism
	var size: float = _t_size
	var mod: float = _mod_metabolism
	var env_mod: float = _env_mod(&"metabolism_mod")
	energy -= dt_sim * metabolism * (0.6 + 0.4 * size) * mod * env_mod


func _update_stress(dt_sim: float) -> void:
	stress = clampf(stress - STRESS_DECAY * dt_sim, 0.0, 100.0)
	var hunger_01: float = 1.0 - energy / MAX_ENERGY
	if hunger_01 > 0.5:
		stress = clampf(stress + STRESS_FROM_HUNGER * hunger_01 * dt_sim, 0.0, 100.0)


# ---------------- UTILITY AI ----------------

func _decide_action(dt_sim: float) -> void:
	_resource_scan_cooldown = maxf(0.0, _resource_scan_cooldown - dt_sim)
	var hunger_01: float = clampf(1.0 - energy / MAX_ENERGY, 0.0, 1.0)
	var energy_01: float = energy / MAX_ENERGY
	var age_01: float = clampf(age / float(genome.get("longevity", 120.0)), 0.0, 1.0)
	var size: float = float(genome.get("size", 1.0))
	var vision_base: float = float(genome.get("vision", 6.0))
	# Visión efectiva: base × (más grande = más visión) × (más joven = más visión)
	var vision_eff: float = vision_base * (0.8 + 0.4 * size) * (1.0 + 0.3 * (1.0 - age_01))
	var vision: float = vision_eff * _env_mod(&"vision_mod")

	# Visión dividida: plantas detectadas al rango completo (función primaria del rasgo);
	# esferas vecinas a 65% para que visión alta no infle artificialmente seek_mate/flee.
	var neighbors: Array = SpatialIndex.query_spheres(global_position, vision * 0.65)
	var plants: Array = SpatialIndex.query_plants(global_position, vision)

	# Compromiso con la planta objetivo: si la actual sigue siendo comestible,
	# se conserva. Reelegir "la más cercana" cada decisión hace que el objetivo
	# parpadee entre plantas equidistantes y la esfera zigzaguee sin llegar a
	# ninguna — causa de muertes por hambre rodeada de comida.
	# Excepción: si el target dejó de ser alcanzable (la esfera se movió a una
	# zona sin path al target, o la elección inicial fue antes de aplicar el
	# filtro), también forzamos reelección. Sin esto, la esfera persigue una
	# planta inalcanzable hasta morir (caso "Mo Lun" — sesión 2026-05-20).
	var target_lost: bool = not _is_edible(_target_plant) \
		or (_target_plant != null and not _is_target_reachable(_target_plant.global_position))
	if target_lost:
		# Al (re)elegir comida se evalúa la disputa: ver `_pick_food_target`.
		_food_rival = null
		_target_plant = _pick_food_target(plants)
		if _target_plant == null:
			# Sin comida en el rango de visión: búsqueda activa en radio amplio.
			# Sin esto, seek_food sin objetivo degenera en paseo aleatorio y las
			# esferas lentas o en zonas pobres mueren sin encontrar comida.
			_target_plant = _pick_food_target(
				SpatialIndex.query_plants(global_position, GlobalParams.tuning.food_search_radius))
	# Objetivo conservado: la disputa se evaluó al elegirlo; solo validamos
	# que el rival siga siendo un objetivo de combate alcanzable.
	if _food_rival != null and not _is_sphere_target_valid(_food_rival, vision):
		_food_rival = null
	# Compromiso con los objetivos esfera (amenaza / pareja / rival): se
	# conservan mientras sigan siendo válidos y dentro del radio de
	# MANTENIMIENTO (`vision`), mayor que el de ADQUISICIÓN (`vision*0.65`).
	# Esa banda de histéresis evita que un objetivo en el borde de la
	# detección entre y salga: sin ella la factibilidad de flee/seek_mate/
	# fight parpadea y la acción thrashea pese al `switch_margin` (la
	# histéresis de utilidad no amortigua un flip de factibilidad).
	var threat: Sphere = _flee_target
	if not _is_sphere_target_valid(threat, vision):
		threat = _pick_strongest_threat(neighbors, vision)
	var threat_pressure: float = 0.0
	_flee_target = threat
	if threat != null:
		threat_pressure = _threat_pressure(threat, vision)
		_flee_from_pos = threat.global_position

	if not _is_mate_valid(_target_mate, vision):
		_target_mate = _pick_potential_mate(neighbors)
	if not _is_sphere_target_valid(_fight_target, vision):
		_fight_target = _pick_fight_target(neighbors)
	# Disputar un alimento manda sobre cualquier otra rencilla: el rival por
	# la comida pasa a ser el objetivo de combate.
	if _food_rival != null:
		_fight_target = _food_rival
	# Guerra a muerte: si mi grupo va a por el líder enemigo y lo tengo a la vista
	# y alcanzable, se antepone como objetivo de combate (asesinato del cabecilla).
	if group_id != -1:
		var war_leader: int = Groups.war_leader_id(group_id)
		if war_leader != -1:
			for n in neighbors:
				if n is Sphere and n._alive and n.get_instance_id() == war_leader \
						and _is_target_reachable(n.global_position):
					_fight_target = n
					break

	# Objetivo de asalto: granja de un grupo HOSTIL al alcance. Solo los miembros de
	# un grupo CON rivalidad vigente arrasan estructuras (acto de conflicto); el
	# gate por `has_rivals` evita recorrer las granjas cuando no hay conflicto. Se
	# conserva el objetivo mientras siga válido (banda de histéresis `vision`).
	if group_id == -1 or not Groups.has_rivals(group_id):
		_target_farm = null
	elif not _is_farm_target_valid(_target_farm, vision):
		_target_farm = _pick_enemy_farm(vision)

	var has_group: bool = group_id != -1 and _group_has_living_members(neighbors)
	var sociability_raw: float = float(genome.get("sociability", 0.5)) * GlobalParams.get_species_mod(genome.get("species", &""), &"sociability")
	if group_id == -1 and sociability_raw > 0.55:
		_maybe_join_group(neighbors)
		has_group = group_id != -1
	# Poder individual: un loner con oro atrae a los vecinos (más afinidad hacia él),
	# facilitando que formen grupo a su alrededor. Los miembros de grupo aportan su
	# oro a la bolsa, así que su poder se gestiona a nivel de grupo.
	if group_id == -1:
		_radiate_power_affinity(neighbors)

	# Si el grupo está en FORAGE, los miembros heredan el objetivo como
	# pista alimentaria — incluso sin planta visible — para que no se
	# queden siguiendo al grupo lejos de la comida.
	_group_food_hint = Vector3(INF, INF, INF)
	if has_group and Groups.get_goal(group_id) == Groups.Goal.FORAGE:
		_group_food_hint = Groups.get_target_pos(group_id)

	var species_id = genome.get("species", &"")
	var repro_appetite: float = (
		float(genome.get("reproductive_appetite", 0.5))
		* GlobalParams.reproductive_appetite_modifier
		* GlobalParams.get_species_mod(species_id, &"reproductive_appetite")
	)
	var aggression_eff: float = float(genome.get("aggression", 0.5)) * GlobalParams.get_species_mod(species_id, &"aggression")
	var sociability_eff: float = float(genome.get("sociability", 0.5)) * GlobalParams.get_species_mod(species_id, &"sociability")

	# Territorio: depositar presencia (alimenta la dominancia por especie y por
	# grupo; ver TerritorySystem) y leer cuánto pisa zona ajena / propia, para la
	# señal de miedo y la ventaja de dueño en BehaviorSystem.
	var species_sn: StringName = StringName(species_id)
	TerritorySystem.deposit(global_position, species_sn, group_id)
	var terr_rival: float = TerritorySystem.rival_pressure_at(global_position, species_sn, group_id)
	var terr_own: float = TerritorySystem.ownership_at(global_position, species_sn, group_id)

	# Apoyo de grupo (M2): aliados vivos del mismo grupo entre los vecinos ya
	# consultados (coste cero). Normalizado a [0..1] por `group_support_count`.
	var ally_count: int = 0
	if group_id != -1:
		for n in neighbors:
			if n == self or not (n is Sphere) or not n._alive:
				continue
			if n.group_id == group_id:
				ally_count += 1
	var ally_support: float = clampf(
		float(ally_count) / maxf(1.0, GlobalParams.tuning.group_support_count), 0.0, 1.0)

	# Hostilidad entre grupos: ¿el objetivo de pelea pertenece a un grupo RIVAL
	# del mío? Da un bono de arrojo (amplifica las peleas grupales).
	var hostile_target: bool = group_id != -1 and _fight_target != null \
		and is_instance_valid(_fight_target) and _fight_target.group_id != -1 \
		and Groups.is_hostile(group_id, _fight_target.group_id)
	# Defensa de territorio contra INTRUSOS: lo mío que es el suelo donde está el
	# objetivo × lo poco suyo que es (1 − su propiedad ahí). Contra la otra especie
	# en mi tierra vale ~1; contra un vecino de mi especie y grupo, ~0. Con la
	# propiedad del suelo que piso yo (`terr_own`) el bonus estaba activo siempre y
	# subía el tope de fight a 0.95 (Fidelidad, M1).
	var target_terr_own: float = 0.0
	if _fight_target != null and is_instance_valid(_fight_target):
		var tpos: Vector3 = _fight_target.global_position
		var mine: float = TerritorySystem.ownership_at(tpos, species_sn, group_id)
		if mine > 0.0:
			var theirs: float = TerritorySystem.ownership_at(tpos,
				StringName(String(_fight_target.genome.get("species", &""))), _fight_target.group_id)
			target_terr_own = mine * (1.0 - theirs)
	# Defensa de crías: adulto en su nido con crías propias dentro, frente a un objetivo
	# de OTRO grupo (rival o solitario). Solo con objetivo de pelea, por coste: la
	# consulta es O(1) (crías cacheadas en el nido), pero no se paga en cada decisión.
	var nest_guard: bool = false
	if _fight_target != null and is_instance_valid(_fight_target) \
			and _fight_target.group_id != group_id:
		nest_guard = Groups.nest_guard(self)

	# --- Econom\u00eda: necesidad de recursos y nodo cosechable a la vista ---
	# Drive de arma: baja supervivencia esperada en conflicto \u2192 fabricar arma.
	var weapon_need: float = _weapon_need_01(threat, threat_pressure, terr_rival, aggression_eff)
	# Drive de granja: si el l\u00edder fij\u00f3 BUILD_FARM, los miembros aportan a la obra.
	var farm_need: float = 0.0
	if has_group and Groups.get_goal(group_id) == Groups.Goal.BUILD_FARM:
		farm_need = 0.9
	var industriousness: float = float(genome.get("industriousness", 0.5))
	# Madera/piedra SOLO por intencion (arma/granja); el oro se junta de forma
	# oportunista (recurso de poder) cuando esta saciado y es laborioso.
	var directed_need: float = maxf(weapon_need, farm_need)
	var gold_need: float = industriousness * (1.0 - hunger_01) * 0.5
	var resource_need: float = maxf(directed_need, gold_need)
	# Tipos por impulso ACTIVO: madera/piedra solo con intencion dirigida (arma/
	# granja); oro solo por el impulso oportunista.
	var needed_types: Array = []
	if directed_need > 0.1:
		needed_types.append(ResourceNode.Type.WOOD)
		needed_types.append(ResourceNode.Type.STONE)
	if gold_need > 0.1:
		needed_types.append(ResourceNode.Type.GOLD)
	# Solo se busca un nodo cuando hay necesidad real (umbral pequeño): así, hambriento
	# o amenazado, no se paga la query espacial de recursos cada decisión.
	if needed_types.is_empty():
		_target_resource = null
	elif not _is_harvestable_node(_target_resource) \
			or not needed_types.has(_target_resource.type):
		# Solo se escanea si el backoff lo permite; si no encuentra nada, se espera
		# RESOURCE_SCAN_INTERVAL antes de reintentar (evita la query cada decisión
		# cuando no hay recurso cerca).
		if _resource_scan_cooldown > 0.0:
			_target_resource = null
		else:
			_target_resource = _pick_resource_target(needed_types, vision)
			if _target_resource == null:
				_resource_scan_cooldown = RESOURCE_SCAN_INTERVAL
	var resource_in_sight: bool = _is_harvestable_node(_target_resource)
	# Fabricaci\u00f3n de arma (transacci\u00f3n instant\u00e1nea, fuera del sistema de acciones).
	_maybe_craft_weapon(weapon_need)

	# Contexto para BehaviorSystem: estado del agente ya normalizado. El
	# sistema decide factibilidad + utilidad; aqu\u00ed solo recopilamos datos.
	# La cooldown reproductiva gatea la FACTIBILIDAD de seek_mate (no su
	# utilidad), as\u00ed que se pasa como flag en vez de anular repro_appetite.
	var ctx: Dictionary = {
		"resource_need_01": resource_need,
		"resource_in_sight": resource_in_sight,
		"industriousness": industriousness,
		"hunger_01": hunger_01,
		"energy_01": energy_01,
		"age_01": age_01,
		"bravery": float(genome.get("bravery", 0.5)),
		"territoriality": float(genome.get("territoriality", 0.5)) \
			* GlobalParams.territoriality_modifier \
			* GlobalParams.get_species_mod(species_id, &"territoriality"),
		"aggression": aggression_eff,
		"sociability": sociability_eff,
		"repro_appetite": repro_appetite,
		"repro_blocked": not can_reproduce(),
		"mate_in_sight": _target_mate != null,
		"threat_present": threat != null,
		"threat_pressure": threat_pressure,
		"fight_in_range": _fight_target != null,
		"size_advantage": _size_advantage_vs(_fight_target) if _fight_target != null else 0.0,
		"contesting_food": _food_rival != null,
		"has_group": has_group,
		"loyalty": float(genome.get("loyalty", 0.5)),
		"ally_support": ally_support,
		"hostile_target": hostile_target,
		"territory_rival_pressure": terr_rival,
		"territory_ownership": terr_own,
		"target_territory_ownership": target_terr_own,
		"nest_guard": nest_guard,
		"enemy_farm_in_range": _target_farm != null,
	}
	var prev_action: int = _current_action
	# Duración mínima de acción: una vez elegida, se mantiene durante
	# `min_action_duration` aunque la decisión oscile — salvo que deje de ser
	# factible. Backstop temporal contra el thrash que la histéresis de
	# utilidad no cubre (parpadeo de factibilidad, ruido de un entorno
	# concurrido donde el objetivo más peligroso/cercano cambia cada tick).
	var locked: bool = (SimulationClock.get_sim_time() - _action_started_t) \
		< GlobalParams.tuning.min_action_duration
	if locked and BehaviorSystem.is_feasible(prev_action, ctx):
		return
	_current_action = BehaviorSystem.select(ctx, prev_action, GlobalParams.tuning, _rng)
	if _current_action != prev_action:
		_action_started_t = SimulationClock.get_sim_time()
		_log_state_change(prev_action)


func _log_state_change(prev_action: int) -> void:
	if has_meta("_migrate_target"):
		remove_meta("_migrate_target")
	_action_changed = true
	# Reset de contadores de progreso: cada episodio de seek_food debe medirse
	# desde cero para que el detector de inalcanzable no acumule entre episodios.
	_seek_food_seconds = 0.0
	_seek_food_distance = 0.0
	_seek_food_last_pos = global_position
	var species: String = String(genome.get("species", &"?"))
	var category: StringName = StringName("sphere_%s" % species)
	var target_name: String = ""
	match _current_action:
		BehaviorSystem.Action.SEEK_FOOD:
			if _target_plant != null and is_instance_valid(_target_plant):
				target_name = "plant#%d" % _target_plant.get_instance_id()
		BehaviorSystem.Action.SEEK_MATE:
			if _target_mate != null and is_instance_valid(_target_mate):
				target_name = _target_mate.full_name()
		BehaviorSystem.Action.FIGHT:
			if _fight_target != null and is_instance_valid(_fight_target):
				target_name = _fight_target.full_name()
		BehaviorSystem.Action.FLEE:
			if _flee_target != null and is_instance_valid(_flee_target):
				target_name = _flee_target.full_name()
		BehaviorSystem.Action.ATTACK_FARM:
			if _target_farm != null and is_instance_valid(_target_farm):
				target_name = "farm#%d" % _target_farm.get_instance_id()
		BehaviorSystem.Action.GATHER:
			if _is_harvestable_node(_target_resource):
				target_name = "%s#%d" % [
					ResourceNode.type_name(_target_resource.type),
					_target_resource.get_instance_id()]
	var snapshot: Dictionary = {
		"id": get_instance_id(),
		"name": full_name(),
		"species": species,
		"generation": generation,
		"position": [global_position.x, global_position.y, global_position.z],
		"prev_action": BehaviorSystem.action_name(prev_action),
		"new_action": BehaviorSystem.action_name(_current_action),
		"target": target_name,
		"energy": energy,
		"health": health,
		"stress": stress,
		"age": age,
		"repro_cooldown": reproduction_cooldown,
		"group_id": group_id,
		"genome": genome,
	}
	EventLog.log_state_change(category, &"action_change", snapshot)



func _execute_action(dt_sim: float) -> void:
	# `fresh` es true solo el primer tick tras un cambio de acción. Permite
	# forzar la asignación de un nuevo target aunque el NavAgent siga navegando
	# hacia el destino de la acción anterior.
	var fresh: bool = _action_changed
	_action_changed = false
	match _current_action:
		BehaviorSystem.Action.SEEK_FOOD:
			if _target_plant == null or not is_instance_valid(_target_plant):
				# Sin planta a la vista: si el grupo conoce una zona de
				# forrajeo, dirígete hacia ella; al llegar, deambula para
				# encontrar planta concreta.
				if _group_food_hint.x != INF:
					if global_position.distance_to(_group_food_hint) > 1.5:
						_seek_if_moved(_group_food_hint, dt_sim, fresh, 0.25)
					else:
						_wander(dt_sim, fresh)
				else:
					# Sin planta visible ni pista grupal: moverse hacia un punto
					# El navmesh gestiona el rodeo por agua, así que basta con
					# elegir un punto aleatorio en la dirección correcta sin
					# validar walkability manualmente.
					if not has_meta("_migrate_target") or global_position.distance_to(get_meta("_migrate_target")) < 2.0:
						# Desesperación: cuanta más hambre, mayor radio de búsqueda.
						# hunger_01 < 0.3 → radio normal (8–25); hunger_01 = 1 → radio amplio (20–60).
						var desperation: float = clampf((1.0 - energy / MAX_ENERGY - 0.3) / 0.7, 0.0, 1.0)
						var angle: float = _rng.randf() * TAU
						var radius: float = _rng.randf_range(lerpf(8.0, 20.0, desperation), lerpf(25.0, 60.0, desperation))
						var candidate: Vector3 = global_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
						candidate.x = clampf(candidate.x, -world_bounds.x * 0.5 + 2.0, world_bounds.x * 0.5 - 2.0)
						candidate.z = clampf(candidate.z, -world_bounds.y * 0.5 + 2.0, world_bounds.y * 0.5 - 2.0)
						# Reluctancia territorial: evitar buscar comida hacia zona
						# rival salvo que el hambre apriete (la desesperación ya
						# rebaja la reluctancia vía _territory_reluctance).
						for _i in 2:
							if _rng.randf() >= _territory_reluctance(candidate):
								break
							angle = _rng.randf() * TAU
							radius = _rng.randf_range(lerpf(8.0, 20.0, desperation), lerpf(25.0, 60.0, desperation))
							candidate = global_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
							candidate.x = clampf(candidate.x, -world_bounds.x * 0.5 + 2.0, world_bounds.x * 0.5 - 2.0)
							candidate.z = clampf(candidate.z, -world_bounds.y * 0.5 + 2.0, world_bounds.y * 0.5 - 2.0)
						set_meta("_migrate_target", _snap_to_nav(candidate))
					_seek_if_moved(get_meta("_migrate_target"), dt_sim, fresh, 0.25)
				return
			# La planta es estática: solo re-path si el target ha cambiado (nueva
			# planta más cercana seleccionada) o si es el primer tick de esta acción.
			_seek_if_moved(_target_plant.global_position, dt_sim, fresh, 0.25)
			if _target_plant != null and is_instance_valid(_target_plant) \
					and global_position.distance_to(_target_plant.global_position) <= FOOD_REACH:
				_eat(_target_plant)
		BehaviorSystem.Action.SEEK_MATE:
			if _target_mate == null or not is_instance_valid(_target_mate):
				_wander(dt_sim, fresh)
				return
			# La pareja se mueve: re-path cuando se aleja >1 m del último target
			# asignado al navagent para no recalcular cada tick.
			_seek_if_moved(_target_mate.global_position, dt_sim, fresh, 1.0)
			if global_position.distance_to(_target_mate.global_position) <= MATE_REACH:
				_attempt_reproduction(_target_mate)
		BehaviorSystem.Action.FLEE:
			_flee_from(_flee_from_pos, dt_sim, fresh)
		BehaviorSystem.Action.FIGHT:
			if _fight_target == null or not is_instance_valid(_fight_target):
				_wander(dt_sim, fresh)
				return
			# El rival se mueve: mismo umbral que pareja.
			_seek_if_moved(_fight_target.global_position, dt_sim, fresh, 1.0)
			if global_position.distance_to(_fight_target.global_position) <= FIGHT_REACH:
				_attack(_fight_target, dt_sim)
		BehaviorSystem.Action.ATTACK_FARM:
			if not _is_farm_target_valid(_target_farm, INF):
				_wander(dt_sim, fresh)
				return
			# La granja es estática: re-path solo al cambiar de objetivo o primer tick.
			_seek_if_moved(_target_farm.global_position, dt_sim, fresh, 0.25)
			if global_position.distance_to(_target_farm.global_position) <= FARM_ATTACK_REACH:
				_attack_farm(_target_farm, dt_sim)
		BehaviorSystem.Action.FOLLOW_GROUP:
			# Dirigirse al objetivo del grupo (forrajeo / migración /
			# reagrupamiento). El sistema de grupos garantiza un punto
			# externo distinto del centroide cuando hace falta, evitando
			# que dos miembros se queden persiguiéndose mutuamente.
			var goal_pos: Vector3 = Groups.get_target_pos(group_id)
			if goal_pos.x == INF:
				var centroid: Vector3 = _group_centroid()
				if centroid.x == INF:
					_wander(dt_sim, fresh)
				else:
					# Centroide se mueve con los miembros: umbral 1.5 m para
					# no re-path cada tick.
					_seek_if_moved(centroid, dt_sim, fresh, 2.25)
			else:
				# En reagrupamiento (GATHER) basta con estar dentro del radio de
				# cohesión del grupo (laxo, escala con el tamaño, siempre < expulsión)
				# para dar volumen a la manada en vez de apilarse en el centroide. En
				# FORAGE/MIGRATE se exige llegar al destino real (zona muerta 1,5 m).
				var reach: float = 1.5
				if Groups.get_goal(group_id) == Groups.Goal.GATHER:
					reach = maxf(1.5, Groups.get_cohesion_radius(group_id))
				if global_position.distance_to(goal_pos) <= reach:
					_wander(dt_sim, fresh)
				else:
					_seek_if_moved(goal_pos, dt_sim, fresh, 2.25)
		BehaviorSystem.Action.GATHER:
			# El objetivo de recurso lo fija la decisión (con throttle); aquí NO se
			# re-escanea por tick. Sin objetivo válido, deambula.
			if not _is_harvestable_node(_target_resource):
				_wander(dt_sim, fresh)
				return
			_seek_if_moved(_target_resource.global_position, dt_sim, fresh, 0.25)
			if global_position.distance_to(_target_resource.global_position) <= GATHER_REACH:
				_harvest_node(_target_resource)
		_:
			_wander(dt_sim, fresh)


# ---------------- MOVIMIENTO ----------------

## Movimiento de un paso de simulación. Se invoca desde `_on_tick` (no desde
## `_physics_process`) para avanzar en lockstep con la decisión. Con el time-slice
## de esferas, `dt_sim` puede abarcar varios frames de física.
func _move(dt_sim: float) -> void:
	# Integración manual (no `move_and_slide`, que mueve `velocity * physics_delta`
	# —un frame— y con el time-slice `SPHERE_STRIDE` el paso abarca varios frames):
	# se avanza el desplazamiento exacto de `dt_sim`. Tras el cambio de capas las
	# esferas solo "colisionaban" con el terreno → la altura se resuelve muestreando
	# `World.get_terrain_height` y el agua la evita el navmesh, sin solver de física.
	_interp_from = global_position
	_moving = false
	var new_pos: Vector3 = global_position
	var next_pos: Vector3 = _nav_next_waypoint()
	if next_pos.x != INF:
		# Solo XZ: la Y del navmesh es plana e irrelevante; la altura la fija el snap
		# al terreno de abajo. `_nav_next_waypoint` ya avanzó el índice de ruta.
		var dir := Vector3(next_pos.x - global_position.x, 0.0, next_pos.z - global_position.z)
		var dir_len := dir.length()
		if dir_len > 0.01:
			dir = dir / dir_len
			var speed: float = _t_speed * _current_speed_mult
			var env_speed: float = _env_mod(&"speed_mod")
			# Desplazamiento del paso; salvaguarda: no sobrepasar el punto de ruta.
			var step: float = minf(speed * env_speed * dt_sim, dir_len)
			new_pos.x += dir.x * step
			new_pos.z += dir.z * step
			_moving = step > 0.01
			# Rumbo visual: orienta el modelo hacia la dirección de avance.
			_heading = atan2(dir.x, dir.z)
	# Pegar al terreno por muestreo de altura (antes lo hacía gravedad + suelo).
	# `+0.5` = radio de la esfera de colisión: reposaba a esa altura sobre el
	# terreno (igual que el spawn en `Spawner._spawn_sphere`), y el mesh se dibuja
	# con el mismo offset, así que conserva la altura visual previa.
	if _world != null:
		new_pos.y = _world.get_terrain_height(new_pos.x, new_pos.z) + 0.5
	global_position = new_pos
	_interp_to = new_pos
	_interp_tick = SimulationClock.get_tick_count()


# ---------------- NAVEGACIÓN EN XZ (independiente de la Y del navmesh) ----------------
# El navmesh está aplanado a Y=0 (ver World._flatten_navmesh): solo aporta la huella
# XZ transitable. Todas las consultas se hacen aplanadas a Y=0 y el seguimiento de
# ruta es en XZ; la altura de la esfera la fija el snap al terreno en `_move`.

## Aplana una posición a Y=0 para consultar el navmesh.
func _flat(p: Vector3) -> Vector3:
	return Vector3(p.x, 0.0, p.z)


## Distancia en el plano XZ (la Y no interviene en la navegación).
func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## RID del mapa de navegación (el NavigationAgent3D solo se conserva para esto).
func _nav_map() -> RID:
	return _nav_agent.get_navigation_map()


## Calcula y guarda una ruta hacia `target`. Consultas aplanadas a Y=0. La ruta se
## sigue luego en XZ desde `_move`. Reemplaza a `_nav_agent.target_position = ...`.
func _set_nav_path(target: Vector3) -> void:
	_nav_goal = target
	_nav_path_idx = 0
	var nav_map := _nav_map()
	if not nav_map.is_valid():
		_nav_path = PackedVector3Array([_flat(target)])
		return
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, _flat(target))
	_nav_path = NavigationServer3D.map_get_path(nav_map, _flat(global_position), snapped, false)


## ¿Terminó la ruta actual? Reemplaza a `is_navigation_finished()`.
func _nav_finished() -> bool:
	if _nav_path.is_empty() or _nav_path_idx >= _nav_path.size():
		return true
	return _xz_dist(global_position, _nav_path[_nav_path.size() - 1]) <= NAV_ARRIVE_DIST


## Waypoint actual a perseguir, avanzando el índice por los ya alcanzados en XZ.
## Devuelve Vector3(INF,..) si la ruta terminó. Reemplaza a `get_next_path_position()`.
func _nav_next_waypoint() -> Vector3:
	while _nav_path_idx < _nav_path.size() \
			and _xz_dist(global_position, _nav_path[_nav_path_idx]) <= NAV_ADVANCE_DIST:
		_nav_path_idx += 1
	if _nav_path_idx >= _nav_path.size():
		return Vector3(INF, INF, INF)
	return _nav_path[_nav_path_idx]


func _wander(_dt_sim: float, fresh: bool = false) -> void:
	_current_speed_mult = 0.7
	# Sin `fresh`: solo elegir nuevo destino si llegamos al anterior.
	# Con `fresh`: acción recién cambiada, forzar nuevo destino aunque el
	# navagent aún tenga una ruta activa de la acción anterior.
	if not fresh and not _nav_finished():
		return
	var nav_map := _nav_map()
	var angle := _rng.randf() * TAU
	var radius := _rng.randf_range(4.0, 12.0)
	var target := global_position + Vector3(cos(angle), 0.0, sin(angle)) * radius
	target.x = clampf(target.x, -world_bounds.x * 0.5 + 1.0, world_bounds.x * 0.5 - 1.0)
	target.z = clampf(target.z, -world_bounds.y * 0.5 + 1.0, world_bounds.y * 0.5 - 1.0)
	# Reluctancia territorial: si el rumbo cae en zona rival, reintentar (coste
	# blando — hambre y valentía lo rebajan; ver _territory_reluctance).
	for _i in 2:
		if _rng.randf() >= _territory_reluctance(target):
			break
		angle = _rng.randf() * TAU
		radius = _rng.randf_range(4.0, 12.0)
		target = global_position + Vector3(cos(angle), 0.0, sin(angle)) * radius
		target.x = clampf(target.x, -world_bounds.x * 0.5 + 1.0, world_bounds.x * 0.5 - 1.0)
		target.z = clampf(target.z, -world_bounds.y * 0.5 + 1.0, world_bounds.y * 0.5 - 1.0)
	_set_nav_path(target)
	# map_get_path devuelve ≤1 punto si el destino está en una isla desconectada.
	# En ese caso intentar radio corto para quedarse en la misma isla.
	if nav_map.is_valid() and _nav_path.size() <= 1:
		angle = _rng.randf() * TAU
		radius = _rng.randf_range(1.0, 3.0)
		target = global_position + Vector3(cos(angle), 0.0, sin(angle)) * radius
		target.x = clampf(target.x, -world_bounds.x * 0.5 + 1.0, world_bounds.x * 0.5 - 1.0)
		target.z = clampf(target.z, -world_bounds.y * 0.5 + 1.0, world_bounds.y * 0.5 - 1.0)
		_set_nav_path(target)


func _seek(target: Vector3, _dt_sim: float) -> void:
	_current_speed_mult = 1.0
	_set_nav_path(target)


## Llama a _seek solo si el target se alejó más de `sq_threshold` (dist²) del
## último destino pedido, o si la acción acaba de cambiar (`fresh`).
## Evita recalcular el path cada tick cuando el target apenas se ha movido.
func _seek_if_moved(target: Vector3, dt_sim: float, fresh: bool, sq_threshold: float) -> void:
	if fresh or target.distance_squared_to(_nav_goal) > sq_threshold:
		_seek(target, dt_sim)
	else:
		_current_speed_mult = 1.0


## Probabilidad [0..1] de descartar un destino candidato. Coste BLANDO de la
## mecánica territorial, combina dos rechazos vía OR saturante:
##  - INVADIR zona rival: la presión rival pesa, pero la valentía y el hambre la
##    rebajan (un cobarde saciado la evita; un valiente o un hambriento la ignoran).
##  - ARRAIGO (salir de la zona del propio GRUPO): un destino que reduce la
##    dominancia del grupo se rechaza en proporción a la `territoriality` heredada,
##    a cuánto domina la celda actual y a (1-hambre). Escala con el rasgo, así que
##    una esfera muy territorial apenas se aleja de su núcleo (salvo hambre), pero
##    no afecta a FOLLOW_GROUP (la migración de grupo no pasa por aquí). Solo
##    aplica con grupo (un loner no tiene zona propia). Ver GDD → Territorialidad.
func _territory_reluctance(candidate: Vector3) -> float:
	var hunger_01: float = clampf(1.0 - energy / MAX_ENERGY, 0.0, 1.0)
	var species: StringName = StringName(genome.get("species", &""))
	# Reluctancia a INVADIR zona rival (coste por especie/grupo ajeno).
	var rival: float = 0.0
	var rp: float = TerritorySystem.rival_pressure_at(candidate, species, group_id)
	if rp > 0.0:
		var bravery: float = float(genome.get("bravery", 0.5))
		rival = rp * (1.0 - bravery) * (1.0 - hunger_01) * GlobalParams.tuning.territory_dest_avoid
	# ARRAIGO a la zona del propio grupo: rechazo a destinos que la abandonan.
	var home: float = 0.0
	if group_id != -1:
		var own_here: float = TerritorySystem.group_ownership_at(global_position, group_id)
		if own_here > 0.0:
			var own_there: float = TerritorySystem.group_ownership_at(candidate, group_id)
			var leaving: float = clampf(own_here - own_there, 0.0, 1.0)
			var terr_eff: float = float(genome.get("territoriality", 0.5)) \
				* GlobalParams.territoriality_modifier \
				* GlobalParams.get_species_mod(species, &"territoriality")
			home = leaving * own_here * terr_eff \
				* (1.0 - hunger_01) * GlobalParams.tuning.territory_home_attachment
	# OR saturante: cualquiera de los dos rechazos empuja hacia 1 sin pasarse.
	return clampf(1.0 - (1.0 - clampf(rival, 0.0, 1.0)) * (1.0 - clampf(home, 0.0, 1.0)), 0.0, 1.0)


func _flee_from(from_pos: Vector3, _dt_sim: float, fresh: bool = false) -> void:
	_current_speed_mult = 1.3
	# Calcular y asignar un nuevo punto de huida solo al cambiar de acción o al
	# llegar al destino anterior. El punto depende de global_position, así que
	# recalcularlo cada tick mueve el destino continuamente y fuerza re-path
	# en cada tick aunque la amenaza no se haya movido.
	if not fresh and not _nav_finished():
		return
	var away := global_position - from_pos
	away.y = 0.0
	if away.length_squared() < 0.001:
		away = Vector3(cos(_heading), 0.0, sin(_heading))
	away = away.normalized()
	# M1: si la esfera tiene grupo y el centroide está del lado contrario a la
	# amenaza, sesgar la huida HACIA los suyos (retirada a la manada) en vez de
	# huir a ciegas. El abanico de probes de abajo sigue garantizando navegabilidad.
	# Defensa de crías: una cría de un grupo con nido se refugia en el nido, no en el
	# centroide (mismo sesgo y misma guarda de no huir hacia la amenaza).
	var base_dir := away
	if group_id != -1 and Groups.has_group(group_id):
		var centroid: Vector3 = Groups.get_centroid(group_id)
		if Groups.is_cub(self):
			var nest_pos: Vector3 = Groups.get_nest_position(group_id)
			if nest_pos.x != INF:
				centroid = nest_pos
		if centroid.x != INF:
			var to_c := centroid - global_position
			to_c.y = 0.0
			# Solo si el grupo NO está hacia la amenaza (dot > 0), para no huir
			# hacia el peligro por querer reunirse.
			if to_c.length_squared() > 0.25 and to_c.normalized().dot(away) > 0.0:
				var k: float = GlobalParams.tuning.flee_to_group_bias
				var blended := away * (1.0 - k) + to_c.normalized() * k
				if blended.length_squared() > 0.001:
					base_dir = blended.normalized()
	var nav_map := _nav_map()
	if not nav_map.is_valid():
		var ft := global_position + base_dir * 15.0
		ft.x = clampf(ft.x, -world_bounds.x * 0.5 + 1.0, world_bounds.x * 0.5 - 1.0)
		ft.z = clampf(ft.z, -world_bounds.y * 0.5 + 1.0, world_bounds.y * 0.5 - 1.0)
		_set_nav_path(ft)
		return
	# Probar el rumbo de huida ideal y, si el navmesh no ofrece un destino
	# alcanzable por ahí (borde de isla, ladera cortada por el bake, esquina),
	# abrir el abanico a ±45°, ±90° y 180° para deslizar a lo largo del
	# obstáculo en vez de quedarse clavada con el destino colapsado encima.
	var base_angle := atan2(base_dir.z, base_dir.x)
	for offset in [0.0, PI * 0.25, -PI * 0.25, PI * 0.5, -PI * 0.5, PI]:
		var ang: float = base_angle + offset
		var ft := global_position + Vector3(cos(ang), 0.0, sin(ang)) * 15.0
		ft.x = clampf(ft.x, -world_bounds.x * 0.5 + 1.0, world_bounds.x * 0.5 - 1.0)
		ft.z = clampf(ft.z, -world_bounds.y * 0.5 + 1.0, world_bounds.y * 0.5 - 1.0)
		var snapped := NavigationServer3D.map_get_closest_point(nav_map, _flat(ft))
		# Destino colapsado sobre la posición actual: ese rumbo no escapa (XZ).
		if _xz_dist(global_position, snapped) < 1.0:
			continue
		# Destino en otra isla de navmesh: map_get_path devuelve ≤1 punto.
		var path := NavigationServer3D.map_get_path(nav_map, _flat(global_position), snapped, false)
		if path.size() > 1:
			_nav_path = path
			_nav_path_idx = 0
			_nav_goal = snapped
			return
	# Ningún rumbo de huida es navegable: deambular para despegarse del sitio.
	_wander(_dt_sim, true)


func _enforce_bounds() -> void:
	# El navmesh contiene las esferas dentro del plano; solo se comprueba Y
	# por si la esfera escapa del collider del terreno durante un flee rápido.
	if _world == null:
		return
	var floor_y: float = _world.get_terrain_height(global_position.x, global_position.z)
	if global_position.y < floor_y - 2.0:
		global_position.y = floor_y + 0.5
		velocity.y = 0.0
	# Montada encima de otra esfera: en reposo el origen está ~0.5 m sobre el
	# terreno; apilada queda ~1.5 m. Si supera 1.0 m, empujarla horizontalmente
	# lejos de la esfera más cercana para que resbale y la gravedad la asiente,
	# en vez de dejar a ambas atascadas en una pila.
	elif global_position.y > floor_y + 1.0:
		var nearest: Node3D = null
		var best_d: float = INF
		for n in SpatialIndex.query_spheres(global_position, 1.2):
			if n == self or not is_instance_valid(n):
				continue
			var d: float = global_position.distance_squared_to(n.global_position)
			if d < best_d:
				best_d = d
				nearest = n
		if nearest != null:
			var push := global_position - nearest.global_position
			push.y = 0.0
			if push.length_squared() < 0.01:
				push = Vector3(cos(_heading), 0.0, sin(_heading))
			global_position += push.normalized() * 0.35
	# Contención lateral: normalmente el pathfinding mantiene a las esferas
	# dentro del mundo, pero un empujón físico (de-stack, colisión) puede
	# sacarlas fuera del navmesh sin retorno posible. Clamp duro de seguridad
	# que además rescata a cualquier esfera que ya se haya escapado.
	var half_x: float = world_bounds.x * 0.5 - 1.0
	var half_z: float = world_bounds.y * 0.5 - 1.0
	global_position.x = clampf(global_position.x, -half_x, half_x)
	global_position.z = clampf(global_position.z, -half_z, half_z)


## Proyecta `pos` al punto transitable más cercano del navmesh (consulta aplanada a
## Y=0) y devuelve ese punto a la altura del TERRENO, para que quien lo consuma con
## distancias 3D (p. ej. el `_migrate_target`) siga funcionando.
func _snap_to_nav(pos: Vector3) -> Vector3:
	var nav_map := _nav_map()
	if not nav_map.is_valid():
		return pos
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, _flat(pos))
	if _world != null:
		snapped.y = _world.get_terrain_height(snapped.x, snapped.z) + 0.5
	return snapped


## ¿El target es alcanzable desde la posición actual?
## Comprueba (1) que el snap al navmesh está cerca del target real y
## (2) que existe ruta real desde nuestra posición. Solo (1) no basta:
## un target puede estar tocando el navmesh pero en una sub-zona sin
## conexión desde donde estamos (rodeada por agua, cuello estrecho,
## bake fragmentado). En ese caso la esfera persigue indefinidamente
## sin avanzar (caso "Mo Lun" — sesión 2026-05-20).
const REACHABILITY_TOLERANCE: float = 1.0

func _is_target_reachable(target_pos: Vector3) -> bool:
	var nav_map := _nav_map()
	if not nav_map.is_valid() or NavigationServer3D.map_get_iteration_id(nav_map) == 0:
		return true  # mapa aún no sincronizado: no filtrar (graceful start)
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, _flat(target_pos))
	if Vector2(snapped.x - target_pos.x, snapped.z - target_pos.z).length() > REACHABILITY_TOLERANCE:
		return false
	# Navmesh conexo (1 sola isla): si el destino está sobre el navmesh (snap
	# cercano), existe ruta por definición. Nos ahorramos el `map_get_path`
	# —la consulta más cara y llamada muchas veces por decisión—. El check de
	# ruta solo aporta en navmesh FRAGMENTADO (islas inconexas, caso "Mo Lun"),
	# donde sí se ejecuta el camino completo de abajo.
	if _world != null and _world.navmesh_connected:
		return true
	# Ruta real: map_get_path devuelve ≤1 punto cuando origen y destino
	# están en componentes desconectados del navmesh (aunque ambos sean
	# alcanzables localmente).
	var path: PackedVector3Array = NavigationServer3D.map_get_path(nav_map, _flat(global_position), snapped, false)
	return path.size() > 1


## Marca la planta actual como inalcanzable, suelta el target y emite log.
## Se ejecuta cuando el detector de progreso confirma atasco (la heurística
## estática `_is_target_reachable` dijo "alcanzable" pero la realidad demuestra
## que no). La blacklist es por instancia y caduca tras `PLANT_BLACKLIST_TICKS`.
## Si la esfera no se ha movido NADA (seek_distance ≈ 0), se aplica un empujón
## físico: el navmesh ofrece path pero la esfera está bloqueada físicamente
## (apilamiento, colisión persistente). Sin el nudge la esfera reelige planta
## tras planta sin desbloquearse — caso "Ily Nox" — sesión 2026-05-20.
func _blacklist_current_plant() -> void:
	var pid: int = _target_plant.get_instance_id()
	var until: int = SimulationClock.get_tick_count() + PLANT_BLACKLIST_TICKS
	_plant_blacklist[pid] = until
	var completely_stuck: bool = _seek_food_distance < 0.1
	var species: String = String(genome.get("species", &"?"))
	EventLog.log_event(&"unreachable_plant", {
		"id": get_instance_id(),
		"sphere": full_name(),
		"plant_id": pid,
		"plant_pos": [_target_plant.global_position.x, _target_plant.global_position.y, _target_plant.global_position.z],
		"sphere_pos": [global_position.x, global_position.y, global_position.z],
		"seek_seconds": snappedf(_seek_food_seconds, 0.1),
		"seek_distance": snappedf(_seek_food_distance, 0.1),
		"blacklist_until_tick": until,
		"physical_block": completely_stuck,
	}, StringName("sphere_%s" % species))
	_target_plant = null
	_food_rival = null
	_seek_food_seconds = 0.0
	_seek_food_distance = 0.0
	if completely_stuck:
		_try_unstuck_nudge()


## Empuja la esfera ~2 m a un punto cercano del navmesh con path real.
## Prueba 4 direcciones cardinales y se queda con la primera que ofrezca
## un destino distinto a la posición actual y conectado por path. Si ninguna
## funciona, no hace nada (la esfera no tiene escape; quedará al cuidado
## del rescue de `_enforce_bounds` o del wander de desesperación).
func _try_unstuck_nudge() -> void:
	var nav_map := _nav_map()
	if not nav_map.is_valid() or NavigationServer3D.map_get_iteration_id(nav_map) == 0:
		return
	for ang in [0.0, PI * 0.5, PI, PI * 1.5]:
		var probe: Vector3 = global_position + Vector3(cos(ang), 0.0, sin(ang)) * 2.0
		var snapped: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, _flat(probe))
		var d: float = _xz_dist(global_position, snapped)
		if d < 0.5 or d > 5.0:
			continue
		var path: PackedVector3Array = NavigationServer3D.map_get_path(nav_map, _flat(global_position), snapped, false)
		if path.size() > 1:
			global_position.x = snapped.x
			global_position.z = snapped.z
			velocity = Vector3.ZERO
			return


# ---------------- INTERACCIONES ----------------

func _eat(plant: Node3D) -> void:
	if not is_instance_valid(plant):
		return
	if plant.has_method("register_visit"):
		plant.register_visit()
	# Posición de lo comido (planta o cadáver) antes de `consume`, que puede liberarlo.
	var from: Vector3 = plant.global_position
	var gained: float = plant.consume()
	if gained > 0.0:
		energy = minf(MAX_ENERGY, energy + gained)
		_eat_count += 1
		EventLog.log_event(&"eat", {"id": get_instance_id(), "sphere": full_name(), "energy": energy,
				"from": [snappedf(from.x, 0.01), snappedf(from.y, 0.01), snappedf(from.z, 0.01)]},
			StringName("sphere_%s" % String(genome.get("species", &"?"))))
		# Comida de granja ajena: si la relación con el dueño es buena, es COMPARTIR
		# (sube amistad); si no, es ROBO (penaliza, una sola vez por planta).
		if plant is Plant:
			var owner: int = plant.owner_group_id
			if owner != -1 and owner != group_id and Groups.has_group(owner):
				if _relationship_to_owner(owner) >= GlobalParams.tuning.farm_share_affinity:
					Groups.register_share(owner, self)
				elif not plant.theft_charged:
					plant.theft_charged = true
					Groups.register_theft(owner, self)
	else:
		_target_plant = null


## Puede reproducirse YA (no mira energía ni afinidad: esas tienen su propio chequeo).
## Gate único para acción, factibilidad de seek_mate y elección de pareja, para que
## los tres digan lo mismo (si no, el joven corteja y falla al llegar una y otra vez).
## La madurez es fracción de la longevidad y no una edad absoluta: `longevity` es
## heredable y una edad fija premiaría evolucionar longevidades cortas (madurar
## antes sin coste). Ver docs: Plan - Fidelidad de la Simulación (M2).
func can_reproduce() -> bool:
	if reproduction_cooldown > 0.0:
		return false
	if health < MAX_HEALTH * GlobalParams.tuning.repro_min_health_01:
		return false
	return age / maxf(_t_longevity, 1.0) >= GlobalParams.tuning.repro_maturity_01


func _attempt_reproduction(mate: Sphere) -> void:
	if not can_reproduce() or not mate.can_reproduce():
		return
	if energy < REPRO_ENERGY_COST + 20.0 or mate.energy < REPRO_ENERGY_COST + 20.0:
		return
	var affinity: float = Relationships.get_affinity(get_instance_id(), mate.get_instance_id())
	if affinity < REPRO_AFFINITY_THRESHOLD:
		Relationships.adjust(get_instance_id(), mate.get_instance_id(), 1.5)
		return
	# Tope de población: por encima del cap no nace cría (y no se cobra a los
	# padres). El conteo del grupo es O(n) pero la reproducción que llega aquí es
	# infrecuente (cooldown de 20 s), igual que el cap de plantas.
	if get_tree().get_nodes_in_group(&"spheres").size() >= SPHERE_CAP:
		return
	energy -= REPRO_ENERGY_COST
	mate.energy -= REPRO_ENERGY_COST
	reproduction_cooldown = REPRO_COOLDOWN
	mate.reproduction_cooldown = REPRO_COOLDOWN
	var stress_avg: float = (stress + mate.stress) * 0.5
	var age_avg: float = 0.5 * (
		age / maxf(float(genome.get("longevity", 120.0)), 1.0)
		+ mate.age / maxf(float(mate.genome.get("longevity", 120.0)), 1.0)
	)
	# Dónde nace la cría ANTES del cruce: su bioma de nacimiento es el del punto
	# de nacimiento, no el de un progenitor (ruido en las fronteras).
	var mid_pos := (global_position + mate.global_position) * 0.5
	# Desplazar al hijo perpendicularmente al eje de los padres: nacer en el
	# punto medio lo dejaba solapado dentro de los colliders de ambos (radio
	# 0.5 c/u) y la cría acababa montada encima de un progenitor y atascada.
	var axis := mate.global_position - global_position
	axis.y = 0.0
	var perp := Vector3(-axis.z, 0.0, axis.x)
	if perp.length_squared() < 0.01:
		perp = Vector3(1.0, 0.0, 0.0)
	perp = perp.normalized() * (1.0 if _rng.randf() < 0.5 else -1.0)
	var spawn_xz := mid_pos + perp * 1.4
	spawn_xz.x = clampf(spawn_xz.x, -world_bounds.x * 0.5 + 1.0, world_bounds.x * 0.5 - 1.0)
	spawn_xz.z = clampf(spawn_xz.z, -world_bounds.y * 0.5 + 1.0, world_bounds.y * 0.5 - 1.0)
	var birth_biome: int = Biomes.biome_at(spawn_xz)
	var child_genome: Dictionary = Genetics.cross(genome, mate.genome, stress_avg, age_avg, birth_biome)
	# `last_sigma` es estado compartido del autoload: se lee ya, pegado al cruce.
	var birth_sigma: float = Genetics.last_sigma
	var child: Sphere = preload("res://entities/Sphere.tscn").instantiate()
	get_parent().add_child(child)
	# Y al nivel del progenitor más alto: la gravedad lo asienta sobre el
	# terreno sin nacer flotando encima de los padres.
	child.global_position = Vector3(spawn_xz.x, maxf(global_position.y, mate.global_position.y), spawn_xz.z)
	child.setup(child_genome, world_bounds, max(generation, mate.generation) + 1)
	child.activate()
	_seed_newborn_social(child, mate)
	Relationships.adjust(get_instance_id(), mate.get_instance_id(), 5.0)
	EventLog.log_event(&"birth", {
		"id": child.get_instance_id(),
		"parent_a": full_name(),
		"parent_b": mate.full_name(),
		# instance_id de los padres: EffectsDirector los resuelve para los corazones.
		"parent_a_id": get_instance_id(),
		"parent_b_id": mate.get_instance_id(),
		"child": child.full_name(),
		"generation": child.generation,
		"biome": String(Biomes.BIOME_KEYS[birth_biome]),
		"sigma": birth_sigma,
		"size": float(child_genome.get("size", 0.0)),
		"speed": float(child_genome.get("speed", 0.0)),
		"vision": float(child_genome.get("vision", 0.0)),
		"metabolism": float(child_genome.get("metabolism", 0.0)),
		"longevity": float(child_genome.get("longevity", 0.0)),
	}, StringName("sphere_%s" % String(genome.get("species", &"?"))))
	born.emit(child)


## Da a la cría su lugar social al nacer: afinidad ALTA hacia ambos progenitores y
## herencia del grupo de uno de ellos (con afinidad levemente alta hacia el resto
## de miembros). Sin esto la cría nacía neutral (0) con todos y no podía agruparse
## con su propia familia hasta ganarse la afinidad desde cero. Los vínculos son
## mutuos (`adjust` toca ambas direcciones): la afinidad ENTRANTE evita que el
## grupo expulse al recién nacido (`GroupSystem._expel_disliked`) y alimenta su
## cohesión.
func _seed_newborn_social(child: Sphere, mate: Sphere) -> void:
	var cid: int = child.get_instance_id()
	var parent_aff: float = GlobalParams.tuning.birth_parent_affinity
	Relationships.adjust(cid, get_instance_id(), parent_aff)
	Relationships.adjust(cid, mate.get_instance_id(), parent_aff)

	# Hereda el grupo de un progenitor que siga existiendo (el propio primero).
	var child_group: int = -1
	if group_id != -1 and Groups.has_group(group_id):
		child_group = group_id
	elif mate.group_id != -1 and Groups.has_group(mate.group_id):
		child_group = mate.group_id
	if child_group == -1:
		return

	child.group_id = child_group
	Groups.register_member(child_group, child)
	child._refresh_group_tag()
	# Afinidad levemente alta con los compañeros de grupo (saltando a los padres,
	# ya vinculados al nivel "alto", y a la propia cría).
	var group_aff: float = GlobalParams.tuning.birth_group_affinity
	for m in Groups.get_members(child_group):
		if m == self or m == mate or m == child:
			continue
		Relationships.adjust(cid, m.get_instance_id(), group_aff)


func _attack(target: Sphere, dt_sim: float) -> void:
	if not is_instance_valid(target):
		return
	var my_power: float = _combat_power()
	var their_power: float = target._combat_power()
	var damage: float = (my_power / maxf(their_power, 0.1)) * 12.0 * dt_sim
	target.health -= damage
	target.stress = clampf(target.stress + STRESS_FROM_COMBAT * dt_sim, 0.0, 100.0)
	target._last_attacker_id = get_instance_id()
	Relationships.adjust(get_instance_id(), target.get_instance_id(), -2.5 * dt_sim)
	stress = clampf(stress + STRESS_FROM_COMBAT * 0.3 * dt_sim, 0.0, 100.0)
	# Reacción de vecinos: testigos pueden intervenir defendiendo a la víctima.
	target._call_for_help(self)


func _call_for_help(attacker: Sphere) -> void:
	## Avisa a vecinos cercanos para que evalúen intervenir.
	## Cada testigo decide en función de afinidad con la víctima, grupo,
	## valentía y salud propia. Si interviene, marca al atacante como
	## su `_fight_target` y degrada la relación.
	var size: float = float(genome.get("size", 1.0))
	var age_01: float = clampf(age / float(genome.get("longevity", 120.0)), 0.0, 1.0)
	var vision_base: float = float(genome.get("vision", 6.0))
	var vision_eff: float = vision_base * (0.8 + 0.4 * size) * (1.0 + 0.3 * (1.0 - age_01))
	var witness_radius: float = vision_eff * _env_mod(&"vision_mod")
	for n in SpatialIndex.query_spheres(global_position, witness_radius):
		if n == self or n == attacker or not (n is Sphere) or not n._alive:
			continue
		var affinity_to_victim: float = Relationships.get_affinity(
			n.get_instance_id(), get_instance_id())
		var same_group: bool = group_id != -1 and n.group_id == group_id
		var bond: float = affinity_to_victim
		if same_group:
			bond += 30.0
		if bond < 10.0:
			continue
		var bravery: float = float(n.genome.get("bravery", 0.5))
		var health_ratio: float = n.health / MAX_HEALTH
		if bravery * health_ratio < 0.35:
			continue
		# Interviene.
		n._fight_target = attacker
		n._last_attacker_id = attacker.get_instance_id()
		Relationships.adjust(n.get_instance_id(), attacker.get_instance_id(), -1.5)
		Relationships.adjust(n.get_instance_id(), get_instance_id(), 0.8)


func _combat_power() -> float:
	var size: float = float(genome.get("size", 1.0))
	var bravery: float = float(genome.get("bravery", 0.5))
	# El arma multiplica el poder de combate (afecta al daño que inflige y a cómo
	# de fuerte la perciben los demás). Persiste hasta la muerte.
	var weapon: float = 1.0 + float(weapon_level) * GlobalParams.tuning.weapon_damage_mult
	return size * (0.5 + 0.5 * health / MAX_HEALTH) * (0.7 + 0.6 * bravery) * weapon


## Inflige daño de estructura a una granja enemiga. El daño escala con el poder de
## combate (el arma cuenta) por el multiplicador de daño a estructuras. La granja no
## se defiende ni llama a testigos (no es un ser).
func _attack_farm(farm: Node3D, dt_sim: float) -> void:
	if not is_instance_valid(farm):
		return
	var damage: float = _combat_power() * GlobalParams.tuning.farm_attack_damage_mult * dt_sim
	farm.take_damage(damage, self)


# ---------------- SENSADO ----------------

## ¿Es `node` una fuente de comida consumible ahora mismo? Planta madura con
## bocados, o cadáver con bocados. Único criterio de comestibilidad — lo usan
## tanto la selección de objetivo como la comprobación de compromiso.
func _is_edible(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node is Plant:
		return node.stage == Plant.Stage.MATURE and node.bites_left > 0
	if node is Corpse:
		return node.bites_left > 0
	return false


## Elige una planta a la que ir a comer teniendo en cuenta la DISPUTA del
## recurso. Para cada candidata (de la más cercana a la más lejana):
##  - sin contendientes, o con bocados de sobra para todos → se elige (comer
##    en paz / compartir);
##  - recurso escaso y disputado → según la predisposición a disputar
##    (agresividad × urgencia de hambre × ventaja física × especie) la esfera
##    LUCHA por él (fija `_food_rival`) o CEDE y prueba la siguiente planta.
## Reparte la población entre plantas y evita que todas se amontonen en una.
func _pick_food_target(plants: Array) -> Node3D:
	var edible: Array = []
	var current_tick: int = SimulationClock.get_tick_count()
	for p in plants:
		var pid: int = p.get_instance_id()
		# Filtro blacklist: plantas marcadas como inalcanzables tras un atasco
		# real (no solo por la heurística estática). Auto-purga cuando caduca.
		if _plant_blacklist.has(pid):
			if _plant_blacklist[pid] > current_tick:
				continue
			_plant_blacklist.erase(pid)
		if not _is_edible(p):
			continue
		# Conciencia de propiedad: una planta de la granja de OTRO grupo se evita
		# (no entra en la lista) salvo que la esfera esté dispuesta a tomarla
		# (hambre, valentía o buena relación con el dueño → sería compartir).
		if p is Plant and p.owner_group_id != -1 and p.owner_group_id != group_id \
				and not _willing_to_take_foreign(p.owner_group_id):
			continue
		edible.append(p)
	# Penalización territorial: una planta en zona rival "parece" más lejos, así
	# se prefiere forrajear en zona propia/neutral salvo que el hambre o la
	# valentía lo compensen (coste blando; ver TerritorySystem). Solo se paga la
	# consulta cuando esa penalización es no nula.
	var terr_avoid: float = GlobalParams.tuning.territory_food_avoid \
		* (1.0 - float(genome.get("bravery", 0.5))) \
		* clampf(energy / MAX_ENERGY, 0.0, 1.0)
	#
	# Rendimiento: en vez de ordenar `edible` entero (sort_custom con lambda, caro
	# en GDScript) y recorrerlo, se sacan las candidatas una a una por mínimo de la
	# MISMA clave que usaba el comparador (precalculada; nada en el bucle mueve
	# esferas ni plantas). Casi siempre basta la primera. Es idéntico al sort
	# mientras cada mínimo extraído sea ÚNICO: entonces cualquier ordenación
	# correcta lo pone en esa misma posición. Si aparece un empate (o un NaN), el
	# orden entre empatadas depende del algoritmo no estable de Godot: ahí se
	# ordena `edible` (aún en su orden original) con el comparador de siempre y se
	# sigue desde la misma posición, cuyo prefijo coincide por lo anterior.
	var n_edible: int = edible.size()
	var keys: PackedFloat64Array = PackedFloat64Array()
	keys.resize(n_edible)
	var sort_by_eff: bool = terr_avoid > 0.0
	var eff: Dictionary = {}
	if sort_by_eff:
		var sp: StringName = StringName(genome.get("species", &""))
		for p in edible:
			eff[p.get_instance_id()] = global_position.distance_to(p.global_position) \
				* (1.0 + TerritorySystem.rival_pressure_at(p.global_position, sp, group_id) * terr_avoid)
		for i in n_edible:
			keys[i] = float(eff[edible[i].get_instance_id()])
	else:
		for i in n_edible:
			keys[i] = global_position.distance_squared_to(edible[i].global_position)
	var taken: PackedByteArray = PackedByteArray()
	taken.resize(n_edible)
	taken.fill(0)
	var sorted_mode: bool = false
	var pos: int = 0
	_food_rival = null
	var fallback: Node3D = null
	var examined: int = 0
	var my_id: int = get_instance_id()
	while pos < n_edible:
		var p = null
		if not sorted_mode:
			var best_i: int = -1
			var best_k: float = INF
			var tie: bool = false
			for i in n_edible:
				if taken[i] != 0:
					continue
				var k: float = keys[i]
				if is_nan(k):
					tie = true
					break
				if k < best_k:
					best_k = k
					best_i = i
					tie = false
				elif k == best_k:
					tie = true
			if tie or best_i == -1:
				sorted_mode = true
				if sort_by_eff:
					edible.sort_custom(func(a, b):
						return float(eff[a.get_instance_id()]) < float(eff[b.get_instance_id()]))
				else:
					edible.sort_custom(_closer_plant)
			else:
				taken[best_i] = 1
				p = edible[best_i]
		if sorted_mode:
			p = edible[pos]
		pos += 1
		# Alcanzabilidad evaluada AQUÍ (no al construir `edible`): solo se paga
		# para las plantas más cercanas que realmente consideramos, no para
		# todas las visibles. Filtra plantas con el path bloqueado por el
		# navmesh; es best-effort, el detector de progreso de _on_tick atrapa
		# los falsos positivos.
		if not _is_target_reachable(p.global_position):
			continue
		if fallback == null:
			fallback = p
		examined += 1
		if examined > 5:
			break  # acotar coste: basta examinar las más cercanas
		var contenders: Array = _food_contenders(p)
		# Sin disputa, o quedan bocados para todos los que corren a por ella.
		if contenders.is_empty() or p.bites_left > contenders.size():
			# Compartir comida: reconoce a los que ya estaban como compañeros
			# pacíficos. Una sola dirección — el otro tampoco se entera de que
			# está "compartiendo", solo está comiendo. Pequeño y acumulativo.
			for n in contenders:
				Relationships.adjust_one_way(my_id, n.get_instance_id(), 0.3)
			return p
		# Recurso disputado y escaso: ¿luchar por él o ceder y buscar otro?
		var rival: Sphere = contenders[0]  # el más próximo a la planta
		if _contest_willingness(rival) >= GlobalParams.tuning.contest_threshold:
			_food_rival = rival
			return p
		# Ceder: el cedente resiente al rival que le ha quitado el recurso.
		# Una sola dirección — el rival ni se entera de que "ganó". Acumulativo
		# en encuentros repetidos: una esfera siempre apartada acaba odiando al
		# matón crónico aunque no llegue a pelear.
		Relationships.adjust_one_way(my_id, rival.get_instance_id(), -0.5)
		# Ceder: seguir buscando una planta menos disputada.
	return fallback


func _closer_plant(a: Node3D, b: Node3D) -> bool:
	return global_position.distance_squared_to(a.global_position) \
		< global_position.distance_squared_to(b.global_position)


## Esferas vivas que disputan `plant`: dentro del radio de disputa y más
## cerca de la planta que uno mismo (llegarían antes). Ordenadas por cercanía.
func _food_contenders(plant: Node3D) -> Array:
	var my_d: float = global_position.distance_to(plant.global_position)
	var out: Array = []
	for n in SpatialIndex.query_spheres(plant.global_position,
			GlobalParams.tuning.food_contention_radius):
		if n == self or not (n is Sphere) or not n._alive:
			continue
		if n.global_position.distance_to(plant.global_position) < my_d:
			out.append(n)
	out.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(plant.global_position) \
			< b.global_position.distance_squared_to(plant.global_position))
	return out


## Predisposición [0..1] a disputar un alimento frente a `rival`: combina
## agresividad, urgencia por el hambre, ventaja física (tamaño) y especie
## (entre especies distintas se disputa más; con la propia, algo de tolerancia).
func _contest_willingness(rival: Sphere) -> float:
	var aggression: float = float(genome.get("aggression", 0.5)) \
		* GlobalParams.aggression_modifier \
		* GlobalParams.get_species_mod(genome.get("species", &""), &"aggression")
	var hunger_01: float = clampf(1.0 - energy / MAX_ENERGY, 0.0, 1.0)
	var urgency: float = 0.5 + 0.5 * hunger_01
	var size_adv: float = clampf(_size_advantage_vs(rival) * 0.5 + 0.5, 0.0, 1.0)
	var species_factor: float = 1.0 if String(rival.genome.get("species", &"")) \
		!= String(genome.get("species", &"")) else 0.8
	return clampf(aggression * urgency * (0.4 + 0.6 * size_adv) * species_factor, 0.0, 1.0)




func _pick_strongest_threat(neighbors: Array, vision: float) -> Sphere:
	var best: Sphere = null
	# 0.6 silenciaba la valentía (amenazas típicas generaban ~0.13, nunca detectadas).
	# 0.25 provocó demasiado combate y colapso poblacional. 0.40 es el punto medio.
	var best_pressure: float = 0.40
	for n in neighbors:
		if n == self or not (n is Sphere) or not n._alive:
			continue
		var p: float = _threat_pressure(n, vision)
		if p > best_pressure:
			best_pressure = p
			best = n
	return best


func _threat_pressure(other: Sphere, vision: float) -> float:
	# Atenuación por distancia: una amenaza al borde de la visión presiona
	# mucho menos que una pegada. Sin esto, acercarse a una planta vigilada
	# dispara `flee` igual que estar encima del rival → thrash seek_food<->flee.
	var dist: float = global_position.distance_to(other.global_position)
	var falloff: float = clampf(1.0 - dist / maxf(vision, 0.1), 0.0, 1.0)
	if falloff <= 0.0:
		return 0.0
	if other.get_instance_id() == _last_attacker_id:
		return 1.5 * falloff
	# Rasgos del vecino desde la caché tipada (`_t_*`, fijada en `setup`): mismo
	# valor que `genome.get(...)` sin hashear strings por vecino y decisión.
	var aggression: float = other._t_aggression
	# Una esfera neutral (no atacante) sólo intimida si es claramente agresiva.
	if aggression < 0.55:
		return 0.0
	var size_ratio: float = other._t_size / maxf(_t_size, 0.1)
	var affinity: float = Relationships.get_affinity(get_instance_id(), other.get_instance_id())
	var amity: float = clampf((affinity + 100.0) / 200.0, 0.0, 1.0)
	return clampf(aggression * size_ratio * (1.0 - amity), 0.0, 2.0) * falloff


## ¿Sigue siendo `s` un objetivo-esfera vivo y dentro del radio de
## mantenimiento? Base de la banda de histéresis de adquisición de objetivos.
func _is_sphere_target_valid(s, keep_radius: float) -> bool:
	return s != null and is_instance_valid(s) and s is Sphere and s._alive \
		and global_position.distance_to(s.global_position) <= keep_radius


## ¿Sigue siendo `f` una granja-objetivo válida? Viva (vida > 0), de un grupo aún
## HOSTIL al mío y dentro del radio de mantenimiento (banda de histéresis).
func _is_farm_target_valid(f, keep_radius: float) -> bool:
	return f != null and is_instance_valid(f) and f is Farm and f.health > 0.0 \
		and group_id != -1 and f.group_id != -1 and f.group_id != group_id \
		and Groups.is_hostile(group_id, f.group_id) \
		and global_position.distance_to(f.global_position) <= keep_radius


## Elige la granja enemiga (de un grupo hostil) más cercana dentro de la visión y
## alcanzable. Pocas granjas en el mundo → recorrer el grupo de escena es trivial.
func _pick_enemy_farm(vision: float) -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for f in get_tree().get_nodes_in_group(&"farms"):
		if not is_instance_valid(f) or not (f is Farm) or f.health <= 0.0:
			continue
		if f.group_id == -1 or f.group_id == group_id \
				or not Groups.is_hostile(group_id, f.group_id):
			continue
		var d: float = global_position.distance_to(f.global_position)
		if d > vision or d >= best_d:
			continue
		# La query de navmesh (cara) se difiere al candidato que ya es el mejor.
		if _is_target_reachable(f.global_position):
			best_d = d
			best = f
	return best


## ¿Sigue `m` siendo una pareja viable? Objetivo-esfera válido + ambos pueden
## reproducirse (`can_reproduce()`) + misma especie.
func _is_mate_valid(m, keep_radius: float) -> bool:
	return _is_sphere_target_valid(m, keep_radius) \
		and can_reproduce() and m.can_reproduce() \
		and String(m.genome.get("species", &"")) == String(genome.get("species", &""))


func _pick_potential_mate(neighbors: Array) -> Sphere:
	if not can_reproduce():
		return null
	var best: Sphere = null
	var best_score: float = 0.0
	for n in neighbors:
		if n == self or not (n is Sphere) or not n._alive:
			continue
		if not n.can_reproduce():
			continue
		if String(n.genome.get("species", &"")) != String(genome.get("species", &"")):
			continue
		var affinity: float = Relationships.get_affinity(get_instance_id(), n.get_instance_id())
		var selectivity: float = float(genome.get("selectivity", 0.5))
		var distance: float = _trait_distance(n)
		var score: float = (affinity + 50.0) - selectivity * 60.0 * distance
		# La comprobación de navmesh (cara) solo se paga cuando el candidato supera al
		# mejor actual, no por cada vecino.
		if score > best_score and _is_target_reachable(n.global_position):
			best_score = score
			best = n
	return best


func _pick_fight_target(neighbors: Array) -> Sphere:
	var aggression: float = (
		_t_aggression
		* GlobalParams.aggression_modifier
		* GlobalParams.get_species_mod(genome.get("species", &""), &"aggression")
	)
	if aggression < 0.45:
		return null
	# Umbral de afinidad necesaria para atacar: las esferas muy agresivas
	# pueden iniciar combate con desconocidos (affinity≈0); las moderadas
	# solo atacan a quienes ya les tienen manía (affinity baja).
	# Rango: aggression 0.45 → threshold -5, aggression 1.0 → threshold 5.
	# (Antes era -10 → aggression 0.75 nunca superaba 0 y el combate no se activaba.)
	var fight_threshold: float = lerpf(-5.0, 5.0,
		clampf((aggression - 0.45) / 0.55, 0.0, 1.0))
	for n in neighbors:
		if n == self or not (n is Sphere) or not n._alive:
			continue
		var affinity: float = Relationships.get_affinity(get_instance_id(), n.get_instance_id())
		# Represalia solo si la relación no es muy positiva (sin atacar a aliados por accidente).
		var retaliate: bool = n.get_instance_id() == _last_attacker_id and affinity < 50.0
		# La comprobación de navmesh (cara) se difiere al candidato que YA cumple el
		# filtro de afinidad: así se paga ~1 query por decisión en vez de 1 por vecino.
		if (affinity < fight_threshold or retaliate) and _is_target_reachable(n.global_position):
			return n
	return null


func _size_advantage_vs(target: Sphere) -> float:
	if target == null:
		return 0.0
	var ratio: float = float(genome.get("size", 1.0)) / maxf(float(target.genome.get("size", 1.0)), 0.1)
	return clampf(ratio - 1.0, -1.0, 1.0)


func _trait_distance(other: Sphere) -> float:
	var keys: Array[String] = ["size", "speed", "vision", "metabolism"]
	var total: float = 0.0
	for k in keys:
		var va: float = float(genome.get(k, 0.0))
		var vb: float = float(other.genome.get(k, 0.0))
		var range_size: float = 1.0
		match k:
			"size": range_size = Traits.SIZE_MAX - Traits.SIZE_MIN
			"speed": range_size = Traits.SPEED_MAX - Traits.SPEED_MIN
			"vision": range_size = Traits.VISION_MAX - Traits.VISION_MIN
			"metabolism": range_size = Traits.METABOLISM_MAX - Traits.METABOLISM_MIN
		total += absf(va - vb) / range_size
	return total / float(keys.size())


# ---------------- GRUPOS ----------------

func _maybe_join_group(neighbors: Array) -> void:
	for n in neighbors:
		if n == self or not (n is Sphere) or not n._alive:
			continue
		if String(n.genome.get("species", &"")) != String(genome.get("species", &"")):
			continue
		var affinity: float = Relationships.get_affinity(get_instance_id(), n.get_instance_id())
		if affinity >= 5.0:
			# Grupo del vecino, o uno nuevo con id del contador de `Groups` (estable
			# entre procesos, ver `GroupSystem.new_group_id`).
			group_id = n.group_id if n.group_id != -1 else Groups.new_group_id()
			if n.group_id == -1:
				n.group_id = group_id
				Groups.register_member(group_id, n)
				n._refresh_group_tag()
			Groups.register_member(group_id, self)
			_refresh_group_tag()
			Relationships.adjust(get_instance_id(), n.get_instance_id(), 1.0)
			return


func _group_has_living_members(neighbors: Array) -> bool:
	for n in neighbors:
		if n == self or not (n is Sphere) or not n._alive:
			continue
		if n.group_id == group_id:
			return true
	return false


func _group_centroid() -> Vector3:
	var sum: Vector3 = Vector3.ZERO
	var count: int = 0
	var radius: float = float(genome.get("vision", 6.0)) * 1.5
	for n in SpatialIndex.query_spheres(global_position, radius):
		if n == self or not (n is Sphere) or not n._alive:
			continue
		if n.group_id == group_id:
			sum += n.global_position
			count += 1
	if count == 0:
		return Vector3(INF, INF, INF)
	return sum / float(count)


# ---------------- ECONOMÍA / RECURSOS ----------------

## Ingresa `amount` unidades de `type` recolectadas: a la bolsa común si la esfera
## está en un grupo, a su inventario personal si es loner.
func gain_resource(type: int, amount: int) -> void:
	if amount <= 0:
		return
	if group_id != -1 and Groups.has_group(group_id):
		Groups.add_to_pool(group_id, type, amount)
	else:
		inventory[type] = int(inventory.get(type, 0)) + amount


## Existencias disponibles de `type` desde el punto de vista de esta esfera
## (bolsa del grupo si es miembro, inventario propio si es loner).
func available_resource(type: int) -> int:
	if group_id != -1 and Groups.has_group(group_id):
		return Groups.pool_amount(group_id, type)
	return int(inventory.get(type, 0))


## Intenta pagar un coste `{type:amount}` de forma atómica (todo o nada) desde la
## bolsa del grupo o el inventario propio. Devuelve true si se pudo cobrar.
func pay_resources(costs: Dictionary) -> bool:
	if group_id != -1 and Groups.has_group(group_id):
		return Groups.pool_spend(group_id, costs)
	for t in costs:
		if int(inventory.get(t, 0)) < int(costs[t]):
			return false
	for t in costs:
		inventory[t] = int(inventory[t]) - int(costs[t])
	return true


## Oro personal acumulado en el inventario (0 para un miembro de grupo, cuyo oro
## ya está en la bolsa). Base del poder individual de un loner (ver paquete D).
func personal_gold() -> int:
	return int(inventory.get(ResourceNode.Type.GOLD, 0))


## Poder individual [0..1] derivado del oro personal (solo relevante para loners).
func individual_power() -> float:
	return clampf(float(personal_gold()) * GlobalParams.tuning.gold_power_scale, 0.0, 1.0)


## Un loner con oro irradia atracción: sube la afinidad de los vecinos HACIA él
## (una dirección), proporcional a su poder. Acumulativo a lo largo de los
## encuentros; clamp de afinidad evita que se dispare.
func _radiate_power_affinity(neighbors: Array) -> void:
	var power: float = individual_power()
	if power <= 0.0:
		return
	var delta: float = power * GlobalParams.tuning.power_affinity_weight * 0.1
	var my_id: int = get_instance_id()
	for n in neighbors:
		if n == self or not (n is Sphere) or not n._alive:
			continue
		Relationships.adjust_one_way(n.get_instance_id(), my_id, delta)


## Necesidad [0..1] de fabricar un arma: índice de baja supervivencia esperada en
## conflicto. Combina el riesgo presente (amenaza + rivalidad territorial) con la
## desventaja de poder frente a la amenaza, atenuado por las armas ya fabricadas.
## Un agente agresivo conserva un pequeño impulso preventivo aun sin amenaza.
func _weapon_need_01(threat, threat_pressure: float, terr_rival: float, aggression_eff: float) -> float:
	var risk: float = maxf(threat_pressure, terr_rival * 0.5)
	var disadvantage: float = 0.0
	if threat != null and is_instance_valid(threat):
		var their_p: float = threat._combat_power()
		var my_p: float = _combat_power()
		disadvantage = clampf(their_p / maxf(my_p, 0.1) - 1.0, 0.0, 1.0)
	var need: float = risk * (0.4 + 0.6 * disadvantage)
	# Impulso preventivo de los agresivos cuando no hay riesgo inmediato.
	need = maxf(need, aggression_eff * 0.15)
	# Cada arma ya fabricada sacia parte de la necesidad.
	need -= float(weapon_level) * GlobalParams.tuning.weapon_satiation
	return clampf(need, 0.0, 1.0)


## Nodo cosechable más cercano entre los tipos pedidos, dentro de `radius`.
func _pick_resource_target(types: Array, radius: float) -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for t in types:
		for n in SpatialIndex.query_resources(global_position, radius, t):
			if not _is_harvestable_node(n):
				continue
			var d: float = global_position.distance_squared_to((n as Node3D).global_position)
			if d < best_d:
				best_d = d
				best = n
	return best


func _is_harvestable_node(node) -> bool:
	return node != null and is_instance_valid(node) \
		and node is ResourceNode and node.is_harvestable()


## Extrae del nodo y deposita lo obtenido (bolsa del grupo o inventario propio).
func _harvest_node(node) -> void:
	if not _is_harvestable_node(node):
		_target_resource = null
		return
	var amount: float = node.harvest()
	if amount > 0.0:
		gain_resource(node.type, int(round(amount)))
		EventLog.log_event(&"gather", {
			"id": get_instance_id(),
			"sphere": full_name(),
			"resource": ResourceNode.type_name(node.type),
			"amount": amount,
		}, StringName("sphere_%s" % String(genome.get("species", &"?"))))
	if not _is_harvestable_node(node):
		_target_resource = null


## Fabrica un arma si la necesidad supera el umbral y hay recursos (de la bolsa del
## grupo o del inventario propio). Transacción instantánea, atómica.
func _maybe_craft_weapon(weapon_need: float) -> void:
	if weapon_level >= WEAPON_LEVEL_MAX:
		return
	if weapon_need < GlobalParams.tuning.weapon_craft_threshold:
		return
	var costs: Dictionary = {
		ResourceNode.Type.WOOD: GlobalParams.tuning.weapon_cost_wood,
		ResourceNode.Type.STONE: GlobalParams.tuning.weapon_cost_stone,
	}
	if not pay_resources(costs):
		return
	weapon_level += 1
	EventLog.log_event(&"weapon_crafted", {
		"id": get_instance_id(),
		"sphere": full_name(),
		"weapon_level": weapon_level,
		"group_id": group_id,
	}, StringName("sphere_%s" % String(genome.get("species", &"?"))))


## Relación de esta esfera con el grupo dueño de una granja: el máximo entre su
## afinidad individual hacia el líder dueño y la afinidad de grupo (si pertenece a
## uno). Base para decidir evitar/robar/compartir. ~0 si no hay trato previo.
func _relationship_to_owner(owner_gid: int) -> float:
	var rel: float = -100.0
	var leader = Groups.leader_of(owner_gid)
	if leader != null:
		rel = Relationships.get_affinity(get_instance_id(), leader.get_instance_id())
	if group_id != -1 and Groups.has_group(group_id):
		rel = maxf(rel, Groups.group_affinity(group_id, owner_gid))
	return rel


## ¿Está dispuesta a tomar comida de la granja del grupo `owner_gid`? Sí si la
## relación es buena (sería compartir), si pasa mucha hambre, o si es muy valiente.
func _willing_to_take_foreign(owner_gid: int) -> bool:
	if _relationship_to_owner(owner_gid) >= GlobalParams.tuning.farm_share_affinity:
		return true
	var hunger_01: float = clampf(1.0 - energy / MAX_ENERGY, 0.0, 1.0)
	if hunger_01 >= GlobalParams.tuning.farm_food_avoid_hunger:
		return true
	return float(genome.get("bravery", 0.5)) >= GlobalParams.tuning.farm_food_avoid_brave


# ---------------- VISUAL ----------------

# El feedback visual dinámico (flasheos por hambre/combate/cortejo) se ha
# retirado: confundía demasiado y diluia la identidad de color de cada
# familia. Si quisieras volver a meterlo, debe quedar tras un toggle y ser
# muy sutil. El color del cuerpo lo da el linaje + tamaño + forma por
# especie.


# ---------------- MUERTE ----------------

func _die(cause: StringName) -> void:
	if not _alive:
		return
	_alive = false
	SimulationClock.unregister_entity(self)
	if cause == &"combat" or cause == &"old_age":
		var parent: Node = get_parent()
		if parent != null:
			var color: Color = genome.get("color", Color(0.4, 0.25, 0.2))
			var size: float = float(genome.get("size", 1.0))
			Corpse.spawn(parent, global_position, color, size)
	var death_data: Dictionary = {
		"id": get_instance_id(),
		"sphere": full_name(),
		"cause": cause,
		"age": age,
		"generation": generation,
		"genome": genome,
		"position": [global_position.x, global_position.y, global_position.z],
		"energy": energy,
		"health": health,
		"stress": stress,
	}
	# Diagnóstico para muertes por hambre sin haber comido nunca: por qué
	# falló la alimentación (objetivo, distancia, navegación, comida cercana).
	if cause == &"hunger" and _eat_count == 0:
		var edible_near: int = 0
		var nearest: float = -1.0
		for p in SpatialIndex.query_plants(global_position, GlobalParams.tuning.food_search_radius):
			if _is_edible(p):
				edible_near += 1
				var pd: float = global_position.distance_to(p.global_position)
				if nearest < 0.0 or pd < nearest:
					nearest = pd
		var has_t: bool = _is_edible(_target_plant)
		var navtgt: Vector3 = _nav_goal if is_finite(_nav_goal.x) else Vector3.ZERO
		death_data["diag"] = {
			"action": BehaviorSystem.action_name(_current_action),
			"seek_food_s": snappedf(_seek_food_seconds, 0.1),
			"seek_food_dist": snappedf(_seek_food_distance, 0.1),
			"has_target": has_t,
			"target_dist": snappedf(global_position.distance_to(_target_plant.global_position), 0.1) if has_t else -1.0,
			"nav_finished": _nav_finished(),
			"navtgt_dist": snappedf(global_position.distance_to(navtgt), 0.1),
			"navtgt_to_plant": snappedf(navtgt.distance_to(_target_plant.global_position), 0.1) if has_t else -1.0,
			"edible_near": edible_near,
			"nearest_edible_dist": snappedf(nearest, 0.1),
		}
	EventLog.log_event(&"death", death_data,
		StringName("sphere_%s" % String(genome.get("species", &"?"))))
	died.emit(cause)
	# Fantasma de muerte: el director adopta el modelo (hijo de este nodo) ANTES del
	# queue_free y lo funde a gris 1 s. Sin director (headless) o sin presupuesto,
	# el modelo se libera con la esfera como siempre.
	if model != null and EffectsDirector.instance != null \
			and EffectsDirector.instance.adopt_dying_model(model, model.global_position):
		model = null
	queue_free()


# ---------------- GUARDADO ----------------
# Ver `SaveGame` y el plan «Guardado y Carga de Escenarios». Las referencias a otras
# entidades se guardan como ÍNDICE de save (posición en `entities`), no como
# `instance_id`, que cambia en cada proceso: `ids` traduce instance_id → índice al
# guardar y `node_of` índice → nodo al cargar. Un índice -1 = sin referencia.

## Foto de esta esfera para el save. No se guarda lo que se recalcula solo: la caché
## `_t_*` (la rehace `setup`), los mods por especie y el color (los rehacen
## `setup`/`_refresh_name_tag`).
func to_save(ids: Dictionary) -> Dictionary:
	return {
		"k": &"sphere",
		"pos": global_position,
		"genome": genome.duplicate(true),
		"generation": generation,
		"given_name": given_name,
		"energy": energy,
		"health": health,
		"stress": stress,
		"age": age,
		"reproduction_cooldown": reproduction_cooldown,
		"plague_time_left": _plague_time_left,
		"plague_course_s": _plague_course_s,
		"plague_frailty": _plague_frailty,
		"plague_strain": _plague_strain,
		"plague_immune_strain": _plague_immune_strain,
		"plague_contagion_acc": _plague_contagion_acc,
		"inventory": inventory.duplicate(),
		"weapon_level": weapon_level,
		# Tal cual: con el contador propio de grupos (M2) el id ya es estable.
		"group_id": group_id,
		"heading": _heading,
		"current_action": _current_action,
		"current_speed_mult": _current_speed_mult,
		"resource_scan_cooldown": _resource_scan_cooldown,
		"action_started_t": _action_started_t,
		"eat_count": _eat_count,
		"seek_food_seconds": _seek_food_seconds,
		"seek_food_distance": _seek_food_distance,
		"seek_food_last_pos": _seek_food_last_pos,
		"group_food_hint": _group_food_hint,
		"flee_from_pos": _flee_from_pos,
		"nav_path": _nav_path,
		"nav_path_idx": _nav_path_idx,
		"nav_goal": _nav_goal,
		# Los que `activate()` pisa: se sobrescriben después en `from_save`.
		"decision_cooldown": _decision_cooldown,
		"interp_from": _interp_from,
		"interp_to": _interp_to,
		"interp_tick": _interp_tick,
		# Objetivos de la IA como índice de save. Un objetivo ya liberado o que no entró
		# en la foto (muerto, en cola de borrado) se guarda como -1 (sin objetivo).
		"target_plant": _save_ref(_target_plant, ids),
		"target_resource": _save_ref(_target_resource, ids),
		"target_mate": _save_ref(_target_mate, ids),
		"fight_target": _save_ref(_fight_target, ids),
		"target_farm": _save_ref(_target_farm, ids),
		"food_rival": _save_ref(_food_rival, ids),
		"flee_target": _save_ref(_flee_target, ids),
		"last_attacker": int(ids.get(_last_attacker_id, -1)),
		"plant_blacklist": _save_blacklist(ids),
	}


## Índice de save de `n`, o -1 si no hay referencia o la entidad no está en la foto.
## `Variant` y no `Object`: un objetivo puede ser un objeto ya liberado, y pasarlo a un
## parámetro tipado es un error en tiempo de ejecución (la foto saldría vacía).
static func _save_ref(n: Variant, ids: Dictionary) -> int:
	if not is_instance_valid(n):
		return -1
	return int(ids.get((n as Object).get_instance_id(), -1))


## `_plant_blacklist` con las claves (id de planta) traducidas a índice de save. Las
## entradas de plantas que ya no están en la foto se descartan: no se pueden reelegir.
func _save_blacklist(ids: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for pid in _plant_blacklist:
		if ids.has(pid):
			out[int(ids[pid])] = int(_plant_blacklist[pid])
	return out


## Restaura esta esfera desde `to_save`. Precondición: ya está en el árbol (`add_child`
## hecho por `SaveGame.restore`) y `SimulationClock` ya tiene el `_tick_count` del save.
## Sigue la regla del plan: posición → `setup`/campos → `activate()` → sobrescribir lo
## que `activate()` pisa (`_decision_cooldown` desde el instance_id nuevo, `_interp_*`).
## `activate()` va aquí dentro para que `SaveGame.restore` llame a esto EN EL ORDEN
## guardado: el orden de registro en `SimulationClock._entities` es el de tick.
func from_save(d: Dictionary, node_of: Array) -> void:
	global_position = d.pos
	setup(Dictionary(d.genome).duplicate(true), world_bounds, int(d.generation))
	# `_ready` ya sorteó nombre y rumbo: se pisan con los guardados.
	given_name = String(d.given_name)
	energy = float(d.energy)
	health = float(d.health)
	stress = float(d.stress)
	age = float(d.age)
	reproduction_cooldown = float(d.reproduction_cooldown)
	# Sin `infect_plague`: restaurar no es infectar (ni se re-loguea `plague_infected`).
	_plague_time_left = float(d.get("plague_time_left", 0.0))
	_plague_course_s = float(d.get("plague_course_s", 0.0))
	_plague_frailty = float(d.get("plague_frailty", 0.0))
	_plague_strain = int(d.get("plague_strain", 0))
	_plague_immune_strain = int(d.get("plague_immune_strain", -1))
	_plague_contagion_acc = float(d.get("plague_contagion_acc", 0.0))
	inventory = Dictionary(d.inventory).duplicate()
	weapon_level = int(d.weapon_level)
	# Tal cual: `Groups.from_save` reconstruye los grupos después de todas las entidades
	# y recolorea a sus miembros (hasta entonces `get_group_name` da "").
	group_id = int(d.group_id)
	_heading = float(d.heading)
	_current_action = int(d.current_action)
	_current_speed_mult = float(d.current_speed_mult)
	_resource_scan_cooldown = float(d.resource_scan_cooldown)
	_action_started_t = float(d.action_started_t)
	_eat_count = int(d.eat_count)
	_seek_food_seconds = float(d.seek_food_seconds)
	_seek_food_distance = float(d.seek_food_distance)
	_seek_food_last_pos = d.seek_food_last_pos
	_group_food_hint = d.group_food_hint
	_flee_from_pos = d.flee_from_pos
	_nav_path = d.nav_path
	_nav_path_idx = int(d.nav_path_idx)
	_nav_goal = d.nav_goal
	# Objetivos: índice → nodo. `node_of` ya tiene TODAS las entidades instanciadas
	# (`SaveGame.restore` crea antes de restaurar), así que un objetivo con índice
	# mayor que esta esfera también resuelve, aunque aún no se haya activado.
	_target_plant = _node_at(node_of, int(d.target_plant)) as Node3D
	_target_resource = _node_at(node_of, int(d.target_resource)) as Node3D
	_target_mate = _node_at(node_of, int(d.target_mate)) as Sphere
	_fight_target = _node_at(node_of, int(d.fight_target)) as Sphere
	_target_farm = _node_at(node_of, int(d.target_farm)) as Node3D
	_food_rival = _node_at(node_of, int(d.food_rival)) as Sphere
	_flee_target = _node_at(node_of, int(d.flee_target)) as Sphere
	var attacker: Node = _node_at(node_of, int(d.last_attacker))
	_last_attacker_id = attacker.get_instance_id() if attacker != null else 0
	_plant_blacklist = {}
	var blacklist: Dictionary = d.plant_blacklist
	for idx in blacklist:
		var p: Node = _node_at(node_of, int(idx))
		if p != null:
			_plant_blacklist[p.get_instance_id()] = int(blacklist[idx])
	_refresh_name_tag()
	activate()
	_decision_cooldown = float(d.decision_cooldown)
	_interp_from = d.interp_from
	_interp_to = d.interp_to
	_interp_tick = int(d.interp_tick)


## Nodo del índice de save `idx`, o null si es -1, está fuera de rango o ya no es válido.
static func _node_at(node_of: Array, idx: int) -> Node:
	if idx < 0 or idx >= node_of.size():
		return null
	var n: Node = node_of[idx]
	return n if is_instance_valid(n) else null
