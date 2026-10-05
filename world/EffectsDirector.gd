class_name EffectsDirector
extends Node3D
## Despachador único de efectos visuales («juicy»). Hijo de `World`, que solo lo crea
## con pantalla: las herramientas headless no lo ven.
##
## Todo efecto pasa por `request()`, que aplica el nivel de `UserSettings`, el
## presupuesto (`max_alive` vivos y `per_frame` altas por frame) y, para los efectos
## constantes, el gate de distancia a la cámara o de esfera seleccionada. Cada tipo
## tiene un pool de `GPUParticles3D` one-shot con su `ParticleProcessMaterial` compartido.
##
## En `OFF` no hay ningún nodo de efecto: `request` sale antes de tocar nada, los pools
## no se rellenan y, si se cambia a `OFF` en caliente, los libres se liberan.
##
## Ver docs: docs/Planes/…/Plan - Game Feel y Efectos Juicy.md (Arquitectura, M2-M4).

## Lo leen Sphere y World sin buscar en el árbol. Null sin pantalla o fuera de partida.
static var instance: EffectsDirector = null

## Por nivel: efectos vivos máx., altas por frame, multiplicador de cantidad y distancia de
## los efectos constantes (0 = solo la esfera seleccionada). Sin entrada para OFF.
## `constant_dist = 0` en los tres: plan B de la 🔴, aplicado en M4 porque con 60 m
## (`high`) el bench a 100 esferas pasaba del +10 % sobre la base de M0.
const LEVELS: Dictionary = {
	UserSettings.EffectsIntensity.LOW:    {"max_alive": 8,  "per_frame": 2, "amount": 0.5, "constant_dist": 0.0},
	UserSettings.EffectsIntensity.MEDIUM: {"max_alive": 16, "per_frame": 4, "amount": 1.0, "constant_dist": 0.0},
	UserSettings.EffectsIntensity.HIGH:   {"max_alive": 32, "per_frame": 8, "amount": 1.5, "constant_dist": 0.0},
}
## Mayor `amount` de LEVELS: los emisores se crean con `base × esto` partículas y cada
## nivel usa `amount_ratio = amount / esto`, para no reasignar buffers al cambiar de nivel.
const MAX_AMOUNT_MULT: float = 1.5

## Efectos constantes (frecuentes): pasan por el gate de `constant_dist`. Los demás son
## ocasionales y solo los limita el presupuesto.
const CONSTANT_KINDS: Array[StringName] = [&"eat_motes", &"hit_sparks"]
## Radio (m) alrededor de la posición dibujada de la esfera seleccionada dentro del que un
## efecto constante se considera «suyo» y pasa el gate aunque `constant_dist` sea 0.
const SELECTED_FX_RADIUS: float = 3.0
## Tipos que viajan de `pos` a `to`: su emisor se estira en Z local (el eje que apunta a
## `to`) hasta la distancia, así la velocidad de la receta (en «tramos» por vida) los
## lleva de un punto al otro sin cambiar el tamaño del sprite. Ver `request`.
const TRAVEL_KINDS: Array[StringName] = [&"eat_motes"]
## Distancia mínima (m) del tramo de un tipo viajero (comer pegado a la planta).
const TRAVEL_MIN_DIST: float = 0.3

## Precalentamiento: bajo el centro del terreno. Queda dentro del frustum de la vista
## cenital (así se dibuja y compila el material) pero lo tapa el suelo.
const PREWARM_POS: Vector3 = Vector3(0.0, -50.0, 0.0)

