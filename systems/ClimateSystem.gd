extends Node
## Ciclo natural: día/noche + estaciones + año.
##
## Autoload `Climate`. No editable directamente por el jugador (solo
## acelerable subiendo la velocidad del `SimulationClock`).
##
## - Día: `GlobalParams.tuning.seconds_per_day` (def. 75 s sim).
## - Estación: `GlobalParams.tuning.days_per_season` días (def. 10, año = 3000 s sim).
## - Año: 4 estaciones (constante estructural).
##
## Emite señales para que el resto del juego pueda reaccionar y para que
## un nodo de luz (sol) pueda orbitar según `day_progress`.
##
## También es el emisor de los eventos del entorno (`EnvironmentEvent`): lleva
## los activos y compone sus multiplicadores con los estacionales. Nadie más sabe
## qué evento hay; plantas y spawner consultan `pollination_modifier()` y
## `plant_wilt_modifier()`, las esferas `sphere_mod()` y la genética `mutation_pressure()`.
## Como mucho un evento por tipo: arrancar otro del mismo tipo reemplaza al activo.
##
## Ver docs: docs/GDD/Mundo y Niveles.md · docs/GDD/Mecánicas.md (eventos del entorno).

signal day_advanced(day_progress: float)  ## 0..1 dentro del día
signal day_rolled(day_index: int)
signal season_changed(season: int)        ## 0=primavera 1=verano 2=otoño 3=invierno
signal year_rolled(year: int)
signal env_event_started(kind: int, intensity: float, duration_days: float)
signal env_event_ended(kind: int)

# Cadencia (día/estación) configurable en vivo: ver `GlobalParams.tuning`
# (seconds_per_day, days_per_season). El año = 4 estaciones es estructural.
const SEASONS_PER_YEAR: int = 4

## Lista de eventos aleatorios cuando el preset no trae la suya (`_get_random_pool`).
const DEFAULT_RANDOM_POOL: PackedStringArray = [
	"res://data/events/sequia.tres",
	"res://data/events/ola_de_frio.tres",
	"res://data/events/tormenta.tres",
	"res://data/events/abundancia.tres",
	"res://data/events/plaga.tres",
]

const SEASON_NAMES: Array[String] = ["Primavera", "Verano", "Otoño", "Invierno"]

var sim_time: float = 0.0
var day_progress: float = 0.0
var day_index: int = 0
var season_index: int = 0
var year: int = 0

# La estación inicial (Primavera/año 0) se registra en el primer tick, no al
# cambiar: así `world.jsonl` no arranca vacío y el análisis ve el punto de partida.
var _initial_logged: bool = false

# Eventos activos: {path, event, kind, intensity, t_start, duration_s, ramp_s, strain}.
# Tiempos en `sim_time` y duraciones fijadas al arrancar (días × seconds_per_day):
# si `seconds_per_day` cambia en vivo, un evento en curso no se estira. `event` es
# el recurso ya cargado (para no releer `path` en cada consulta); el guardado
# solo lleva `path` y `from_save` lo recarga.
var _active: Array[Dictionary] = []
# Productos de los multiplicadores de eventos (rampa incluida), recalculados una
# vez por tick: cada planta madura y cada esfera los consultan en su tick.
var _event_pollination_mult: float = 1.0
var _event_wilt_mult: float = 1.0
var _event_metabolism_mult: float = 1.0
var _event_speed_mult: float = 1.0
var _event_vision_mult: float = 1.0
# Σ `mutation_pressure × intensidad × ramp_01` de los activos (sin acotar).
var _event_mutation_pressure: float = 0.0
# Cepa de la plaga en curso (o la última): cada `start_event` de plaga la incrementa,
# así que la inmunidad a una cepa (`Sphere._plague_immune_strain`) no protege de la siguiente.
var _plague_strain: int = 0
# RNG propio del clima (tirada diaria de eventos aleatorios): su `seed` y su `state`
# entran en el guardado para que la secuencia siga igual tras cargar.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Pool de la tirada aleatoria, cargado de `SimConfig.random_event_pool_paths` una vez
# por partida: se recarga solo si cambian las rutas (partida nueva o save cargado).
var _random_pool: Array[EnvironmentEvent] = []
var _random_pool_paths: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_rng.randomize()
	SimulationClock.tick.connect(_on_tick)


