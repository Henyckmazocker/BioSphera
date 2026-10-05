extends Node
## Arnés de ida y vuelta del guardado — regresión del estado persistente.
##
## Dos fases, una por proceso (los autoloads no se resetean entre partidas, así que la
## carga tiene que ocurrir en un proceso nuevo, como al pulsar «Continuar»):
## - `save`: misma arrancada que `tools/smoke_test.gd` (semilla de biomas fija, `World`
##   instanciado), corre `BIOSPHERA_SAVE_TEST_S` segundos de sim (120 por defecto) a x8
##   y guarda en la ranura `test`.
## - `load`: lee ese save, lo deja en `SimConfig.pending_save` ANTES de instanciar el
##   mundo, y en cuanto `Spawner` lo restaura (señal `save_restored`, antes de cualquier
##   tick posterior) vuelve a capturar y compara con lo leído campo a campo, más el
##   orden de `SimulationClock._entities`. Sale con 1 y lista las primeras diferencias.
##
## Las capturas usan índices de save, no `instance_id`, así que son comparables entre
## procesos. Un campo nuevo que no se guarde o no se restaure aparece como diferencia.
## Además (M1): exige que los tipos de entidad de la foto guardada sigan en la cargada,
## el mismo orden de `SimulationClock._slow`, y que cada objetivo no nulo de cada esfera
## restaurada resuelva a una entidad viva del tipo correcto (lo mismo para la
## `_plant_blacklist`). Y (M2) integridad social en el mundo cargado: mismos grupos con
## los mismos miembros; cada miembro vivo y con su `group_id`; cada `group_id` de
## esfera, granja o planta existe en `Groups` o es -1, sin tolerancia (plan «Nidos y
## Asentamientos», M2); cada nido es del grupo que lo apunta o huérfano con
## `orphaned_tick`; cada clave de `Relationships` es una esfera viva.
##
## La fase sale de la variable de entorno `BIOSPHERA_SAVE_LOAD_PHASE`. Uso:
##   env -u AUGUR_KEY tools/save_load_test.sh
##
## Evento del entorno opcional (plan Eventos del Entorno, M1), mismo formato que
## `tools/measure_run.gd` y con `day` relativo al día de arranque (0):
##   env -u AUGUR_KEY BIOSPHERA_EVENT="drought:0.6:day=1:dur=10" tools/save_load_test.sh
## Solo lo lee la fase `save`; la `load` recibe el evento del save y no lo vuelve a disparar.

const PHASE_ENV: String = "BIOSPHERA_SAVE_LOAD_PHASE"
const SLOT: String = "test"
const DEFAULT_SIM_SECONDS: float = 120.0
## Duración de la fase `save` en segundos de sim (fundar un nido exige 150 s: ver plan
## «Nidos y Asentamientos», M0). Sin la variable, `DEFAULT_SIM_SECONDS`.
const SIM_SECONDS_ENV: String = "BIOSPHERA_SAVE_TEST_S"
const RUN_SPEED: float = 8.0
const BIOME_SEED: int = 20260519       # la misma que tools/smoke_test.gd
const MAX_DIFFS_SHOWN: int = 20
const EVENT_ENV: String = "BIOSPHERA_EVENT"
## Solo por `parse_event_spec` y `EVENT_PATHS` (funciones estáticas, no se ejecuta).
const MeasureRun: GDScript = preload("res://tools/measure_run.gd")
## Volátiles por diseño: cambian en cada guardado sin ser estado de la simulación.
const VOLATILE_KEYS: Array[String] = ["saved_at", "kind"]
## Objetivos de la IA de `Sphere` → tipos de entidad válidos. Un cadáver se registra
## como alimento (`SpatialIndex.register_plant`), así que puede ser `_target_plant`.
const TARGET_KINDS: Dictionary = {
	"target_plant": [&"plant", &"corpse"],
	"target_resource": [&"tree", &"deposit"],
	"target_mate": [&"sphere"],
	"fight_target": [&"sphere"],
	"target_farm": [&"farm"],
	"food_rival": [&"sphere"],
	"flee_target": [&"sphere"],
}