## Tipos que no son partículas: anillo de grupo (`ImmediateMesh`) y fantasma de muerte
## (el modelo adoptado). Cuentan en el presupuesto igual que un emisor.
const RING_KIND: StringName = &"group_ring"
## Pulso de anillo al fundar un nido: mismo nodo que el de grupo, pero fijo en el nido.
const NEST_PULSE_KIND: StringName = &"nest_pulse"
const GHOST_KIND: StringName = &"death_ghost"
## Duraciones en tiempo REAL (s), no simulado.
const GHOST_S: float = 1.0
const RING_S: float = 1.5
## Pop-in del recién nacido sobre `fx_squash`: de casi 0 (0 exacto deja la Basis
## singular) a un sobrepaso y de vuelta a 1.
const POP_START: float = 0.01
const POP_OVERSHOOT: float = 1.15
const POP_UP_S: float = 0.22
const POP_SETTLE_S: float = 0.14
## Bounce al comer sobre `fx_squash`: se aplasta (ancho↑, alto↓) y vuelve a 1.
const BOUNCE_SQUASH: Vector3 = Vector3(1.12, 0.86, 1.12)
const BOUNCE_DOWN_S: float = 0.07
const BOUNCE_UP_S: float = 0.16
## Altura relativa (× altura visual) a la que llegan las motas de comer: la boca/pecho.
const EAT_TARGET_H: float = 0.6
## Altura (m) sobre la base de lo comido de la que salen las motas.
const EAT_FROM_H: float = 0.25
## Anillo de grupo: grosor radial, holgura sobre los fundadores, altura sobre los pies,
## crecimiento relativo durante el fundido y segmentos (como `GroupHighlight`).
const RING_WIDTH: float = 0.2
const RING_MARGIN: float = 0.7
const RING_Y: float = 0.08
const RING_GROW: float = 0.25
const RING_SEGMENTS: int = 32
## Pulso de nido: crece de la huella del domo a `nest_radius` (la zona «en el nido») en
## `NEST_PULSE_S` s de tiempo real, apagándose como el anillo de grupo.
const NEST_PULSE_S: float = 2.0
## Grosor radial del pulso de nido: con el radio del nido, el de grupo (`RING_WIDTH`)
## apenas se ve desde la vista cenital.
const NEST_PULSE_WIDTH: float = 0.6

## Recetas por tipo: kind → {"process": ParticleProcessMaterial, "mesh": Mesh,
## "base_amount": int, "lifetime": float}. Las registra `_register_kinds` (M3).
var _kinds: Dictionary = {}
## Emisores libres por tipo: kind → Array[GPUParticles3D].
var _pools: Dictionary = {}
## Nodos de efecto vivos (emitiendo), incluidos los fantasmas de muerte (M3).
var _alive: int = 0
## Altas en el frame `_budget_frame`.
var _spawned_this_frame: int = 0
var _budget_frame: int = -1
var _pooled_count: int = 0
var _prewarmed: bool = false
## Emisores en vuelo: {"p": GPUParticles3D, "until": msec en que vuelven al pool}.
var _emitting: Array[Dictionary] = []
## Fantasmas vivos: {"model": EntityModel, "t0": msec}.
var _ghosts: Array[Dictionary] = []
## Anillos vivos: {"node": MeshInstance3D, "color": Color, "t0": msec, "dur": s} y, o
## bien "members": Array (anillo de grupo, sigue a sus fundadores), o bien "center":
## Vector3 + "r0"/"r1"/"width": float (pulso fijo, p. ej. el del nido).
var _rings: Array[Dictionary] = []
## Material compartido de los anillos (color y alfa van por vértice).
var _ring_mat: StandardMaterial3D = null
## Cuántas veces se disparó cada tipo (diagnóstico; lo leen los conductores de prueba).
var fired: Dictionary = {}
## Cuántas veces se pidió cada tipo, pasara o no (diagnóstico de descartes, M4).
var requested: Dictionary = {}


func _enter_tree() -> void:
	instance = self


func _exit_tree() -> void:
	if instance == self:
		instance = null


func _ready() -> void:
	_register_kinds()
	EventLog.event_logged.connect(_on_event_logged)
	Relationships.bond_formed.connect(_on_bond_formed)
	if UserSettings.effects_intensity != UserSettings.EffectsIntensity.OFF:
		_prewarm()


func _process(_delta: float) -> void:
	# Cambio a OFF en caliente: los emisores libres sobran. Los vivos terminan solos y,
	# al volver al pool, se liberan aquí en un frame posterior.
	if _pooled_count > 0 and UserSettings.effects_intensity == UserSettings.EffectsIntensity.OFF:
		_purge_pools()
	if not _emitting.is_empty() or not _ghosts.is_empty() or not _rings.is_empty():
		var now: int = Time.get_ticks_msec()
		_update_emitting(now)
		_update_ghosts(now)
		_update_rings(now)


