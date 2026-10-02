extends Node
## Arnés de prueba headless — puerta de regresión de la simulación.
##
## Instancia el mundo, corre la simulación N segundos a velocidad alta,
## acumula métricas de salud en vivo desde EventLog y emite un informe
## con veredicto PASS/FAIL. Código de salida 0 si todo pasa, 1 si algo falla.
##
## Uso:
##   godot --headless tools/SmokeTest.tscn
##
## Complementa a `tools/analyze_logs.py`: este da un sí/no rápido y
## automático; aquel hace el análisis forense profundo de una sesión.

const TARGET_SIM_SECONDS: float = 90.0
const RUN_SPEED: float = 8.0
const SAMPLE_INTERVAL: float = 2.0     # cada cuántos segundos reales muestreamos posiciones
const BIOME_SEED: int = 20260519       # semilla fija de biomas (corridas reproducibles)
const MIN_SAMPLES_FOR_STUCK: int = 4   # esferas con menos muestras no cuentan para "atascada"

# Umbrales de aprobación.
const MAX_FAST_SWITCH_PCT: float = 12.0   # % de cambios de acción en < 0.5 s
const MAX_STUCK_PCT: float = 3.0          # % de esferas con < 2 m de desplazamiento vital
const MIN_POPULATION_PCT: float = 30.0    # población final mínima vs inicial
const MAX_OOB_SAMPLES: int = 0            # esferas fuera del mundo (|x| o |z| > límite)

var _world: Node = null
var _initial_population: int = 0

# Métricas desde EventLog.
var _last_action_t: Dictionary = {}        # id -> t_sim del último action_change
var _switch_intervals: Array[float] = []
var _eats_by_id: Dictionary = {}           # id -> nº de eat
var _hunger_deaths: int = 0
var _hunger_deaths_zero_eats: int = 0     # contexto: muertes de hambre sin comer
var _starved_with_food: int = 0           # de esas, las que tenían comida al alcance
var _deaths_by_cause: Dictionary = {}
var _births: int = 0

# Muestreo de posiciones (desplazamiento vital y fuera-de-mundo).
var _first_pos: Dictionary = {}            # id -> Vector3
var _last_pos: Dictionary = {}
var _sample_count: Dictionary = {}         # id -> nº de muestras
var _oob_samples: int = 0
var _sample_accum: float = 0.0
var _half_bound: float = 30.0


func _ready() -> void:
	print("=== BioSphera smoke test — %.0fs sim @ x%.0f ===" % [TARGET_SIM_SECONDS, RUN_SPEED])
	_half_bound = SimConfig.world_size * 0.5
	EventLog.event_logged.connect(_on_event)
	# Biomas con semilla fija: el terreno (origen estructural de varianza
	# entre corridas) es reproducible, así el veredicto es comparable run a run.
	Biomes.generate(Vector2(SimConfig.world_size, SimConfig.world_size), BIOME_SEED)
	var world_scene: PackedScene = load("res://world/World.tscn")
	_world = world_scene.instantiate()
	add_child(_world)
	SimulationClock.set_speed(RUN_SPEED)
	call_deferred("_count_initial_population")


func _count_initial_population() -> void:
	# El spawner coloca la población tras `World.await_nav_ready()`, cuyo
	# tiempo no es fijo: depende de cuántos physics frames tarde el server en
	# integrar la región. Pollear es más robusto que un timer.
	var guard: int = 0
	while get_tree().get_nodes_in_group(&"spheres").is_empty() and guard < 120:
		await get_tree().process_frame
		guard += 1
	# Un frame extra para asegurar que el bucle del spawner ha terminado.
	await get_tree().process_frame
	_initial_population = get_tree().get_nodes_in_group(&"spheres").size()
	print("Población inicial: %d esferas" % _initial_population)


func _on_event(e: Dictionary) -> void:
	match String(e.get("kind", "")):
		"action_change":
			var id = e.data.get("id", 0)
			var t: float = float(e.get("t_sim", 0.0))
			if _last_action_t.has(id):
				_switch_intervals.append(t - float(_last_action_t[id]))
			_last_action_t[id] = t
		"eat":
			var eid = e.data.get("id", 0)
			_eats_by_id[eid] = int(_eats_by_id.get(eid, 0)) + 1
		"death":
			var cause: String = String(e.data.get("cause", "?"))
			_deaths_by_cause[cause] = int(_deaths_by_cause.get(cause, 0)) + 1
			if cause == "hunger":
				_hunger_deaths += 1
				if int(_eats_by_id.get(e.data.get("id", 0), 0)) == 0:
					_hunger_deaths_zero_eats += 1
					# `diag.edible_near > 0` ⇒ tenía comida al alcance y aun así
					# no comió: patológico. `== 0` ⇒ escasez real (ecología).
					var diag: Dictionary = e.data.get("diag", {})
					if int(diag.get("edible_near", 0)) > 0:
						_starved_with_food += 1
		"birth":
			_births += 1