var _phase: String = ""
var _target_sim_seconds: float = DEFAULT_SIM_SECONDS
var _world: Node = null
var _spawner: Spawner = null
var _expected: Dictionary = {}
# Evento programado de la fase `save` ({} sin `BIOSPHERA_EVENT` o ya disparado).
var _event_spec: Dictionary = {}


func _ready() -> void:
	_phase = OS.get_environment(PHASE_ENV)
	set_process(false)
	match _phase:
		"save":
			_start_save()
		"load":
			_start_load()
		_:
			printerr("save_load_test: falta %s=save|load" % PHASE_ENV)
			get_tree().quit(2)


func _start_save() -> void:
	var secs_env: String = OS.get_environment(SIM_SECONDS_ENV).strip_edges()
	if not secs_env.is_empty():
		if not secs_env.is_valid_float() or secs_env.to_float() <= 0.0:
			printerr("save_load_test: %s=%s no es un número de segundos > 0" % [
				SIM_SECONDS_ENV, secs_env])
			get_tree().quit(2)
			return
		_target_sim_seconds = secs_env.to_float()
	print("=== save_load_test (save) — %.0fs sim @ x%.0f ===" % [_target_sim_seconds, RUN_SPEED])
	var event_env: String = OS.get_environment(EVENT_ENV)
	_event_spec = MeasureRun.parse_event_spec(event_env)
	if _event_spec.is_empty() and not event_env.strip_edges().is_empty():
		get_tree().quit(1)   # mal escrito: no se da por buena una ida y vuelta sin el evento
		return
	if not _event_spec.is_empty():
		print("Evento programado: %s i=%.2f · day_index=%d · %.1f días" % [
			_event_spec["kind"], float(_event_spec["intensity"]), int(_event_spec["day"]),
			float(_event_spec["dur"])])
	# Como smoke_test: biomas con semilla fija antes de crear el mundo.
	Biomes.generate(Vector2(SimConfig.world_size, SimConfig.world_size), BIOME_SEED)
	_instantiate_world()
	SimulationClock.set_speed(RUN_SPEED)
	set_process(true)


func _process(_dt: float) -> void:
	# `_process` corre fuera del tick: la captura no ve bajas diferidas a medias.
	if not _event_spec.is_empty() and Climate.day_index >= int(_event_spec["day"]):
		Climate.start_event(load(String(_event_spec["path"])), float(_event_spec["intensity"]),
			float(_event_spec["dur"]))
		print("Evento %s disparado en day_index=%d (t_sim=%.1f)" % [
			_event_spec["kind"], Climate.day_index, Climate.sim_time])
		_event_spec = {}
	if SimulationClock.get_sim_time() < _target_sim_seconds:
		return
	set_process(false)
	print("Eventos activos al guardar: %s" % str(Climate.active_events()))
	var err: Error = SaveGame.save_now(_spawner, SLOT)
	if err != OK:
		printerr("save_load_test: no se pudo guardar (%s)" % error_string(err))
		get_tree().quit(1)
		return
	var r: Dictionary = SaveGame.read(SLOT)
	var n: int = (r.data.get("entities", []) as Array).size() if r.ok else -1
	print("Guardado en %s: tick %d, %d entidades %s" % [
		ProjectSettings.globalize_path(SaveGame.path_for(SLOT)),
		SimulationClock.get_tick_count(), n,
		str(_kind_counts(r.data.get("entities", []))) if r.ok else ""])
	if r.ok:
		print("Nidos en el save: %d" % (r.data.get("groups", {}).get("nests", []) as Array).size())
	get_tree().quit(0 if r.ok and n > 0 else 1)


func _start_load() -> void:
	print("=== save_load_test (load) ===")
	var r: Dictionary = SaveGame.read(SLOT)
	if not r.ok:
		printerr("save_load_test: %s" % r.error)
		get_tree().quit(1)
		return
	_expected = r.data
	print("Eventos en el save: %s" % str(_expected.climate.get("events", [])))
	# Lo que haría StartScreen al pulsar «Continuar»: config/params y save pendiente.
	SaveGame.apply_settings(_expected)
	SimConfig.pending_save = _expected.duplicate(true)
	_instantiate_world()


