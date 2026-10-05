extends Node
## Puente con la analítica de Augur (autoload `Analytics`).
##
## Es el **único** sistema que habla con el autoload `Augur` (SDK en
## `addons/augur/`); el resto del juego llama a `Analytics`. Es autoload y no
## un nodo de `Stats` porque vive entre escenas (StartScreen → simulación).
##
## Sin `AUGUR_KEY` en el entorno no se llama a nada de `Augur`: ni
## `configure()`, ni red, ni disco en `user://augur/`. La clave sale solo del
## entorno, nunca del repo.
## Con `BIOSPHERA_AUGUR_ROOT` (solo `tools/measure_stage.sh`) el estado de
## Augur va a esa raíz en vez de `user://augur/`; el juego normal no la define.
##
## Qué manda (todo con `run_label` y `day`, props planas):
## - `run_start` al lanzar la partida desde StartScreen (`start_run`).
## - `day_summary` por día simulado (`Climate.day_rolled`), y uno `partial` al
##   cerrar la ventana (`Augur.closing`).
## - `birth_biome` por bioma con nacimientos del día, solo si `birth` trae `biome`.
## - Quince eventos sociales/económicos sueltos, reenviados tal cual (sin campos
##   Array/Dictionary). `birth`/`death`/`action_change` NO se reenvían: se agregan.
##
## Nada de esto corre en el tick: `_on_event` es un `match` por evento (el mismo
## coste que ya paga `Stats`) y el recorrido de esferas va una vez por día.
##
## Ver docs: docs/Planes/…/Plan - Integración con Augur.md (sección "Analytics").

const DEFAULT_ENDPOINT: String = "https://augur.dcahomelab.com"
const DEFAULT_RUN_LABEL: String = "dev"
const CUSTOM_PRESET: String = "Personalizado"

## Causas de muerte con prop propia en `day_summary` (ver `Sphere._on_tick`).
## Una causa nueva queda en el JSONL pero no en el resumen hasta añadirla aquí.
const DEATH_CAUSES: Array[String] = ["hunger", "combat", "old_age", "plague"]
const SPECIES: Array[String] = ["A", "B"]
## Rasgos físicos del genoma promediados en `day_summary` y con varianza en `birth_biome`.
const PHYSICAL_KEYS: Array[String] = ["size", "speed", "vision", "metabolism", "longevity"]

## Eventos de EventLog que se reenvían sueltos con el mismo nombre.
const FORWARDED_KINDS: Dictionary = {
	"env_event_start": true,
	"env_event_end": true,
	"group_formed": true,
	"group_dissolved": true,
	"groups_merged": true,
	"group_rivalry": true,
	"member_expelled": true,
	"goal_changed": true,
	"farm_share": true,
	"farm_theft": true,
	"farm_built": true,
	"farm_destroyed": true,
	"weapon_crafted": true,
	# Nidos: `nest_faded` no se reenvía (ruido; el desvanecido sigue a cada `nest_lost`).
	"nest_founded": true,
	"nest_lost": true,
}

## true solo si `AUGUR_KEY` no está vacía y se llamó a `Augur.configure()`.
var enabled: bool = false
## Etiqueta de la partida para comparar series en Augur (`BIOSPHERA_RUN_LABEL`).
var run_label: String = DEFAULT_RUN_LABEL

# Partida en curso: hasta `start_run()` no se agrega ni se manda nada.
var _run_active: bool = false
var _preset: String = CUSTOM_PRESET

# Acumuladores del día en curso (se ponen a cero en cada `day_summary`).
var _births: Dictionary = {}          # especie (String) -> int
var _deaths: Dictionary = {}          # "<causa>_<especie>" -> int
var _fights_started: int = 0
# bioma (String) -> {n, sigma_sum, sums: {rasgo: suma}, sq_sums: {rasgo: suma de cuadrados}}
var _birth_biomes: Dictionary = {}


