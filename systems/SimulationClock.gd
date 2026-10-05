extends Node
## Reloj global de simulación.
##
## Autoload `SimulationClock`. La simulación avanza en pasos fijos de
## `DT_SIM` segundos: exactamente un paso (`tick`) por frame de física.
##
## La velocidad (x2/x4/x8…) se aplica ejecutando N pasos de simulación por frame
## de física: a x2 corren 2 ticks por frame, a x8 corren 8, etc. (con acumulador
## fraccionario para x0.5). CADA tick es un paso idéntico (mismo `DT_SIM`), así
## que la sim avanza más rápido sin cambiar de comportamiento.
##
## Por qué NO `Engine.time_scale`: en Godot 4 subir `time_scale` NO aumenta la
## frecuencia de `_physics_process` (sigue fija en `physics_ticks_per_second`),
## sino que estira el `delta` de cada tick. Como aquí cada tick usa un `DT_SIM`
## fijo e ignora el `delta`, `time_scale` no tenía ningún efecto y la sim quedaba
## clavada a x1 a cualquier velocidad. Por eso `time_scale` se deja siempre en 1.0
## y la velocidad se controla con el nº de ticks por frame.
##
## Consecuencia clave: la simulación es invariante a la velocidad. Decisión
## y movimiento (ambos por tick) avanzan siempre en lockstep 1:1 — x8 es x1
## ocho veces más rápido, no un comportamiento distinto.
##
## Ver docs: docs/Programación.md (sección "Tick de simulación").

signal tick(dt_sim: float)
signal paused_changed(is_paused: bool)
signal speed_changed(speed: float)

const TICKS_PER_SECOND: float = 30.0
const DT_SIM: float = 1.0 / TICKS_PER_SECOND
const SPEEDS: Array[float] = [0.0, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]

var speed: float = 1.0:
	set(value):
		var clamped: float = clampf(value, 0.0, 16.0)
		if is_equal_approx(clamped, speed):
			return
		speed = clamped
		speed_changed.emit(speed)
		paused_changed.emit(is_paused())

var _tick_count: int = 0
## Acumulador de pasos fraccionarios: a x0.5 suma 0.5 por frame y dispara un tick
## cada dos frames; a x2 suma 2 y dispara dos ticks por frame. El resto fraccionario
## se arrastra entre frames para no perder ni inventar pasos.
var _tick_accumulator: float = 0.0

## Registro de entidades que se tickean (esferas, plantas, cadáveres). Antes cada
## entidad conectaba su `_on_tick` a la señal `tick`: con cientos-miles de
## conexiones, el despacho de Callables de la señal dominaba el tiempo propio de
## `_physics_process` (medido en profiler, 2026-06-08). Aquí las recorremos con
## llamadas directas en un solo bucle, mucho más barato que emitir a N conexiones.
## La señal `tick` se conserva para los pocos listeners de sistema/UI.
var _entities: Array = []        # cadencia plena (30 Hz): esferas
var _ticking: bool = false
var _pending_remove: Array = []

## Entidades de cadencia lenta (plantas, cadáveres): no se mueven y sus procesos
## son lentos (crecimiento 12 s, vida madura 45 s, descomposición 30 s), así que
## tickear cada frame —incluida una query espacial de polinización por planta
## madura— es despilfarro. Se tickean 1 de cada `SLOW_STRIDE` frames, repartidas
## en franjas por índice, con `dt` escalado (la lógica de planta/cadáver acumula
## linealmente, así que es exacta con cualquier dt). Recorta su coste ~SLOW_STRIDE×
## y reduce el tamaño del bucle por frame, sin tocar la fluidez de las esferas.
const SLOW_STRIDE: int = 6
var _slow: Array = []

## Las esferas también se reparten en franjas: cada una tickea cada `SPHERE_STRIDE`
## frames con `dt` escalado (recorta el bucle y `_on_tick` ~SPHERE_STRIDE×). El
## movimiento se integra manualmente en `Sphere._move` (sin `move_and_slide`, que
## está acoplado a `physics_delta`) y `EntityRenderer` interpola la posición del
## cuerpo para que el movimiento se vea fluido pese a mover a 30/SPHERE_STRIDE Hz.
## Poner 1 desactiva el time-slice de esferas (tick cada frame).
const SPHERE_STRIDE: int = 2


## Alta/baja en el bucle central. Las entidades llaman a esto en su `activate()`
## (último paso del spawn) y en su limpieza, en lugar de `tick.connect/disconnect`.
## `slow = true` → cadencia reducida (plantas, cadáveres). El orden de registro =
## orden de tick (igual que el orden de conexión anterior).
func register_entity(e: Object, slow: bool = false) -> void:
	if slow:
		_slow.append(e)
	else:
		_entities.append(e)