## Pide un efecto `kind` en `pos` (posición dibujada), escalado por `size` y orientado
## hacia `to` si es finito. Devuelve false si el nivel es OFF, se agotó el presupuesto,
## falla el gate de constantes o el tipo no existe.
func request(kind: StringName, pos: Vector3, size: float = 1.0, to: Vector3 = Vector3.INF) -> bool:
	requested[kind] = int(requested.get(kind, 0)) + 1
	var cfg: Dictionary = _budget()
	if cfg.is_empty():
		return false  # OFF o presupuesto agotado: no se toca nada
	if kind in CONSTANT_KINDS and not _passes_constant_gate(kind, pos, float(cfg["constant_dist"])):
		return false
	if not _kinds.has(kind):
		return false
	if not _prewarmed:
		_prewarm()  # se pasó de OFF a otro nivel en caliente
	var p: GPUParticles3D = _acquire(kind)
	p.amount_ratio = float(cfg["amount"]) / MAX_AMOUNT_MULT
	var b := Basis.IDENTITY
	var travel: float = 1.0
	if to.is_finite() and not to.is_equal_approx(pos):
		b = Basis.looking_at(to - pos, Vector3.UP if absf((to - pos).normalized().y) < 0.99 else Vector3.FORWARD)
		if kind in TRAVEL_KINDS:
			travel = maxf(TRAVEL_MIN_DIST, pos.distance_to(to))
	# El estirado va en ejes locales (Z) para no tocar el tamaño del sprite, que solo
	# depende de X/Y (`billboard_keep_scale`).
	p.global_transform = Transform3D(b * Basis.from_scale(Vector3(size, size, travel)), pos)
	_emit(p)
	_spawned_this_frame += 1
	_count(kind)
	return true


## Adopta el modelo de una esfera que muere para su fantasma de `GHOST_S` (tiempo real):
## lo cuelga de este nodo conservando su transform global (la posición dibujada; `_at`
## es esa misma posición, que ya trae el modelo) y lo frena y funde a gris en `_process`.
## False en OFF o sin presupuesto: entonces Sphere libera su modelo como siempre.
func adopt_dying_model(model: EntityModel, _at: Vector3) -> bool:
	if model == null or not model.is_inside_tree() or _budget().is_empty():
		return false
	# El halo de estado comparte `material_overlay` con la capa gris del fantasma:
	# se quita antes, y `set_halo` ya no lo vuelve a poner con el fantasma puesto.
	model.set_halo(-1)
	model.reparent(self, true)
	_alive += 1
	_spawned_this_frame += 1
	_ghosts.append({"model": model, "t0": Time.get_ticks_msec()})
	_count(GHOST_KIND)
	return true


## Configuración del nivel actual si queda presupuesto para un alta más en este frame;
## {} en OFF o con `max_alive`/`per_frame` agotados. Quien da el alta suma los contadores.
func _budget() -> Dictionary:
	var level: int = UserSettings.effects_intensity
	if not LEVELS.has(level):
		return {}
	var cfg: Dictionary = LEVELS[level]
	var frame: int = Engine.get_process_frames()
	if frame != _budget_frame:
		_budget_frame = frame
		_spawned_this_frame = 0
	if _alive >= int(cfg["max_alive"]) or _spawned_this_frame >= int(cfg["per_frame"]):
		return {}
	return cfg


func _count(kind: StringName) -> void:
	fired[kind] = int(fired.get(kind, 0)) + 1


# --- Gate de efectos constantes ---

## Las chispas solo son «de la seleccionada» si ella está peleando y el impacto es a
## su alcance: una pelea vecina dentro de `SELECTED_FX_RADIUS` no cuenta (visto en M4).
func _passes_constant_gate(kind: StringName, pos: Vector3, dist: float) -> bool:
	var sel: Sphere = Selection.current
	if sel != null and is_instance_valid(sel) and sel.model != null:
		var sp: Vector3 = sel.model.global_position
		if kind == &"hit_sparks":
			if sel._fight_target != null and is_instance_valid(sel._fight_target) \
					and Vector2(pos.x - sp.x, pos.z - sp.z).length() <= Sphere.FIGHT_REACH:
				return true
		elif sp.distance_to(pos) <= SELECTED_FX_RADIUS:
			return true
	return _passes_camera_gate(pos, dist)