func _instantiate_world() -> void:
	var world_scene: PackedScene = load("res://world/World.tscn")
	_world = world_scene.instantiate()
	_spawner = _world.get_node("Spawner") as Spawner
	if _phase == "load":
		# Conectar antes de `add_child`: la restauración llega tras `await_nav_ready`.
		_spawner.save_restored.connect(_on_save_restored, CONNECT_ONE_SHOT)
	add_child(_world)


## Síncrono dentro de la rama de carga del Spawner: aún no ha corrido ningún tick tras
## restaurar, así que reloj y clima deben coincidir exactamente con el save.
func _on_save_restored(node_of: Array) -> void:
	var got: Dictionary = SaveGame.capture(_spawner)
	var diffs: Array[String] = []
	for key in _expected.keys():
		if String(key) in VOLATILE_KEYS:
			continue
		if not got.has(key):
			diffs.append("%s: falta en la recaptura" % key)
			continue
		_diff(String(key), _expected[key], got[key], diffs)
	for key in got.keys():
		if not _expected.has(key) and not String(key) in VOLATILE_KEYS:
			diffs.append("%s: sobra en la recaptura" % key)
	# Orden de tick: `_entities` y `_slow` deben ser exactamente los nodos restaurados de
	# cada cadencia, en el orden del save (la franja de cada entidad es su posición).
	var want_fast: Array = []
	var want_slow: Array = []
	for nd in node_of:
		if nd is Sphere:
			want_fast.append(nd)
		elif nd is Plant or nd is TreeNode or nd is Farm or nd is Corpse:
			want_slow.append(nd)
	_check_order("_entities", SimulationClock._entities, want_fast, node_of, diffs)
	_check_order("_slow", SimulationClock._slow, want_slow, node_of, diffs)
	# Los tipos de entidad de la foto guardada siguen en la cargada (no un mínimo
	# absoluto por tipo: una partida sin cadáveres en ese instante es legítima).
	var counts: Dictionary = _kind_counts(_expected.entities)
	var got_counts: Dictionary = _kind_counts(got.get("entities", []))
	for kind in counts:
		if int(got_counts.get(kind, 0)) == 0:
			diffs.append("entities: ningún «%s» tras cargar (%d en el save)" % [kind, counts[kind]])
	if int(counts.get(&"sphere", 0)) == 0:
		diffs.append("entities: el save no tiene esferas")
	var n_targets: int = _check_targets(_expected.entities, node_of, diffs)
	var social: Dictionary = _check_social(node_of, diffs)
	print("Restauradas %d entidades %s en el tick %d; %d objetivos/blacklist comprobados" % [
		node_of.size(), str(counts), SimulationClock.get_tick_count(), n_targets])
	print("Integridad social: %d grupos, %d miembros, %d group_id comprobados (sin tolerancia de colgantes), %d nidos (%d huérfanos), %d claves de Relationships" % [
		social.groups, social.members, social.gids, social.nests, social.orphans, social.rel_keys])
	if diffs.is_empty():
		print("Eventos activos tras cargar: %s" % str(Climate.active_events()))
		print("VEREDICTO: ✅ PASS — captura idéntica tras cargar, mismo orden de _entities y _slow, objetivos vivos y del tipo correcto, grupos y relaciones íntegros")
		get_tree().quit(0)
		return
	print("VEREDICTO: ❌ FAIL — %d diferencias (primeras %d):" % [diffs.size(), MAX_DIFFS_SHOWN])
	for i in mini(diffs.size(), MAX_DIFFS_SHOWN):
		print("  " + diffs[i])
	get_tree().quit(1)


func _kind_counts(entities: Array) -> Dictionary:
	var counts: Dictionary = {}
	for d in entities:
		var k: StringName = StringName(d.get("k", &""))
		counts[k] = int(counts.get(k, 0)) + 1
	return counts