func _process(dt: float) -> void:
	_sample_accum += dt
	if _sample_accum >= SAMPLE_INTERVAL:
		_sample_accum = 0.0
		_sample_positions()
	if SimulationClock.get_sim_time() >= TARGET_SIM_SECONDS:
		_report_and_quit()


func _sample_positions() -> void:
	for s in get_tree().get_nodes_in_group(&"spheres"):
		var id: int = s.get_instance_id()
		var p: Vector3 = s.global_position
		if not _first_pos.has(id):
			_first_pos[id] = p
		_last_pos[id] = p
		_sample_count[id] = int(_sample_count.get(id, 0)) + 1
		if absf(p.x) > _half_bound + 0.5 or absf(p.z) > _half_bound + 0.5:
			_oob_samples += 1


func _report_and_quit() -> void:
	set_process(false)

	var fast: int = 0
	for iv in _switch_intervals:
		if iv < 0.5:
			fast += 1
	var fast_pct: float = 100.0 * float(fast) / float(maxi(1, _switch_intervals.size()))

	var population: int = get_tree().get_nodes_in_group(&"spheres").size()
	var pop_pct: float = 100.0 * float(population) / float(maxi(1, _initial_population))

	var stuck: int = 0
	var eligible: int = 0
	for id in _first_pos:
		if int(_sample_count.get(id, 0)) < MIN_SAMPLES_FOR_STUCK:
			continue
		eligible += 1
		var a: Vector3 = _first_pos[id]
		var b: Vector3 = _last_pos[id]
		if Vector2(a.x - b.x, a.z - b.z).length() < 2.0:
			stuck += 1
	var stuck_pct: float = 100.0 * float(stuck) / float(maxi(1, eligible))

	print("\n" + "─".repeat(58))
	print("INFORME DE SALUD")
	print("─".repeat(58))
	var ok := true
	ok = _check("Cambios de acción < 0.5 s",
		"%.1f%% (%d/%d)" % [fast_pct, fast, _switch_intervals.size()],
		fast_pct <= MAX_FAST_SWITCH_PCT, "≤ %.0f%%" % MAX_FAST_SWITCH_PCT) and ok
	ok = _check("Muestras de esfera fuera del mundo",
		"%d" % _oob_samples, _oob_samples <= MAX_OOB_SAMPLES,
		"≤ %d" % MAX_OOB_SAMPLES) and ok
	ok = _check("Esferas atascadas (< 2 m de por vida)",
		"%.1f%% (%d/%d)" % [stuck_pct, stuck, eligible],
		stuck_pct <= MAX_STUCK_PCT, "≤ %.0f%%" % MAX_STUCK_PCT) and ok
	# La población es la salud INTEGRAL del sistema alimentario: un fallo real
	# de entrega de comida la hundiría. La inanición individual, en cambio, es
	# selección natural (escasez ecológica) y se reporta como contexto, no
	# como fallo — el arnés mide bugs, no darwinismo.
	ok = _check("Población final",
		"%.0f%% (%d/%d)" % [pop_pct, population, _initial_population],
		pop_pct >= MIN_POPULATION_PCT, "≥ %.0f%%" % MIN_POPULATION_PCT) and ok

	print("─".repeat(58))
	var causes: Array = []
	for c in _deaths_by_cause:
		causes.append("%s=%d" % [c, _deaths_by_cause[c]])
	print("Contexto: %d nacimientos, muertes [%s]" % [_births, ", ".join(causes)])
	print(("Contexto inanición: %d murieron sin comer — %d por escasez real " +
		"(sin comida en 40 m = selección natural), %d con comida al alcance.") % [
		_hunger_deaths_zero_eats, _hunger_deaths_zero_eats - _starved_with_food,
		_starved_with_food])
	print("VEREDICTO: %s" % ("✅ PASS" if ok else "❌ FAIL"))
	print("─".repeat(58))
	get_tree().quit(0 if ok else 1)


func _check(label: String, value: String, passed: bool, threshold: String) -> bool:
	print("  %s  %-42s %s  (umbral %s)" % [
		"✅" if passed else "❌", label, value, threshold])
	return passed