## Parte de cámara del gate: dentro de `dist` y del frustum. False con `dist` ≤ 0.
func _passes_camera_gate(pos: Vector3, dist: float) -> bool:
	if dist <= 0.0:
		return false
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null or cam.global_position.distance_to(pos) > dist:
		return false
	return cam.is_position_in_frustum(pos)


# --- Pools ---

## Registra un tipo con su material de proceso compartido. Lo usarán M3/M4.
func _register_kind(kind: StringName, process: ParticleProcessMaterial, mesh: Mesh,
		base_amount: int, lifetime: float) -> void:
	_kinds[kind] = {"process": process, "mesh": mesh, "base_amount": base_amount,
		"lifetime": lifetime}
	_pools[kind] = []


func _acquire(kind: StringName) -> GPUParticles3D:
	var pool: Array = _pools[kind]
	if not pool.is_empty():
		_pooled_count -= 1
		return pool.pop_back()
	var r: Dictionary = _kinds[kind]
	var p := GPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.explosiveness = 1.0
	p.amount = maxi(1, ceili(int(r["base_amount"]) * MAX_AMOUNT_MULT))
	p.lifetime = float(r["lifetime"])
	p.process_material = r["process"]
	p.draw_pass_1 = r["mesh"]
	p.set_meta(&"fx_kind", kind)
	add_child(p)
	return p


## La vuelta al pool la decide el tiempo real (`_emitting`), no la señal `finished`: con
## `restart()` en el renderizador Compatibility no llegaba a emitirse y el presupuesto se
## agotaba para siempre (visto en la verificación de M3).
func _emit(p: GPUParticles3D) -> void:
	_alive += 1
	p.visible = true
	p.restart()
	p.emitting = true
	var ms: float = p.lifetime * (2.0 - p.explosiveness) * 1000.0 + 100.0
	_emitting.append({"p": p, "until": Time.get_ticks_msec() + int(ms)})


func _update_emitting(now: int) -> void:
	for i in range(_emitting.size() - 1, -1, -1):
		if now >= int(_emitting[i]["until"]):
			var p: GPUParticles3D = _emitting[i]["p"]
			_emitting.remove_at(i)
			_release(p)


func _release(p: GPUParticles3D) -> void:
	_alive = maxi(0, _alive - 1)
	p.emitting = false
	p.visible = false
	var kind: StringName = p.get_meta(&"fx_kind")
	if UserSettings.effects_intensity == UserSettings.EffectsIntensity.OFF or not _pools.has(kind):
		p.queue_free()
		return
	_pools[kind].append(p)
	_pooled_count += 1


func _purge_pools() -> void:
	for kind in _pools:
		for p in _pools[kind]:
			(p as Node).queue_free()
		_pools[kind] = []
	_pooled_count = 0
	_prewarmed = false


## Emite una vez cada tipo fuera de la vista para compilar sus shaders y que el primer
## efecto real no dé tirón. No cuenta como alta del frame. El anillo (sin test de
## profundidad: se vería a través del suelo) se precalienta con alfa 0, y la capa gris
## del fantasma con una caja bajo el terreno; ambos se liberan a los 0,5 s.
func _prewarm() -> void:
	_prewarmed = true
	for kind in _kinds:
		var p: GPUParticles3D = _acquire(kind)
		p.global_transform = Transform3D(Basis.IDENTITY, PREWARM_POS)
		_emit(p)
	var ring := _new_ring_node()
	var im := ring.mesh as ImmediateMesh
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in [Vector3.ZERO, Vector3.RIGHT, Vector3.BACK]:
		im.surface_set_color(Color(1.0, 1.0, 1.0, 0.0))
		im.surface_add_vertex(PREWARM_POS + v)
	im.surface_end()
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.material_override = EntityModel.make_ghost_overlay()
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(box)
	box.global_position = PREWARM_POS
	for n in [ring, box]:
		get_tree().create_timer(0.5).timeout.connect((n as Node).queue_free)


# --- Fuentes de eventos ---

