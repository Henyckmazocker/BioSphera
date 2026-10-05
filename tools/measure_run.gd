extends SceneTree
## Partida de medición headless: 1 año de *Dos tribus* a ×16 con telemetría.
##
## Monta `StartScreen`, elige el preset *Dos tribus*, arranca por el mismo camino
## que el botón «Iniciar» (`_on_start_pressed`, que llama a `Analytics.start_run`),
## pone ×16, espera a que `Climate` complete un año (`day_index` = 4 ×
## `days_per_season`) y simula el cierre de ventana: así salen el día `partial` y
## el `session_end`, y el SDK sube la sesión y sale él solo.
##
## Uso normal: una etapa entera (3 partidas en paralelo, cada una con su raíz de
## Augur, y la pasada de subida final), con las reglas de memoria de CLAUDE.md:
##   AUGUR_KEY=… tools/measure_stage.sh <label>
##
## Una partida suelta (en serie, con el `user://augur/` de David):
##   AUGUR_KEY=… BIOSPHERA_RUN_LABEL=baseline \
##     tools/run_godot.sh 2400 --headless --path . --script res://tools/measure_run.gd
##
## Duración real: ~15-25 min por partida (con ~300-450 esferas el ×16 no se sostiene).
##
## Con `BIOSPHERA_AUGUR_ROOT` (raíz propia, la pone `measure_stage.sh`) da el
## consentimiento él mismo vía `Analytics.set_consent(true)`: lanzar una medición
## es la decisión explícita de David. Sin ella necesita consentimiento ya dado en
## `user://augur/`. No habla con `Augur`: el recuento final lee el `.jsonl` de la
## sesión en `<raíz>/sessions/` justo tras el cierre, antes de que la respuesta de
## la subida lo borre.
##
## Evento del entorno opcional (plan Eventos del Entorno, M0):
##   BIOSPHERA_EVENT="<kind>:<intensidad>:day=<n>:dur=<días>"   p. ej. "drought:0.6:day=10:dur=10"
## `day` es el desplazamiento desde el día de arranque real (no desde el día 0) y
## `dur` sobrescribe `duration_days` del recurso. Sin la variable no cambia nada.
##
## Override de tuning opcional (plan Nidos y Asentamientos, bisección de M5):
##   BIOSPHERA_TUNING="<clave>=<valor>,<clave>=<valor>"   p. ej. "nest_leash_radius=0"
## Cada clave es una propiedad de `SimTuning`; el valor se castea al tipo actual de la
## propiedad (int/float/bool). Se aplica a `GlobalParams.tuning` (el recurso que lee
## toda la simulación) tras elegir el preset y antes de arrancar, e imprime el valor
## efectivo. Solo para medir: el juego no la lee. Clave desconocida o mal formada →
## error y sale con 1, sin abrir partida.
##
## 🔴 No nombrar `class_name` de entidades (Sphere, Plant…): compilaría
## `entities/Sphere.gd` antes que los autoloads (ver skill ver-el-juego).
##
## Ver docs: docs/Planes/…/Plan - Fidelidad de la Simulación.md (protocolo de medición).

const PRESET_NAME: String = "Dos tribus"
const RUN_SPEED: float = 16.0
const DEFAULT_AUGUR_ROOT: String = "user://augur/"
const PROGRESS_EVERY_DAYS: int = 5
## `kind` de `BIOSPHERA_EVENT` → recurso del evento.
const EVENT_PATHS: Dictionary = {
	"drought": "res://data/events/sequia.tres",
	"cold_wave": "res://data/events/ola_de_frio.tres",
	"storm": "res://data/events/tormenta.tres",
	"abundance": "res://data/events/abundancia.tres",
	"plague": "res://data/events/plaga.tres",
}

var _started: bool = false
var _t0_ms: int = 0
var _sessions_dir: String = DEFAULT_AUGUR_ROOT + "sessions/"


func _process(_delta: float) -> bool:
	# Los nodos se montan aquí: en _initialize() aún no hay root utilizable.
	if _started:
		return false
	_started = true
	_run()
	return false