func _ready() -> void:
	var key := OS.get_environment("AUGUR_KEY")
	if key.is_empty():
		return
	var endpoint := OS.get_environment("AUGUR_ENDPOINT")
	if endpoint.is_empty():
		endpoint = DEFAULT_ENDPOINT
	var label := OS.get_environment("BIOSPHERA_RUN_LABEL")
	if not label.is_empty():
		run_label = label
	# Raíz de Augur propia (p.ej. `user://augur_run_1/`): la usan las partidas de
	# `tools/measure_stage.sh` para no compartir `user://augur/` (el SDK de una
	# borraría las sesiones de las otras). Tiene que ir antes de `configure()`.
	var root := OS.get_environment("BIOSPHERA_AUGUR_ROOT")
	if not root.is_empty():
		Augur._set_test_root(root)
	Augur.configure(key, endpoint)
	enabled = true
	_reset_day()
	EventLog.event_logged.connect(_on_event)
	Climate.day_rolled.connect(_on_day_rolled)
	Augur.closing.connect(_on_closing)


## Guarda la decisión del jugador. Sin clave no hace nada.
func set_consent(granted: bool) -> void:
	if enabled:
		Augur.set_consent(granted)


## true si hay clave y el jugador aún no ha decidido (hay que enseñar la pantalla).
func needs_consent_decision() -> bool:
	return enabled and not Augur.has_consent_decision()


## true si hay clave y el jugador aceptó.
func has_consent() -> bool:
	return enabled and Augur.has_consent()


## Lo llama StartScreen justo antes de cambiar a la simulación, con `SimConfig`
## ya escrito. `preset` es el `display_name` del escenario elegido, o
## "Personalizado". Manda `run_start` y pone a cero los acumuladores.
## `loaded` marca una partida cargada de un save (las gráficas pueden filtrarla).
## Al cargar, `Climate` aún no está restaurado (eso pasa en `SaveGame.restore`, tras
## cambiar de escena): quien llama pasa el `day` del save; con -1 se usa `Climate`.
func start_run(preset: String = CUSTOM_PRESET, loaded: bool = false, day: int = -1) -> void:
	if not enabled:
		return
	_preset = preset if not preset.is_empty() else CUSTOM_PRESET
	_run_active = true
	_reset_day()
	_track("run_start", {
		"preset": _preset,
		"biome_seed": SimConfig.biome_seed,
		"pop_per_species": SimConfig.initial_population_per_species,
		"initial_plants": SimConfig.initial_plants,
		"loaded": loaded,
	}, day if day >= 0 else Climate.day_index)


func _on_event(e: Dictionary) -> void:
	if not _run_active:
		return
	var kind: String = e.get("kind", "")
	var data: Dictionary = e.get("data", {})
	match kind:
		"birth":
			var sp_b: String = _species_from_category(e.get("category", ""))
			_births[sp_b] = int(_births.get(sp_b, 0)) + 1
			if data.has("biome"):
				_accumulate_birth_biome(data)
		"death":
			var key: String = "%s_%s" % [str(data.get("cause", "")), _species_from_category(e.get("category", ""))]
			_deaths[key] = int(_deaths.get(key, 0)) + 1
		"action_change":
			if str(data.get("new_action", "")) == "fight":
				_fights_started += 1
		_:
			if FORWARDED_KINDS.has(kind):
				_track(kind, _flat_props(data), Climate.day_index)


## `day_index` es el día que EMPIEZA: el resumen es del que acaba (`day_index - 1`).
func _on_day_rolled(day_index: int) -> void:
	if not _run_active:
		return
	_emit_day(day_index - 1, false)


## Cierre de ventana: el día en curso sale con `partial: true` (el SDK avisa
## antes de cerrar la sesión, así que entra en ella).
func _on_closing() -> void:
	if not _run_active:
		return
	_emit_day(Climate.day_index, true)
	_run_active = false


func _emit_day(day: int, partial: bool) -> void:
	var days_per_season: int = maxi(1, GlobalParams.tuning.days_per_season)
	var season: int = (day / days_per_season) % Climate.SEASONS_PER_YEAR
	var props: Dictionary = {
		"preset": _preset,
		"season": season,
		"year": day / (days_per_season * Climate.SEASONS_PER_YEAR),
		"t_sim": Climate.sim_time,
		"partial": partial,
		"fights_started": _fights_started,
	}
	for sp in SPECIES:
		props["births_%s" % sp] = int(_births.get(sp, 0))
		for cause in DEATH_CAUSES:
			props["deaths_%s_%s" % [cause, sp]] = int(_deaths.get("%s_%s" % [cause, sp], 0))
	_add_population_snapshot(props)
	_track("day_summary", props, day)
	_emit_birth_biomes(day, season)
	_reset_day()