func _on_event_logged(event: Dictionary) -> void:
	if not LEVELS.has(UserSettings.effects_intensity):
		return  # OFF: ni efectos ni pop-in
	match String(event.get("kind", "")):
		"birth":
			_on_birth(event.get("data", {}))
		"eat":
			_on_eat(event.get("data", {}))
		"group_formed":
			# Al emitirse solo está registrado el primer fundador (`Sphere._maybe_join_group`
			# registra al vecino y después a sí misma): se atiende al final del frame.
			_spawn_group_ring.call_deferred(int(event.get("data", {}).get("group_id", -1)))
		"nest_founded":
			_on_nest_founded(event.get("data", {}))


## Nido fundado: pulso de anillo del color del clan en la posición del nido. Se atiende
## en el momento (el grupo existe al emitirse, `GroupSystem._found_nest`). Salta el
## presupuesto (no el nivel: en OFF ya se salió arriba): es raro, unos pocos por partida,
## y a x16 las altas por frame se las comen los efectos constantes del mismo frame
## (visto en M4 de «Nidos y Asentamientos»: se perdía uno de cada pocos pulsos).
func _on_nest_founded(data: Dictionary) -> void:
	var p: Variant = data.get("position", null)
	var gid: int = int(data.get("group_id", -1))
	if not (p is Array and p.size() == 3) or not Groups.has_group(gid):
		return
	var center := Vector3(float(p[0]), float(p[1]), float(p[2]))
	_spawn_ring(NEST_PULSE_KIND, Groups.get_group_color(gid), NEST_PULSE_S, [], center,
		VisualScale.NEST_FOOTPRINT * 0.5, GlobalParams.tuning.nest_radius, NEST_PULSE_WIDTH, true)


## Nacimiento: corazones entre los padres, destello y pop-in en la cría.
func _on_birth(data: Dictionary) -> void:
	var child := instance_from_id(int(data.get("id", 0))) as Sphere
	var pa := instance_from_id(int(data.get("parent_a_id", 0))) as Sphere
	var pb := instance_from_id(int(data.get("parent_b_id", 0))) as Sphere
	if pa != null and pb != null:
		var mid: Vector3 = (_drawn_pos(pa) + _drawn_pos(pb)) * 0.5
		var h: float = maxf(pa.visual_height(), pb.visual_height())
		request(&"mate_hearts", mid + Vector3.UP * h * 0.8)
	if child == null:
		return
	request(&"birth_flash", _drawn_pos(child) + Vector3.UP * child.visual_height() * 0.5)
	# El pop-in es un Tween, no un nodo: no gasta presupuesto. Ligado a la cría para
	# que muera con ella.
	child.fx_squash = Vector3.ONE * POP_START
	var tw: Tween = _new_squash_tween(child)
	tw.set_meta(&"pop", true)
	tw.tween_property(child, ^"fx_squash", Vector3.ONE * POP_OVERSHOOT, POP_UP_S) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(child, ^"fx_squash", Vector3.ONE, POP_SETTLE_S) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_count(&"birth_pop")


## Comer: motas de lo comido (`from`) a la esfera y un bounce corto. Las motas pasan
## el gate de constantes en `request`; el bounce (un Tween, sin nodo ni presupuesto)
## sigue el mismo gate para que en LOW solo rebote la seleccionada.
func _on_eat(data: Dictionary) -> void:
	var s := instance_from_id(int(data.get("id", 0))) as Sphere
	var f: Variant = data.get("from", null)
	if s == null or not s._alive or s.model == null or not (f is Array and f.size() == 3):
		return
	# Aquí se conoce quién come: «de la seleccionada» es ella y no cualquiera que coma a
	# menos de `SELECTED_FX_RADIUS` (en grupo comen juntas). El resto, gate de cámara.
	var cfg: Dictionary = LEVELS.get(UserSettings.effects_intensity, {})
	var sel: Sphere = Selection.current
	if cfg.is_empty() or (s != sel and not _passes_camera_gate(_drawn_pos(s), float(cfg["constant_dist"]))):
		return
	var from := Vector3(float(f[0]), float(f[1]) + EAT_FROM_H, float(f[2]))
	var to: Vector3 = _drawn_pos(s) + Vector3.UP * s.visual_height() * EAT_TARGET_H
	request(&"eat_motes", from, 1.0, to)
	# No pisar un pop-in en curso: el recién nacido termina de aparecer primero.
	if s.fx_tween != null and s.fx_tween.is_valid() and s.fx_tween.is_running() \
			and s.fx_tween.has_meta(&"pop"):
		return
	var tw: Tween = _new_squash_tween(s)
	tw.tween_property(s, ^"fx_squash", BOUNCE_SQUASH, BOUNCE_DOWN_S) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, ^"fx_squash", Vector3.ONE, BOUNCE_UP_S) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_count(&"eat_bounce")