## Estado del ciclo para el guardado (ver `SaveGame`). `day_progress`, `day_index`,
## `season_index` y `year` se derivan de `sim_time` en cada tick, pero se guardan igual:
## entre la carga y el primer tick los leen el HUD y el sol, y la captura de ida y
## vuelta del arnés (`tools/save_load_test.gd`) los compara campo a campo.
## Los eventos activos van sin el recurso (`event`), solo con su `path`.
func to_save() -> Dictionary:
	var events: Array = []
	for a in _active:
		events.append({
			"path": a["path"],
			"kind": a["kind"],
			"intensity": a["intensity"],
			"t_start": a["t_start"],
			"duration_s": a["duration_s"],
			"ramp_s": a["ramp_s"],
			"strain": a["strain"],
		})
	return {
		"sim_time": sim_time,
		"day_progress": day_progress,
		"day_index": day_index,
		"season_index": season_index,
		"year": year,
		"events": events,
		"plague_strain": _plague_strain,
		"rng_seed": _rng.seed,
		"rng_state": _rng.state,
	}


## Restaura el ciclo desde `to_save`. `_initial_logged = true`: la estación inicial ya
## se registró en la partida original; relanzarla metería un `season` falso en el log.
## Por lo mismo, los eventos activos se restauran sin `env_event_started` ni
## `env_event_start`: ya se emitieron al arrancarlos. Un `path` que no carga se
## descarta con aviso (save de una versión con eventos que ya no existen).
func from_save(d: Dictionary) -> void:
	sim_time = float(d.get("sim_time", 0.0))
	day_progress = float(d.get("day_progress", 0.0))
	day_index = int(d.get("day_index", 0))
	season_index = int(d.get("season_index", 0))
	year = int(d.get("year", 0))
	_initial_logged = true
	_active.clear()
	for e in d.get("events", []):
		var ev: EnvironmentEvent = load(String(e["path"])) as EnvironmentEvent
		if ev == null:
			push_warning("Climate.from_save: evento '%s' no carga; se descarta" % e["path"])
			continue
		_active.append({
			"path": String(e["path"]),
			"event": ev,
			"kind": int(e["kind"]),
			"intensity": float(e["intensity"]),
			"t_start": float(e["t_start"]),
			"duration_s": float(e["duration_s"]),
			"ramp_s": float(e["ramp_s"]),
			"strain": int(e["strain"]),
		})
	_plague_strain = int(d.get("plague_strain", 0))
	# `seed` antes que `state`: asignar la semilla reinicia el estado.
	if d.has("rng_seed"):
		_rng.seed = int(d["rng_seed"])
		_rng.state = int(d.get("rng_state", _rng.state))
	_recompute_event_mults()


func current_season_name() -> String:
	return SEASON_NAMES[season_index]


## Multiplicador de productividad vegetal según estación.
## Primavera y verano favorecen plantas; otoño/invierno la penalizan.
func plant_growth_modifier() -> float:
	match season_index:
		0: return 1.2  # primavera
		1: return 1.4  # verano
		2: return 0.8  # otoño
		_: return 0.5  # invierno


## Presión climática 0..1 sobre la mutación: escasez estacional de comida, no
## extremos térmicos (el verano es la estación de MÁS comida, no hostil).
## invierno 0.5 · otoño 0.2 · primavera/verano 0. Los eventos activos suman su
## `mutation_pressure × intensidad × ramp_01`; el total se acota a 0..1.
func mutation_pressure() -> float:
	return clampf(maxf(0.0, 1.0 - plant_growth_modifier()) + _event_mutation_pressure, 0.0, 1.0)