## Integridad social del mundo cargado (M2). Los grupos del save deben ser los de
## `Groups` con los mismos miembros (tras M0 el tick normalizaba `group_id` a -1 porque
## no había grupos: ahora se conservan). Devuelve los recuentos comprobados.
func _check_social(node_of: Array, out: Array[String]) -> Dictionary:
	var saved_list: Array = _expected.groups.list
	var saved_members: Dictionary = {}   # gid → Array de índices
	for sg in saved_list:
		saved_members[int(sg.id)] = sg.members
	if saved_list.size() != Groups._groups.size():
		out.append("grupos: %d en el save, %d tras cargar" % [saved_list.size(), Groups._groups.size()])
	var n_members: int = 0
	for gid in Groups._groups:
		var g: Dictionary = Groups._groups[gid]
		if not saved_members.has(gid):
			out.append("grupo %d: no estaba en el save" % gid)
		else:
			var want: Array = []
			for idx in saved_members[gid]:
				want.append(node_of[int(idx)])
			if want != g.members:
				out.append("grupo %d: miembros %s, en el save %s" % [gid,
					str(g.members.map(func(m): return node_of.find(m))), str(saved_members[gid])])
		for m in g.members:
			n_members += 1
			if not is_instance_valid(m) or not (m is Sphere) or not m._alive:
				out.append("grupo %d: miembro no vivo" % gid)
			elif m.group_id != gid:
				out.append("grupo %d: miembro %d con group_id %d" % [gid, node_of.find(m), m.group_id])
	# Sin tolerancia de colgantes (plan «Nidos y Asentamientos», M2): `_retire_group` deja
	# las granjas y plantas de un grupo muerto en -1 y la fusión las traspasa, así que
	# cualquier id que no exista es un fallo, del guardado o del juego.
	var n_gids: int = 0
	for i in node_of.size():
		var nd: Node = node_of[i]
		var gid: int = -1
		if nd is Sphere or nd is Farm:
			gid = nd.group_id
		elif nd is Plant:
			gid = nd.owner_group_id
		else:
			continue
		n_gids += 1
		if gid != -1 and not Groups.has_group(gid):
			out.append("entities[%d] (%s): group_id %d no existe en Groups" % [i, nd.get_class(), gid])
	# Nidos: el de cada grupo existe y es suyo; el `group_id` de cada nido es -1
	# (huérfano, con `orphaned_tick`) o un grupo que lo tiene como `nest_id`.
	var n_nests: int = Groups._nests.size()
	var n_orphans: int = 0
	for gid in Groups._groups:
		var nid: int = int(Groups._groups[gid].get("nest_id", -1))
		if nid != -1 and (not Groups._nests.has(nid) or int(Groups._nests[nid].group_id) != gid):
			out.append("grupo %d: nest_id %d no existe o no es suyo" % [gid, nid])
	for nid in Groups._nests:
		var nest: Dictionary = Groups._nests[nid]
		var ngid: int = int(nest.group_id)
		if ngid == -1:
			n_orphans += 1
			if int(nest.orphaned_tick) < 0:
				out.append("nido %d: huérfano sin orphaned_tick" % nid)
		elif not Groups.has_group(ngid) or int(Groups._groups[ngid].nest_id) != int(nid):
			out.append("nido %d: group_id %d no existe o no lo reconoce" % [nid, ngid])
	var live_spheres: Dictionary = {}
	for nd in node_of:
		if nd is Sphere and is_instance_valid(nd) and nd._alive:
			live_spheres[nd.get_instance_id()] = true
	var n_keys: int = 0
	for a in Relationships._memory:
		n_keys += 1
		if not live_spheres.has(a):
			out.append("Relationships: clave %d no es una esfera viva" % a)
		for b in Relationships._memory[a]:
			n_keys += 1
			if not live_spheres.has(b):
				out.append("Relationships[%d]: clave %d no es una esfera viva" % [a, b])
	return {"groups": Groups._groups.size(), "members": n_members, "gids": n_gids,
		"nests": n_nests, "orphans": n_orphans, "rel_keys": n_keys}