## Foto de la población al cierre del día: un recorrido de esferas por día simulado.
func _add_population_snapshot(props: Dictionary) -> void:
	var tree: SceneTree = get_tree()
	var pop: Dictionary = {"A": 0, "B": 0}
	var max_generation: int = 0
	var alive: int = 0
	var sums: Dictionary = {}
	for key in PHYSICAL_KEYS:
		sums[key] = 0.0
	for key in Traits.BEHAVIOR_KEYS:
		sums[String(key)] = 0.0
	for s in tree.get_nodes_in_group(&"spheres"):
		if not (s is Sphere):
			continue
		var sphere: Sphere = s
		var sp: String = String(sphere.genome.get("species", &"?"))
		if pop.has(sp):
			pop[sp] = int(pop[sp]) + 1
		max_generation = maxi(max_generation, sphere.generation)
		alive += 1
		for key in sums:
			sums[key] = float(sums[key]) + float(sphere.genome.get(key, 0.0))
	props["pop_A"] = int(pop["A"])
	props["pop_B"] = int(pop["B"])
	props["plants"] = tree.get_nodes_in_group(&"plants").size()
	props["max_generation"] = max_generation
	props["groups"] = Groups.get_groups_summary().size()
	props["farms"] = tree.get_nodes_in_group(&"farms").size()
	props["nests"] = Groups.count_owned_nests()
	for key in sums:
		props["avg_%s" % key] = float(sums[key]) / float(alive) if alive > 0 else 0.0


func _accumulate_birth_biome(data: Dictionary) -> void:
	var biome: String = str(data.get("biome", ""))
	if not _birth_biomes.has(biome):
		var acc: Dictionary = {"n": 0, "sigma_sum": 0.0, "sums": {}, "sq_sums": {}}
		for key in PHYSICAL_KEYS:
			acc["sums"][key] = 0.0
			acc["sq_sums"][key] = 0.0
		_birth_biomes[biome] = acc
	var b: Dictionary = _birth_biomes[biome]
	b["n"] = int(b["n"]) + 1
	b["sigma_sum"] = float(b["sigma_sum"]) + float(data.get("sigma", 0.0))
	for key in PHYSICAL_KEYS:
		var v: float = float(data.get(key, 0.0))
		b["sums"][key] = float(b["sums"][key]) + v
		b["sq_sums"][key] = float(b["sq_sums"][key]) + v * v


func _emit_birth_biomes(day: int, season: int) -> void:
	for biome in _birth_biomes:
		var b: Dictionary = _birth_biomes[biome]
		var n: int = int(b["n"])
		var props: Dictionary = {
			"season": season,
			"biome": biome,
			"n": n,
			"sigma_avg": float(b["sigma_sum"]) / float(n) if n > 0 else 0.0,
		}
		for key in PHYSICAL_KEYS:
			var variance: float = 0.0
			if n >= 2:
				var mean: float = float(b["sums"][key]) / float(n)
				variance = maxf(0.0, float(b["sq_sums"][key]) / float(n) - mean * mean)
			props["%s_var" % key] = variance
		_track("birth_biome", props, day)


func _reset_day() -> void:
	_births.clear()
	_deaths.clear()
	_fights_started = 0
	_birth_biomes.clear()


## Único punto de salida hacia el SDK. Añade `run_label` y `day`.
func _track(event_name: String, props: Dictionary, day: int) -> void:
	if not enabled:
		return
	props["run_label"] = run_label
	props["day"] = day
	Augur.track(event_name, props)


## Copia los campos escalares de `data`: descarta Array/Dictionary (p. ej.
## `position`) y cualquier otro tipo no plano; `StringName` → `String`.
static func _flat_props(data: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in data:
		var v: Variant = data[k]
		match typeof(v):
			TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
				out[String(k)] = v
			TYPE_STRING_NAME:
				out[String(k)] = String(v)
	return out


static func _species_from_category(category: String) -> String:
	# "sphere_A" -> "A"
	if category.begins_with("sphere_"):
		return category.substr(7)
	return "?"