## Polinización de las plantas: la estación compuesta con los eventos activos
## (multiplica, no pisa: una sequía en invierno es peor que una en verano).
## `plant_growth_modifier()` sigue sin eventos: escala la edad, y con ella la
## marchitez, así que componer ahí la sequía alargaría la vida de las plantas.
func pollination_modifier() -> float:
	return plant_growth_modifier() * _event_pollination_mult


## Escala 0..1 de la comida que entra SIN polinizar (suelo de semillas del
## `Spawner` y siembra de las granjas) por los eventos: baja con la sequía y no
## sube con la abundancia (el tope es `plants_total_max`). 1.0 sin eventos.
func food_supply_scale() -> float:
	return minf(1.0, _event_pollination_mult)


## Aceleración de la marchitez de las plantas maduras (Π `wilt_mult`; 1.0 sin eventos).
func plant_wilt_modifier() -> float:
	return _event_wilt_mult


## Multiplicador de los eventos sobre un `*_mod` de esfera (`&"metabolism_mod"`,
## `&"speed_mod"`, `&"vision_mod"`); se compone con el del bioma en `Sphere._env_mod`.
## 1.0 sin eventos o con otra clave.
func sphere_mod(key: StringName) -> float:
	match key:
		&"metabolism_mod": return _event_metabolism_mult
		&"speed_mod": return _event_speed_mult
		&"vision_mod": return _event_vision_mult
	return 1.0


## Cepa de la plaga en curso, o de la última si no hay ninguna.
func plague_strain() -> int:
	return _plague_strain


## Fuerza 0..1 de la plaga activa (`intensidad × ramp_01`), 0 si no hay: abre y cierra
## la ventana de contagio (`Plague.try_infect`). Las infecciones en curso no dependen de ella.
func plague_strength() -> float:
	var idx: int = _find_active(EnvironmentEvent.Kind.PLAGUE)
	if idx < 0:
		return 0.0
	return float(_active[idx]["intensity"]) * _ramp_01(_active[idx])


## Eventos activos para HUD y analítica:
## `[{kind, name, intensity, ramp_01, days_left}]`, en orden de arranque.
func active_events() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seconds_per_day: float = GlobalParams.tuning.seconds_per_day
	for a in _active:
		var ev: EnvironmentEvent = a["event"]
		var left_s: float = float(a["t_start"]) + float(a["duration_s"]) - sim_time
		out.append({
			"kind": int(a["kind"]),
			"name": ev.display_name,
			"intensity": float(a["intensity"]),
			"ramp_01": _ramp_01(a),
			"days_left": maxf(left_s, 0.0) / seconds_per_day,
		})
	return out


## Arranca `ev` con `intensity` (< 0 → `ev.intensity`) y `duration_days`
## (< 0 → `ev.duration_days`; las herramientas de medición la sobrescriben sin
## duplicar el recurso). La rampa de entrada y la de salida van dentro de la
## duración, cada una de `ramp_days` como mucho la mitad. Si ya hay uno del mismo
## `kind`, lo reemplaza: el viejo se retira al momento (con `env_event_ended` y su
## `env_event_end`, para que el log quede emparejado) y el nuevo arranca de cero.
func start_event(ev: EnvironmentEvent, intensity: float = -1.0, duration_days: float = -1.0) -> void:
	var i: float = clampf(ev.intensity if intensity < 0.0 else intensity, 0.0, 1.0)
	var days: float = ev.duration_days if duration_days < 0.0 else duration_days
	var seconds_per_day: float = GlobalParams.tuning.seconds_per_day
	var duration_s: float = maxf(days * seconds_per_day, 0.0)
	var prev: int = _find_active(int(ev.kind))
	if prev >= 0:
		_active.remove_at(prev)
		_emit_ended(int(ev.kind))
	var strain: int = 0
	if ev.kind == EnvironmentEvent.Kind.PLAGUE:
		_plague_strain += 1
		strain = _plague_strain
	_active.append({
		"path": ev.resource_path,
		"event": ev,
		"kind": int(ev.kind),
		"intensity": i,
		"t_start": sim_time,
		"duration_s": duration_s,
		"ramp_s": minf(ev.ramp_days * seconds_per_day, duration_s * 0.5),
		"strain": strain,  # cepa: solo la plaga la usa (0 en el resto)
	})
	_recompute_event_mults()
	env_event_started.emit(int(ev.kind), i, days)
	EventLog.log_event(&"env_event_start", {
		"kind": _kind_name(int(ev.kind)),
		"intensity": i,
		"duration_days": days,
		"strain": strain,
	})
	# Pacientes cero tras el `env_event_start`, para que el log quede en orden.
	if ev.kind == EnvironmentEvent.Kind.PLAGUE:
		for s in Plague.pick_zeros(get_tree().get_nodes_in_group(&"spheres"), i):
			s.infect_plague(strain)