func _run() -> void:
	_t0_ms = Time.get_ticks_msec()
	# Sin JSONL a disco desde el primer momento (Climate registra la estación inicial
	# en su primer tick, antes de montar StartScreen): lo medido llega a Augur por la
	# señal `event_logged`, no por el fichero (~85 MB por partida, y en paralelo
	# chocarían los nombres).
	root.get_node("EventLog").enabled_disk = false
	var analytics: Node = root.get_node("Analytics")
	var climate: Node = root.get_node("Climate")
	var clock: Node = root.get_node("SimulationClock")
	var tuning: Resource = root.get_node("GlobalParams").tuning
	# Override de tuning por entorno: se valida lo primero (mal escrito, no se abre
	# partida, tampoco sin AUGUR_KEY) y se aplica justo antes de arrancar.
	var tuning_env: String = OS.get_environment("BIOSPHERA_TUNING")
	var tuning_overrides: Dictionary = parse_tuning_spec(tuning_env, tuning)
	if tuning_overrides.is_empty() and not tuning_env.strip_edges().is_empty():
		quit(1)
		return
	if not tuning_overrides.is_empty():
		print("[measure_run] BIOSPHERA_TUNING válido: %s" % str(tuning_overrides))

	# Raíz propia (partidas en paralelo de measure_stage.sh): no hay decisión previa
	# en disco, así que se da aquí. Analytics ya llamó a _set_test_root() en su _ready().
	var augur_root: String = OS.get_environment("BIOSPHERA_AUGUR_ROOT")
	if not augur_root.is_empty():
		_sessions_dir = augur_root.trim_suffix("/") + "/sessions/"
		if analytics.enabled and not analytics.has_consent():
			analytics.set_consent(true)
	print("[measure_run] inicio %s · run_label=%s · analytics=%s · consent=%s · sesiones=%s" % [
		Time.get_datetime_string_from_system(), analytics.run_label,
		analytics.enabled, analytics.has_consent(), _sessions_dir])
	if not analytics.has_consent():
		push_error("[measure_run] sin AUGUR_KEY o sin consentimiento en user://augur/ (ni BIOSPHERA_AUGUR_ROOT): no se mide")
		quit(1)
		return

	# Evento programado por entorno: vacío → {} y no se dispara nada. Se
	# valida antes de arrancar: mal escrito, no se abre ninguna partida.
	var event_env: String = OS.get_environment("BIOSPHERA_EVENT")
	var event_spec: Dictionary = parse_event_spec(event_env)
	if event_spec.is_empty() and not event_env.strip_edges().is_empty():
		quit(1)
		return

	var ss: Node = load("res://ui/StartScreen.tscn").instantiate()
	root.add_child(ss)
	current_scene = ss   # para que change_scene_to_file lo sustituya
	await process_frame
	var idx: int = -1
	for i in ss._presets.size():
		if String(ss._presets[i].display_name) == PRESET_NAME:
			idx = i
	if idx < 0:
		push_error("[measure_run] preset '%s' no encontrado" % PRESET_NAME)
		quit(1)
		return
	ss._on_preset_selected(idx + 1)   # índice 0 = «Personalizado»
	# Sin autoguardado: el cierre simulado de abajo escribiría `auto.sav` (el del jugador),
	# y measure_stage lanza tres a la vez sobre el mismo fichero.
	root.get_node("SimConfig").autosave_enabled = false
	# Los presets no tocan `SimTuning`, pero se aplica tras elegirlo por si algún día lo
	# hacen. `GlobalParams.tuning` es el recurso (preload, compartido) que lee toda la
	# simulación.
	for key in tuning_overrides:
		root.get_node("GlobalParams").tuning.set(key, tuning_overrides[key])
	ss._on_start_pressed()
	for i in 5:
		await process_frame
	# Valor efectivo, leído de vuelta ya con la simulación montada.
	for key in tuning_overrides:
		print("[measure_run] tuning override: %s=%s" % [key,
			str(root.get_node("GlobalParams").tuning.get(key))])
	clock.set_speed(RUN_SPEED)

	var target_day: int = 4 * int(tuning.days_per_season)
	var start_day: int = int(climate.day_index)
	print("[measure_run] preset=%s · día de arranque=%d · objetivo day_index=%d · ×%.0f" % [
		PRESET_NAME, start_day, target_day, RUN_SPEED])
	var event_day: int = start_day + int(event_spec.get("day", 0))
	if not event_spec.is_empty():
		print("[measure_run] evento programado: %s i=%.2f · day_index=%d · %.1f días" % [
			event_spec["kind"], float(event_spec["intensity"]), event_day,
			float(event_spec["dur"])])
	var last_reported: int = start_day
	while int(climate.day_index) < target_day:
		await process_frame
		if not is_equal_approx(float(clock.speed), RUN_SPEED):
			clock.set_speed(RUN_SPEED)
		var d: int = int(climate.day_index)
		if not event_spec.is_empty() and d >= event_day:
			climate.start_event(load(String(event_spec["path"])), float(event_spec["intensity"]),
				float(event_spec["dur"]))
			print("[measure_run] evento %s i=%.2f disparado en day_index=%d (t_sim=%.1f) · %.1f días" % [
				event_spec["kind"], float(event_spec["intensity"]), d, float(climate.sim_time),
				float(event_spec["dur"])])
			event_spec = {}
		if d - last_reported >= PROGRESS_EVERY_DAYS:
			last_reported = d
			var pop: Vector2i = _population()
			print("[measure_run] día %d · %.0f s reales · A=%d B=%d" % [
				d, (Time.get_ticks_msec() - _t0_ms) / 1000.0, pop.x, pop.y])

	clock.set_speed(0.0)
	var pop_end: Vector2i = _population()
	print("[measure_run] año completo: day_index=%d · t_sim=%.1f · %.0f s reales · A=%d B=%d" % [
		int(climate.day_index), float(climate.sim_time),
		(Time.get_ticks_msec() - _t0_ms) / 1000.0, pop_end.x, pop_end.y])

	# Cierre simulado: el SDK retiene el quit, emite `closing` (→ día `partial`),
	# cierra la sesión con `session_end`, sube y llama él a quit().
	root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_report_session()