## `got` (array del reloj) debe ser `want` elemento a elemento.
func _check_order(label: String, got: Array, want: Array, node_of: Array, out: Array[String]) -> void:
	if got.size() != want.size():
		out.append("orden %s: %d registradas, %d en el save" % [label, got.size(), want.size()])
	for i in mini(got.size(), want.size()):
		if got[i] != want[i]:
			out.append("orden %s[%d]: es la entidad %d del save, se esperaba la %d" % [
				label, i, node_of.find(got[i]), node_of.find(want[i])])


## Comprobación explícita de los objetivos de la IA, en el save y en el mundo cargado:
## cada índice no nulo apunta a una entrada del tipo correcto, y cada referencia de
## cada esfera restaurada es una entidad viva (válida, no en cola de borrado y, si es
## esfera, `_alive`) de la foto y del tipo correcto. Devuelve cuántas ha comprobado.
func _check_targets(entities: Array, node_of: Array, out: Array[String]) -> int:
	var kind_of: Dictionary = {}   # nodo → k
	for i in node_of.size():
		if node_of[i] != null:
			kind_of[node_of[i]] = StringName(entities[i].get("k", &""))
	var checked: int = 0
	for i in entities.size():
		var d: Dictionary = entities[i]
		if StringName(d.get("k", &"")) != &"sphere":
			continue
		var s: Sphere = node_of[i] as Sphere
		for field in TARGET_KINDS:
			var allowed: Array = TARGET_KINDS[field]
			var idx: int = int(d[field])
			if idx >= 0 and (idx >= entities.size() or not StringName(entities[idx].get("k", &"")) in allowed):
				out.append("entities[%d].%s: índice %d no es %s" % [i, field, idx, str(allowed)])
			var ref: Variant = s.get("_" + field)
			if ref == null:
				if idx >= 0:
					out.append("entities[%d].%s: índice %d no resolvió" % [i, field, idx])
				continue
			checked += 1
			_check_live_ref("entities[%d]._%s" % [i, field], ref, allowed, kind_of, out)
		for pid in s._plant_blacklist:
			checked += 1
			_check_live_ref("entities[%d]._plant_blacklist" % i, instance_from_id(pid),
				[&"plant", &"corpse"], kind_of, out)
	return checked


func _check_live_ref(path: String, ref: Variant, allowed: Array, kind_of: Dictionary,
		out: Array[String]) -> void:
	if not is_instance_valid(ref) or (ref as Node).is_queued_for_deletion():
		out.append("%s: apunta a una entidad liberada" % path)
	elif not kind_of.has(ref):
		out.append("%s: apunta a una entidad fuera de la foto" % path)
	elif not kind_of[ref] in allowed:
		out.append("%s: es «%s», se esperaba %s" % [path, kind_of[ref], str(allowed)])
	elif ref is Sphere and not ref._alive:
		out.append("%s: apunta a una esfera muerta" % path)


## Diferencia recursiva estricta: mismo tipo y mismo valor. `path` localiza el campo
## (p. ej. `entities[12].energy`).
func _diff(path: String, a: Variant, b: Variant, out: Array[String]) -> void:
	if typeof(a) != typeof(b):
		out.append("%s: tipo %s ≠ %s (%s ≠ %s)" % [path, type_string(typeof(a)),
			type_string(typeof(b)), str(a), str(b)])
		return
	match typeof(a):
		TYPE_DICTIONARY:
			for k in a.keys():
				if not b.has(k):
					out.append("%s.%s: falta en la recaptura" % [path, str(k)])
				else:
					_diff("%s.%s" % [path, str(k)], a[k], b[k], out)
			for k in b.keys():
				if not a.has(k):
					out.append("%s.%s: sobra en la recaptura" % [path, str(k)])
		TYPE_ARRAY:
			if a.size() != b.size():
				out.append("%s: tamaño %d ≠ %d" % [path, a.size(), b.size()])
			for i in mini(a.size(), b.size()):
				_diff("%s[%d]" % [path, i], a[i], b[i], out)
		_:
			if a != b:
				out.append("%s: %s ≠ %s" % [path, var_to_str(a), var_to_str(b)])