func unregister_entity(e: Object) -> void:
	# Durante el bucle no se puede `erase` (desplazaría índices): se difiere.
	if _ticking:
		_pending_remove.append(e)
	else:
		_entities.erase(e)
		_slow.erase(e)


func _ready() -> void:
	# Base de física a la tasa de simulación: a x1 corre 1 tick por frame de física.
	# La velocidad >x1 NO se obtiene de más frames (ver cabecera) sino de más ticks
	# por frame, así que `time_scale` se fija en 1.0 de forma permanente: la cámara
	# y la UI corren en tiempo real y la pausa solo suprime ticks (no congela todo).
	Engine.physics_ticks_per_second = int(TICKS_PER_SECOND)
	Engine.time_scale = 1.0


func _physics_process(_delta: float) -> void:
	# La velocidad = nº de pasos `DT_SIM` por frame de física (no `time_scale`, que
	# en Godot 4 estira el delta sin aumentar la frecuencia de este callback). Cada
	# tick es siempre el mismo paso de simulación; a x2 corren dos, a x8 ocho.
	if speed <= 0.0:
		return
	_tick_accumulator += speed
	var steps: int = int(_tick_accumulator)
	_tick_accumulator -= float(steps)
	for _i in steps:
		_run_one_tick()


## Un paso de simulación de `DT_SIM`. Lo invoca `_physics_process` tantas veces por
## frame como dicte la velocidad.
func _run_one_tick() -> void:
	_tick_count += 1
	# Sistemas globales y UI (~7 listeners): siguen por señal, su coste es nimio.
	tick.emit(DT_SIM)
	# Entidades (cientos-miles): bucle directo. Se fija el conteo al inicio para
	# que los recién nacidos (que se registran durante este mismo tick, p. ej. al
	# reproducirse) NO se tickeen hasta el siguiente paso — misma semántica que
	# el snapshot de conexiones de `emit()`. El borrado de los que mueren se
	# difiere (ver `unregister_entity`) para no desplazar índices a mitad de bucle.
	_ticking = true
	# Esferas: solo la franja de este paso, con dt escalado (time-slice).
	var n: int = _entities.size()
	var sphere_dt: float = DT_SIM * float(SPHERE_STRIDE)
	var i: int = _tick_count % SPHERE_STRIDE
	while i < n:
		var e: Object = _entities[i]
		if is_instance_valid(e):
			e._on_tick(sphere_dt)
		i += SPHERE_STRIDE
	# Plantas/cadáveres: solo la franja de este paso, con dt escalado.
	var m: int = _slow.size()
	var slow_dt: float = DT_SIM * float(SLOW_STRIDE)
	var j: int = _tick_count % SLOW_STRIDE
	while j < m:
		var se: Object = _slow[j]
		if is_instance_valid(se):
			se._on_tick(slow_dt)
		j += SLOW_STRIDE
	_ticking = false
	if not _pending_remove.is_empty():
		for re in _pending_remove:
			_entities.erase(re)
			_slow.erase(re)
		_pending_remove.clear()


func is_paused() -> bool:
	return speed <= 0.0


func toggle_pause() -> void:
	if is_paused():
		set_speed(1.0)
	else:
		set_speed(0.0)


func set_speed(value: float) -> void:
	speed = value


func cycle_speed(direction: int = 1) -> void:
	var current_index: int = 0
	for i in SPEEDS.size():
		if is_equal_approx(SPEEDS[i], speed):
			current_index = i
			break
	var next_index: int = clampi(current_index + direction, 0, SPEEDS.size() - 1)
	set_speed(SPEEDS[next_index])


## Restaura el reloj desde un guardado (ver `SaveGame.restore`). Va ANTES de activar
## las entidades: `Sphere.activate` lee `get_tick_count()` para `_interp_tick`, y la
## franja de tick de cada esfera depende de `_tick_count % SPHERE_STRIDE` frente a su
## posición en `_entities`. Restaurar el contador conserva la fase de toda la población.
## La velocidad pasa por el setter para avisar a la UI (`speed_changed`).
func restore_state(tick_count: int, new_speed: float, accumulator: float) -> void:
	assert(not _ticking, "restore_state dentro del tick")
	_tick_count = tick_count
	speed = new_speed
	_tick_accumulator = accumulator


func get_tick_count() -> int:
	return _tick_count


func get_sim_time() -> float:
	return _tick_count * DT_SIM