## Tween nuevo sobre `fx_squash`, ligado a la esfera (muere con ella). Mata el anterior
## para que dos no se peleen por la misma propiedad; quien compone (no pisar un pop-in)
## lo decide antes de llamar.
func _new_squash_tween(s: Sphere) -> Tween:
	if s.fx_tween != null and s.fx_tween.is_valid():
		s.fx_tween.kill()
	var tw: Tween = create_tween().bind_node(s)
	s.fx_tween = tw
	return tw


## Afinidad mutua alta: un brillo suave sobre cada una de las dos esferas.
func _on_bond_formed(a_id: int, b_id: int) -> void:
	if not LEVELS.has(UserSettings.effects_intensity):
		return
	for id in [a_id, b_id]:
		var s := instance_from_id(id) as Sphere
		if s != null and s._alive:
			request(&"bond_bloom", _drawn_pos(s) + Vector3.UP * s.visual_height() * 0.7)


## Posición dibujada (pies) de una esfera: la del modelo, que va interpolada.
func _drawn_pos(s: Sphere) -> Vector3:
	if s.model != null:
		return s.model.global_position
	return s.global_position - Vector3.UP * Sphere.MODEL_FEET_DROP


# --- Fantasma de muerte ---

func _update_ghosts(now: int) -> void:
	for i in range(_ghosts.size() - 1, -1, -1):
		var g: Dictionary = _ghosts[i]
		var m: EntityModel = g["model"]
		var t: float = (now - int(g["t0"])) / (GHOST_S * 1000.0)
		if t >= 1.0 or not is_instance_valid(m):
			if is_instance_valid(m):
				m.queue_free()
			_ghosts.remove_at(i)
			_alive = maxi(0, _alive - 1)
			continue
		m.set_anim_speed(1.0 - t)
		m.set_grey_fade(t)


# --- Anillo de grupo ---

## Anillo de luz alrededor de los fundadores de `group_id`, que se expande un poco y se
## apaga en `RING_S`. Diferido desde `group_formed` (ver `_on_event_logged`).
func _spawn_group_ring(group_id: int) -> void:
	if group_id == -1 or not Groups.has_group(group_id):
		return
	var members: Array = Groups.get_members(group_id)
	if members.is_empty():
		return
	_spawn_ring(RING_KIND, Groups.get_group_color(group_id), RING_S, members)


## Alta de un anillo con presupuesto (salvo `over_budget`, que solo cuenta como vivo).
## Con `members` sigue a esas esferas (anillo de grupo); sin ellos queda fijo en
## `center` y su radio va de `r0` a `r1` (pulso).
func _spawn_ring(kind: StringName, base_color: Color, dur: float, members: Array,
		center: Vector3 = Vector3.ZERO, r0: float = 0.0, r1: float = 0.0,
		width: float = RING_WIDTH, over_budget: bool = false) -> void:
	if not over_budget and _budget().is_empty():
		return
	_alive += 1
	_spawned_this_frame += 1
	var r: Dictionary = {"node": _new_ring_node(), "color": base_color.lerp(Color.WHITE, 0.45),
		"t0": Time.get_ticks_msec(), "dur": dur}
	if members.is_empty():
		r["center"] = center
		r["r0"] = r0
		r["r1"] = r1
		r["width"] = width
	else:
		r["members"] = members
	_rings.append(r)
	_count(kind)


func _new_ring_node() -> MeshInstance3D:
	if _ring_mat == null:
		# Mismo material que `GroupHighlight`: sin luz, por vértice y siempre visible.
		_ring_mat = StandardMaterial3D.new()
		_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_ring_mat.vertex_color_use_as_albedo = true
		_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ring_mat.no_depth_test = true
	var n := MeshInstance3D.new()
	n.mesh = ImmediateMesh.new()
	n.material_override = _ring_mat
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(n)
	return n