## Pasa el evento activo de tipo `kind` directamente a la rampa de salida: le queda
## `ramp_s × ramp_01` actual, así que baja desde donde está sin saltos (a mitad de la
## rampa de entrada, sale en el mismo tiempo que llevaba). Sin rampa, se retira en
## el siguiente tick. Nunca alarga el evento. Sin evento de ese tipo, no hace nada.
func stop_event(kind: int) -> void:
	var idx: int = _find_active(kind)
	if idx < 0:
		return
	var a: Dictionary = _active[idx]
	var elapsed: float = sim_time - float(a["t_start"])
	var remaining: float = float(a["ramp_s"]) * _ramp_01(a)
	a["duration_s"] = minf(float(a["duration_s"]), elapsed + remaining)
	_recompute_event_mults()


func is_night() -> bool:
	return day_progress < 0.25 or day_progress > 0.75


func _on_tick(dt_sim: float) -> void:
	sim_time += dt_sim
	var prev_day: int = day_index
	var prev_season: int = season_index
	var prev_year: int = year

	var seconds_per_day: float = GlobalParams.tuning.seconds_per_day
	var days_per_season: int = GlobalParams.tuning.days_per_season
	day_progress = fmod(sim_time, seconds_per_day) / seconds_per_day
	day_index = int(sim_time / seconds_per_day)
	season_index = (day_index / days_per_season) % SEASONS_PER_YEAR
	year = day_index / (days_per_season * SEASONS_PER_YEAR)

	if not _initial_logged:
		_initial_logged = true
		season_changed.emit(season_index)
		EventLog.log_event(&"season", {"season": current_season_name(), "year": year})

	day_advanced.emit(day_progress)
	if day_index != prev_day:
		day_rolled.emit(day_index)
	if season_index != prev_season:
		season_changed.emit(season_index)
		EventLog.log_event(&"season", {"season": current_season_name(), "year": year})
	if year != prev_year:
		year_rolled.emit(year)

	if not _active.is_empty():
		_retire_finished_events()
		_recompute_event_mults()
	if day_index != prev_day:
		_roll_random_event()


## Tirada diaria del disparo aleatorio: con `p = eventos_al_año / (4 × días_por_estación)`
## arranca un evento del pool cuyo tipo no esté activo (si todos lo están, nada), con
## intensidad uniforme en `SimConfig.random_intensity_range` y su duración por defecto.
## Con ritmo 0 o pool vacío no consume el RNG. El reemplazo por tipo es solo del manual.
func _roll_random_event() -> void:
	var per_year: float = GlobalParams.random_events_per_year
	if per_year <= 0.0:
		return
	var pool: Array[EnvironmentEvent] = _get_random_pool()
	if pool.is_empty():
		return
	var days_per_year: float = float(SEASONS_PER_YEAR * GlobalParams.tuning.days_per_season)
	if _rng.randf() >= per_year / maxf(days_per_year, 1.0):
		return
	var candidates: Array[EnvironmentEvent] = []
	for ev in pool:
		if _find_active(int(ev.kind)) < 0:
			candidates.append(ev)
	if candidates.is_empty():
		return
	var ev: EnvironmentEvent = candidates[_rng.randi_range(0, candidates.size() - 1)]
	var range_i: Vector2 = SimConfig.random_intensity_range
	start_event(ev, _rng.randf_range(minf(range_i.x, range_i.y), maxf(range_i.x, range_i.y)))