## Parsea `BIOSPHERA_EVENT` («<kind>:<intensidad>:day=<n>:dur=<días>»). Devuelve
## {kind, path, intensity, day, dur} o {} si está vacía; un formato o un `kind`
## desconocido devuelve {} con error, y `_run` sale con 1 (no se mide una etapa con el
## evento mal escrito). Sin
## `dur` → -1 (la duración del recurso); sin `day` → 0 (el día de arranque).
static func parse_event_spec(spec: String) -> Dictionary:
	if spec.strip_edges().is_empty():
		return {}
	var parts: PackedStringArray = spec.strip_edges().split(":")
	if parts.size() < 2 or not EVENT_PATHS.has(parts[0]) or not parts[1].is_valid_float():
		push_error("[measure_run] BIOSPHERA_EVENT mal formado o kind desconocido: '%s'" % spec)
		return {}
	var out: Dictionary = {
		"kind": parts[0],
		"path": EVENT_PATHS[parts[0]],
		"intensity": clampf(parts[1].to_float(), 0.0, 1.0),
		"day": 0,
		"dur": -1.0,
	}
	for i in range(2, parts.size()):
		var kv: PackedStringArray = parts[i].split("=")
		if kv.size() != 2 or not kv[1].is_valid_float() or not (kv[0] == "day" or kv[0] == "dur"):
			push_error("[measure_run] BIOSPHERA_EVENT: campo desconocido '%s'" % parts[i])
			return {}
		out[kv[0]] = int(kv[1].to_float()) if kv[0] == "day" else kv[1].to_float()
	return out


## Parsea `BIOSPHERA_TUNING` («clave=valor,clave=valor»). Devuelve {clave: valor} con
## el valor ya casteado al tipo actual de la propiedad en `tuning` (int/float/bool), o
## {} si está vacía; una clave que no existe, un tipo no soportado o un valor que no
## encaja devuelve {} con error, y `_run` sale con 1.
static func parse_tuning_spec(spec: String, tuning: Resource) -> Dictionary:
	var out: Dictionary = {}
	if spec.strip_edges().is_empty():
		return out
	for item in spec.strip_edges().split(","):
		var kv: PackedStringArray = item.strip_edges().split("=")
		if kv.size() != 2 or kv[0].strip_edges().is_empty():
			push_error("[measure_run] BIOSPHERA_TUNING mal formado: '%s'" % item)
			return {}
		var key: String = kv[0].strip_edges()
		var raw: String = kv[1].strip_edges()
		if not key in tuning:
			push_error("[measure_run] BIOSPHERA_TUNING: SimTuning no tiene '%s'" % key)
			return {}
		var cur: Variant = tuning.get(key)
		match typeof(cur):
			TYPE_INT:
				if not raw.is_valid_int():
					push_error("[measure_run] BIOSPHERA_TUNING: '%s' espera int, no '%s'" % [key, raw])
					return {}
				out[key] = raw.to_int()
			TYPE_FLOAT:
				if not raw.is_valid_float():
					push_error("[measure_run] BIOSPHERA_TUNING: '%s' espera float, no '%s'" % [key, raw])
					return {}
				out[key] = raw.to_float()
			TYPE_BOOL:
				var low: String = raw.to_lower()
				if low not in ["true", "false", "1", "0"]:
					push_error("[measure_run] BIOSPHERA_TUNING: '%s' espera bool, no '%s'" % [key, raw])
					return {}
				out[key] = low == "true" or low == "1"
			_:
				push_error("[measure_run] BIOSPHERA_TUNING: '%s' no es int/float/bool" % key)
				return {}
	return out