## Redibuja cada anillo siguiendo a sus fundadores (centro y radio desde sus posiciones
## dibujadas), creciendo y apagándose con el tiempo real.
func _update_rings(now: int) -> void:
	for i in range(_rings.size() - 1, -1, -1):
		var r: Dictionary = _rings[i]
		var node: MeshInstance3D = r["node"]
		var im := node.mesh as ImmediateMesh
		var k: float = (now - int(r["t0"])) / (float(r["dur"]) * 1000.0)
		var center := Vector3.ZERO
		var radius: float = 0.0
		var width: float = float(r.get("width", RING_WIDTH))
		var alive: bool = k < 1.0
		if alive and r.has("center"):
			# Pulso fijo: sale rápido y frena al llegar a `r1`.
			center = r["center"]
			radius = lerpf(float(r["r0"]), float(r["r1"]), 1.0 - (1.0 - k) * (1.0 - k))
		elif alive:
			var pts: Array[Vector3] = []
			var body_r: float = 0.0
			for m in r["members"]:
				if is_instance_valid(m) and m.model != null:
					pts.append(m.model.global_position)
					body_r = maxf(body_r, m.visual_ground_radius())
			alive = not pts.is_empty()
			for p in pts:
				center += p
			center /= maxf(1.0, float(pts.size()))
			for p in pts:
				radius = maxf(radius, Vector2(p.x - center.x, p.z - center.z).length())
			radius = (radius + body_r + RING_MARGIN) * (1.0 + RING_GROW * k)
		if not alive:
			node.queue_free()
			_rings.remove_at(i)
			_alive = maxi(0, _alive - 1)
			continue
		var col: Color = r["color"]
		# Entrada rápida (primer 10 %) y apagado suave.
		col.a = minf(k / 0.1, 1.0) * (1.0 - k) * (1.0 - k)
		im.clear_surfaces()
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		_emit_ring(im, center + Vector3.UP * RING_Y, maxf(0.05, radius - width), radius, col)
		im.surface_end()


## Anillo plano en XZ entre `inner` y `outer` (mismo trazado que `GroupHighlight`).
func _emit_ring(im: ImmediateMesh, center: Vector3, inner: float, outer: float, col: Color) -> void:
	var step: float = TAU / float(RING_SEGMENTS)
	for i in RING_SEGMENTS:
		var a0: float = float(i) * step
		var a1: float = float(i + 1) * step
		var c0 := Vector3(cos(a0), 0.0, sin(a0))
		var c1 := Vector3(cos(a1), 0.0, sin(a1))
		for v in [center + c0 * inner, center + c0 * outer, center + c1 * outer,
				center + c0 * inner, center + c1 * outer, center + c1 * inner]:
			im.surface_set_color(col)
			im.surface_add_vertex(v)


# --- Recetas de partículas ---

