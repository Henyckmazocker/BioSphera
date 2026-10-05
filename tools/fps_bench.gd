extends SceneTree
## Medición de FPS con ventana (plan «Game Feel y Efectos Juicy», M0).
##
## Monta `Main` (World + Hud) sin pasar por `StartScreen`, con el preset Génesis y
## `N/2` esferas por especie, ventana de 1600×900 sin vsync, vista cenital por
## defecto de `CameraRig` y velocidad ×1. Calienta 10 s y mide 30 s de frames
## reales; imprime una sola línea de resultado:
##   [fps_bench] spheres=<n_final> fx=<…> halo=<…> avg_ms=<…> p99_ms=<…> fps=<…>
##
## Uso (siempre con ventana, nunca --headless, y siempre con run_godot.sh):
##   env -u AUGUR_KEY tools/run_godot.sh 90 --path . --script res://tools/fps_bench.gd -- --spheres=100 --fx=off
##
## `--fx=off|low|medium|high` fija `UserSettings.effects_intensity` solo para este
## proceso: se carga primero el fichero de David (`load_settings`, que marca la carga
## como hecha) y luego se **asigna la variable estática** sin `set_*`, que guardaría y
## pisaría sus preferencias. Cuando `World._ready` llama a `load_settings()` no relee
## (es idempotente), así que el nivel del bench se mantiene.
##
## `--halo=always|hover|never` fija igual `UserSettings.halo_mode` (sin guardar); si no
## se pasa, se queda el de las preferencias de David.
##
## 🔴 No nombrar `class_name` de entidades (Sphere, EntityModel…): compilaría
## `entities/Sphere.gd` antes que los autoloads (ver skill ver-el-juego).
##
## Ver docs: docs/Planes/…/Plan - Game Feel y Efectos Juicy.md (sección 🔴 y M0).

const MAIN_SCENE: String = "res://main/Main.tscn"
const PRESET_PATH: String = "res://data/presets/genesis.tres"
const FX_LEVELS: PackedStringArray = ["off", "low", "medium", "high"]
## Mismo orden que `UserSettings.HaloMode`.
const HALO_MODES: PackedStringArray = ["always", "hover", "never"]
const DEFAULT_SPHERES: int = 100
const BENCH_SEED: int = 20261005
const WINDOW_SIZE: Vector2i = Vector2i(1600, 900)
const WARMUP_S: float = 10.0
const MEASURE_S: float = 30.0
## Tope de espera a que el Spawner siembre la población (arranque + navmesh).
const POPULATE_TIMEOUT_S: float = 60.0

var _started: bool = false


func _process(_delta: float) -> bool:
	# Los nodos se montan aquí: en _initialize() aún no hay root utilizable.
	if _started:
		return false
	_started = true
	_run()
	return false


func _run() -> void:
	var opts: Dictionary = _parse_args(OS.get_cmdline_user_args())
	if opts.is_empty():
		quit(1)
		return
	var n_req: int = int(opts["spheres"])
	var fx: String = String(opts["fx"])

	# Sin JSONL a disco ni autoguardado: el bench no debe dejar nada en el user:// de David.
	root.get_node("EventLog").enabled_disk = false
	var sim_config: Node = root.get_node("SimConfig")
	sim_config.autosave_enabled = false
	sim_config.apply_preset(load(PRESET_PATH))
	sim_config.initial_population_per_species = maxi(1, n_req / 2)
	sim_config.preset_name = "fps_bench"
	sim_config.apply_to_global_params()
	seed(BENCH_SEED)
	UserSettings.load_settings()
	UserSettings.effects_intensity = FX_LEVELS.find(fx)  # mismo orden que EffectsIntensity
	if opts.has("halo"):
		UserSettings.halo_mode = HALO_MODES.find(String(opts["halo"]))
	var halo: String = HALO_MODES[UserSettings.halo_mode]

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(WINDOW_SIZE)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var main: Node = load(MAIN_SCENE).instantiate()
	root.add_child(main)
	current_scene = main
	# El Spawner siembra frames después (espera al navmesh): da tiempo a fijar su RNG,
	# que se aleatoriza en su _ready.
	var spawner: Node = main.get_node_or_null("World/Spawner")
	if spawner != null and spawner.get("_rng") is RandomNumberGenerator:
		spawner._rng.seed = BENCH_SEED
	# CameraRig ya arranca en la vista cenital por defecto (`_apply_top_down_reset` en su _ready).

	var t_wait: int = Time.get_ticks_msec()
	while spawner != null and not bool(spawner.get("populated")):
		await process_frame
		if Time.get_ticks_msec() - t_wait > int(POPULATE_TIMEOUT_S * 1000.0):
			push_error("[fps_bench] el Spawner no sembró en %.0f s" % POPULATE_TIMEOUT_S)
			quit(1)
			return
	root.get_node("SimulationClock").set_speed(1.0)

	# Calentamiento.
	var t0: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < int(WARMUP_S * 1e6):
		await process_frame

	# Medida: duración real de cada frame entre dos process_frame consecutivos.
	var frames: PackedFloat64Array = PackedFloat64Array()
	var t_start: int = Time.get_ticks_usec()
	var t_prev: int = t_start
	while t_prev - t_start < int(MEASURE_S * 1e6):
		await process_frame
		var now: int = Time.get_ticks_usec()
		frames.append((now - t_prev) / 1000.0)
		t_prev = now
	var total_s: float = (t_prev - t_start) / 1e6

	var sum_ms: float = 0.0
	for f in frames:
		sum_ms += f
	var sorted: Array = Array(frames)
	sorted.sort()
	var p99: float = float(sorted[clampi(int(ceil(sorted.size() * 0.99)) - 1, 0, sorted.size() - 1)])
	var n_final: int = get_nodes_in_group(&"spheres").size()
	print("[fps_bench] spheres=%d fx=%s halo=%s avg_ms=%.2f p99_ms=%.2f fps=%.1f" % [
		n_final, fx, halo, sum_ms / maxf(frames.size(), 1.0), p99, frames.size() / maxf(total_s, 0.001)])
	quit(0)


## Lee `--spheres=<N>`, `--fx=<nivel>` y `--halo=<modo>` (opcional). Devuelve {} (y error)
## si algo no es válido.
func _parse_args(args: PackedStringArray) -> Dictionary:
	var out: Dictionary = {"spheres": DEFAULT_SPHERES, "fx": "off"}
	for a in args:
		if a.begins_with("--spheres=") and a.trim_prefix("--spheres=").is_valid_int():
			out["spheres"] = maxi(2, a.trim_prefix("--spheres=").to_int())
		elif a.begins_with("--fx=") and a.trim_prefix("--fx=") in FX_LEVELS:
			out["fx"] = a.trim_prefix("--fx=")
		elif a.begins_with("--halo=") and a.trim_prefix("--halo=") in HALO_MODES:
			out["halo"] = a.trim_prefix("--halo=")
		else:
			push_error("[fps_bench] argumento no válido: '%s' (--spheres=<N> --fx=%s --halo=%s)" % [
				a, "|".join(FX_LEVELS), "|".join(HALO_MODES)])
			return {}
	return out