## Pool de la tirada aleatoria; lo (re)carga si las rutas de `SimConfig` cambiaron.
## Una ruta que no carga se descarta con aviso.
func _get_random_pool() -> Array[EnvironmentEvent]:
	# Sin lista en el preset (todos menos «Mundo en colapso», y «Personalizado») se usan
	# los cinco: el slider «Eventos al año» funciona en cualquier partida, y con el ritmo
	# a 0 de esos presets nada cambia hasta que el jugador lo mueve.
	var paths: PackedStringArray = SimConfig.random_event_pool_paths
	if paths.is_empty():
		paths = DEFAULT_RANDOM_POOL
	if paths != _random_pool_paths:
		_random_pool_paths = paths.duplicate()
		_random_pool.clear()
		for path in paths:
			var ev: EnvironmentEvent = load(path) as EnvironmentEvent
			if ev == null:
				push_warning("Climate: evento aleatorio '%s' no carga; se descarta" % path)
				continue
			_random_pool.append(ev)
	return _random_pool


## Retira los eventos cuya duración ya pasó (la rampa de salida los dejó en 0).
func _retire_finished_events() -> void:
	for idx in range(_active.size() - 1, -1, -1):
		var a: Dictionary = _active[idx]
		if sim_time < float(a["t_start"]) + float(a["duration_s"]):
			continue
		_active.remove_at(idx)
		_emit_ended(int(a["kind"]))


func _emit_ended(kind: int) -> void:
	env_event_ended.emit(kind)
	EventLog.log_event(&"env_event_end", {"kind": _kind_name(kind)})


## Índice en `_active` del evento de tipo `kind`, o -1 (hay como mucho uno por tipo).
func _find_active(kind: int) -> int:
	for idx in _active.size():
		if int(_active[idx]["kind"]) == kind:
			return idx
	return -1


## Rampa trapezoidal 0..1: sube en `ramp_s`, se queda en 1 y baja en los últimos `ramp_s`.
func _ramp_01(a: Dictionary) -> float:
	var ramp_s: float = float(a["ramp_s"])
	if ramp_s <= 0.0:
		return 1.0
	var elapsed: float = sim_time - float(a["t_start"])
	var remaining: float = float(a["duration_s"]) - elapsed
	return clampf(minf(elapsed, remaining) / ramp_s, 0.0, 1.0)


func _recompute_event_mults() -> void:
	var poll: float = 1.0
	var wilt: float = 1.0
	var metab: float = 1.0
	var speed: float = 1.0
	var vision: float = 1.0
	var mut: float = 0.0
	for a in _active:
		var ev: EnvironmentEvent = a["event"]
		var w: float = float(a["intensity"]) * _ramp_01(a)
		poll *= lerpf(1.0, ev.pollination_mult, w)
		wilt *= lerpf(1.0, ev.wilt_mult, w)
		metab *= lerpf(1.0, ev.metabolism_mult, w)
		speed *= lerpf(1.0, ev.speed_mult, w)
		vision *= lerpf(1.0, ev.vision_mult, w)
		mut += ev.mutation_pressure * w
	_event_pollination_mult = poll
	_event_wilt_mult = wilt
	_event_metabolism_mult = metab
	_event_speed_mult = speed
	_event_vision_mult = vision
	_event_mutation_pressure = mut


## Nombre del tipo para el log («drought», «cold_wave»…), el mismo de `BIOSPHERA_EVENT`.
func _kind_name(kind: int) -> String:
	return String(EnvironmentEvent.Kind.find_key(kind)).to_lower()