## Registra los tipos de partículas de M3 y M4. Solo crea recursos (materiales, mallas,
## texturas), ningún nodo: en OFF los pools siguen vacíos.
func _register_kinds() -> void:
	var heart: Texture2D = _make_sprite(true)
	var dot: Texture2D = _make_sprite(false)

	# Corazones entre los padres: suben despacio y se desvanecen.
	var hearts := _make_process(Color(1.0, 0.55, 0.75), 0.25, 0.32)
	hearts.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	hearts.emission_sphere_radius = 0.35
	hearts.direction = Vector3.UP
	hearts.spread = 30.0
	hearts.initial_velocity_min = 0.5
	hearts.initial_velocity_max = 0.9
	hearts.gravity = Vector3(0.0, 0.15, 0.0)
	hearts.damping_min = 0.4
	hearts.damping_max = 0.6
	_register_kind(&"mate_hearts", hearts, _make_quad(heart, false), 5, 1.2)

	# Destello del nacimiento: un brillo cálido que crece y se apaga.
	var flash := _make_process(Color(1.0, 0.95, 0.8), 1.0, 1.3)
	flash.gravity = Vector3.ZERO
	flash.scale_curve = _make_curve_tex([Vector2(0.0, 0.35), Vector2(0.4, 1.0), Vector2(1.0, 1.1)])
	_register_kind(&"birth_flash", flash, _make_quad(dot, true), 2, 0.5)

	# Bloom de afinidad: chispitas suaves que suben alrededor de la esfera.
	var bloom := _make_process(Color(1.0, 0.85, 0.55), 0.12, 0.2)
	bloom.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	bloom.emission_sphere_radius = 0.45
	bloom.direction = Vector3.UP
	bloom.spread = 20.0
	bloom.initial_velocity_min = 0.3
	bloom.initial_velocity_max = 0.6
	bloom.gravity = Vector3.ZERO
	_register_kind(&"bond_bloom", bloom, _make_quad(dot, true), 6, 0.8)

	# Motas de comer (M4): puntitos que viajan de la comida a la esfera. El emisor está
	# estirado en Z hasta la distancia (`TRAVEL_KINDS`), así que la velocidad va en
	# tramos por segundo: 1 / vida ≈ llegar justo al apagarse.
	const EAT_LIFE: float = 0.45
	var motes := _make_process(Color(0.85, 1.0, 0.6), 0.13, 0.2)
	motes.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	motes.emission_sphere_radius = 0.12
	motes.direction = Vector3(0.0, 0.0, -1.0)
	motes.spread = 10.0
	motes.initial_velocity_min = 0.8 / EAT_LIFE
	motes.initial_velocity_max = 1.0 / EAT_LIFE
	_register_kind(&"eat_motes", motes, _make_quad(dot, true), 6, EAT_LIFE)

	# Chispas de combate (M4): estallido corto y cálido en todas direcciones que cae.
	var sparks := _make_process(Color(1.0, 0.85, 0.45), 0.1, 0.16)
	sparks.direction = Vector3.UP
	sparks.spread = 180.0
	sparks.initial_velocity_min = 1.4
	sparks.initial_velocity_max = 2.4
	sparks.gravity = Vector3(0.0, -5.0, 0.0)
	sparks.damping_min = 1.5
	sparks.damping_max = 2.5
	_register_kind(&"hit_sparks", sparks, _make_quad(dot, true), 8, 0.35)


## Material de proceso común: color con fundido de alfa al final y escala aleatoria.
func _make_process(col: Color, scale_min: float, scale_max: float) -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.gravity = Vector3.ZERO
	m.scale_min = scale_min
	m.scale_max = scale_max
	var g := Gradient.new()
	g.set_color(0, Color(col, 0.0))
	g.set_color(1, Color(col, 0.0))
	g.add_point(0.12, Color(col, 0.85))
	g.add_point(0.6, Color(col, 0.6))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	m.color_ramp = gt
	return m


func _make_curve_tex(points: Array) -> CurveTexture:
	var c := Curve.new()
	c.max_value = 2.0
	for p in points:
		c.add_point(p)
	var ct := CurveTexture.new()
	ct.curve = c
	return ct


## Quad en billboard de partículas con la textura dada (aditivo para los brillos).
func _make_quad(tex: Texture2D, additive: bool) -> QuadMesh:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true  # sin esto el billboard ignora la escala de la partícula
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_texture = tex
	mat.disable_receive_shadows = true
	var q := QuadMesh.new()
	q.material = mat
	return q


## Sprite blanco de 32×32 generado en código: corazón (`heart`) o punto de borde suave.
func _make_sprite(heart: bool) -> ImageTexture:
	const N: int = 32
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for y in N:
		for x in N:
			var a: float
			if heart:
				# Corazón implícito (x²+y²−1)³ − x²y³ ≤ 0, con y hacia arriba.
				var u: float = (x + 0.5) / N * 2.6 - 1.3
				var v: float = 1.25 - (y + 0.5) / N * 2.6
				var f: float = pow(u * u + v * v - 1.0, 3.0) - u * u * v * v * v
				a = clampf(-f * 40.0, 0.0, 1.0)
			else:
				var d: float = Vector2(x + 0.5 - N * 0.5, y + 0.5 - N * 0.5).length() / (N * 0.5)
				a = clampf(1.0 - d, 0.0, 1.0)
				a *= a
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)