## Población viva por especie (sin nombrar la clase `Sphere`).
func _population() -> Vector2i:
	var a: int = 0
	var b: int = 0
	for s in get_nodes_in_group(&"spheres"):
		var g: Variant = s.get("genome")
		if typeof(g) != TYPE_DICTIONARY:
			continue
		match String(g.get("species", &"")):
			"A": a += 1
			"B": b += 1
	return Vector2i(a, b)


## Lee la sesión recién cerrada (la más reciente de `sessions/`) y resume lo que
## emitió `Analytics`: day_summary completos y parciales, birth_biome, y la σ media
## por estación y bioma (en M0 debe ser la misma en todos los biomas).
func _report_session() -> void:
	var path: String = _latest_session_file()
	if path.is_empty():
		print("[measure_run] sesión: no hay .jsonl en %s (¿ya subida y borrada?)" % _sessions_dir)
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("[measure_run] sesión: no se pudo abrir %s" % path)
		return
	var days_full: int = 0
	var days_partial: int = 0
	var birth_biomes: int = 0
	var has_end: bool = false
	var last_full: Dictionary = {}
	var partial_props: Dictionary = {}
	# "season|biome" -> [n, sigma_sum]
	var sigma_acc: Dictionary = {}
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.is_empty():
			continue
		var rec: Variant = JSON.parse_string(line)
		if typeof(rec) != TYPE_DICTIONARY:
			continue
		var ev_name: String = str(rec.get("name", ""))
		var props: Dictionary = rec.get("props", {})
		match ev_name:
			"day_summary":
				if bool(props.get("partial", false)):
					days_partial += 1
					partial_props = props
				else:
					days_full += 1
					last_full = props
			"birth_biome":
				birth_biomes += 1
				var key: String = "%d|%s" % [int(props.get("season", -1)), str(props.get("biome", ""))]
				var n: int = int(props.get("n", 0))
				var acc: Array = sigma_acc.get(key, [0, 0.0])
				acc[0] = int(acc[0]) + n
				acc[1] = float(acc[1]) + float(props.get("sigma_avg", 0.0)) * n
				sigma_acc[key] = acc
			"session_end":
				has_end = true
	var final_props: Dictionary = partial_props if not partial_props.is_empty() else last_full
	print("[measure_run] sesión %s: day_summary=%d (+%d partial) · birth_biome=%d · session_end=%s · pop final A=%d B=%d" % [
		path.get_file(), days_full, days_partial, birth_biomes, has_end,
		int(final_props.get("pop_A", -1)), int(final_props.get("pop_B", -1))])
	var keys: Array = sigma_acc.keys()
	keys.sort()
	for key in keys:
		var acc: Array = sigma_acc[key]
		print("[measure_run]   σ estación|bioma %s: n=%d σ_media=%.5f" % [
			key, int(acc[0]), float(acc[1]) / maxf(float(acc[0]), 1.0)])


func _latest_session_file() -> String:
	var dir: DirAccess = DirAccess.open(_sessions_dir)
	if dir == null:
		return ""
	var best: String = ""
	var best_mtime: int = -1
	for file in dir.get_files():
		if not file.ends_with(".jsonl"):
			continue
		var p: String = _sessions_dir + file
		var mtime: int = FileAccess.get_modified_time(p)
		if mtime > best_mtime:
			best_mtime = mtime
			best = p
	return best
