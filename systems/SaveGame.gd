class_name SaveGame
extends RefCounted
## Guardado y carga de partidas: foto del estado de la simulación a disco y vuelta.
##
## Solo funciones estáticas, sin autoload: `SimConfig.pending_save` ya cruza la frontera
## `StartScreen` → `World`, y el `CLAUDE.md` del repo pide justificar cada autoload.
##
## Formato: `var_to_str`/`str_to_var` (texto Godot). Conserva `Vector3`, `StringName` y
## las claves `int` de los diccionarios (JSON las convertiría a String) y se puede
## inspeccionar y diffear (`store_var` no). `str_to_var` puede construir objetos: se
## acepta porque los saves son ficheros locales del jugador, pero `read` valida la forma.
##
## Reglas que mandan (ver el plan «Guardado y Carga de Escenarios», sección del riesgo):
## - El orden de `entities` es el orden de tick (`SimulationClock._entities`): activar
##   en ese orden reproduce la franja de tick de cada esfera sin tabla de orden aparte.
## - Las referencias cruzadas se guardan como índice de save, nunca como `instance_id`.
## - Restaurar: reloj → clima → entidades (instanciar todas, luego `from_save` en orden)
##   → Groups → Relationships → Territory → Genetics → Stats (el último: los `spawn` de
##   `activate()` no deben tocar sus contadores).
## - Los ids de grupo salen de un contador propio (`GroupSystem.new_group_id`), estable
##   entre procesos: van tal cual en esferas, granjas, plantas, grupos y territorio.
##
## Estado del esquema (M2): `config` (con `preset_name`, M3), `params`, `clock`, `climate`, `spawner`, todas las
## entidades (`sphere`, `plant`, `tree`, `farm`, `corpse`, `deposit`) con los objetivos
## de la IA, y `groups`, `relationships`, `territory`, `stats` y `genetics`.
##
## Ver docs: docs/Programación.md (sección "Persistencia").

const SCHEMA_VERSION: int = 1
const DIR: String = "user://saves/"
const SLOT_MANUAL: String = "manual"
const SLOT_AUTO: String = "auto"

const SPHERE_SCENE: PackedScene = preload("res://entities/Sphere.tscn")
const PLANT_SCENE: PackedScene = preload("res://entities/Plant.tscn")
const TREE_SCENE: PackedScene = preload("res://entities/Tree.tscn")
const DEPOSIT_SCENE: PackedScene = preload("res://entities/Deposit.tscn")
const FARM_SCENE: PackedScene = preload("res://entities/Farm.tscn")
const CORPSE_SCENE: PackedScene = preload("res://entities/Corpse.tscn")

## Campos de `SimConfig` que definen la partida (los que lee el mundo al construirse).
## `pending_save` no entra nunca; `biome_seed` se guarda aparte con la semilla RESUELTA.
const CONFIG_KEYS: Array[StringName] = [
	&"world_size", &"initial_plants", &"initial_population_per_species", &"min_plant_seeds",
	&"initial_wood", &"initial_stone", &"initial_gold", &"min_stone", &"min_gold",
	&"initial_trait_means", &"spawn_split", &"apex_enabled", &"apex_size", &"apex_species",
	&"population_size_max",
	&"food_respawn_per_second", &"target_food", &"mutation_base_rate", &"lifespan_multiplier",
	&"preset_name", &"random_events_per_year", &"random_event_pool_paths", &"random_intensity_range",
]

## Parámetros vivos de `GlobalParams` (ajustables por el jugador en partida). `tuning`
## no se guarda: es un preload compartido y congelarlo impediría re-balancear. Tampoco
## `experimentation_mode`, que es un modo de UI y no un parámetro de la simulación.
const PARAM_KEYS: Array[StringName] = [
	&"mutation_base_rate", &"mutation_stress_factor", &"mutation_inbreeding_factor",
	&"mutation_age_factor", &"mutation_climate_factor", &"mutation_biome_factor",
	&"aggression_modifier", &"sociability_modifier", &"reproductive_appetite_modifier",
	&"territoriality_modifier", &"food_respawn_per_second", &"target_food",
	&"social_memory_capacity", &"lifespan_multiplier", &"random_events_per_year",
]


static func path_for(slot: String) -> String:
	return DIR + slot + ".sav"


## Foto completa del estado en memoria (no escribe). Nunca dentro del tick: con
## `_ticking` aún no se han aplicado las bajas diferidas (`_pending_remove`) y la foto
## incluiría esferas muertas en posiciones que desplazan el orden.
static func capture(spawner: Node) -> Dictionary:
	assert(not SimulationClock._ticking, "SaveGame.capture dentro del tick")
	var nodes: Array = capture_order()
	var ids: Dictionary = {}
	for i in nodes.size():
		ids[nodes[i].get_instance_id()] = i
	var plants_parent: Node = spawner._resolve_parent(spawner.plants_parent_path)
	var entities: Array = []
	for n in nodes:
		var d: Dictionary = n.to_save(ids)
		if n is Plant:
			# Las plantas cuelgan de dos padres y no da igual: el rescate de semillas del
			# Spawner cuenta los hijos del nodo de plantas; las de granja (y su
			# descendencia) cuelgan del World y no cuentan. Se conserva el padre.
			d["in_plants_node"] = n.get_parent() == plants_parent
		entities.append(d)
	return {
		"schema_version": SCHEMA_VERSION,
		"kind": "",   # lo fija `save_now` con la ranura
		"saved_at": Time.get_datetime_string_from_system(),
		"game_version": String(ProjectSettings.get_setting("application/config/version", "")),
		"config": _capture_config(),
		"params": _capture_params(),
		"clock": {
			"tick": SimulationClock.get_tick_count(),
			"speed": SimulationClock.speed,
			"accumulator": SimulationClock._tick_accumulator,
		},
		"climate": Climate.to_save(),
		"spawner": {
			"seed_timer": spawner._seed_timer,
			"resource_timer": spawner._resource_timer,
		},
		"entities": entities,
		"groups": Groups.to_save(ids),
		"relationships": Relationships.to_save(ids),
		"territory": TerritorySystem.to_save(),
		"stats": Stats.to_save(),
		"genetics": Genetics.to_save(),
	}


## Entidades que entran en la foto, en el orden de save = orden de tick: primero
## `SimulationClock._entities` (esferas), luego `_slow` (plantas, árboles, granjas,
## cadáveres) y al final los yacimientos, que no tickean (por grupo de escena, en orden
## del árbol: piedra y luego oro). Solo entidades válidas, vivas y no en cola de borrado
## (una planta comida del todo sigue en `_slow` hasta liberarse al final del frame).
static func capture_order() -> Array:
	var out: Array = []
	for e in SimulationClock._entities:
		if _is_live(e) and e is Sphere and e._alive:
			out.append(e)
	for e in SimulationClock._slow:
		if _is_live(e) and (e is Plant or e is TreeNode or e is Farm or e is Corpse):
			out.append(e)
	for type in [ResourceNode.Type.STONE, ResourceNode.Type.GOLD]:
		for e in (Engine.get_main_loop() as SceneTree).get_nodes_in_group(ResourceNode.group_for(type)):
			if _is_live(e) and e is Deposit:
				out.append(e)
	return out


static func _is_live(e: Variant) -> bool:
	return is_instance_valid(e) and not (e as Node).is_queued_for_deletion()


## Escribe `data` en la ranura de forma atómica: a `.tmp` y luego `rename`. Escribir
## directo dejaría un save corrupto si el proceso muere a mitad (justo al cerrar).
static func write(slot: String, data: Dictionary) -> Error:
	var err: Error = DirAccess.make_dir_recursive_absolute(DIR)
	if err != OK and err != ERR_ALREADY_EXISTS:
		return err
	var path: String = path_for(slot)
	var tmp: String = path + ".tmp"
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(var_to_str(data))
	f.close()
	return DirAccess.rename_absolute(tmp, path)


## Lee y valida una ranura. Devuelve `{ok, data, error}`; `error` es un texto para el
## jugador. Se rechaza todo lo que no tenga la forma esperada en lugar de cargarlo a
## medias: raíz no-Dictionary, otra `schema_version`, `entities` que no sea Array.
static func read(slot: String) -> Dictionary:
	var path: String = path_for(slot)
	if not FileAccess.file_exists(path):
		return _read_error("No hay partida guardada en «%s»" % slot)
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return _read_error("No se pudo leer «%s» (%s)" % [slot, error_string(FileAccess.get_open_error())])
	var root: Variant = str_to_var(text)
	if typeof(root) != TYPE_DICTIONARY:
		return _read_error("Partida dañada: el contenido no es un diccionario")
	var data: Dictionary = root
	var version: int = int(data.get("schema_version", -1))
	if version != SCHEMA_VERSION:
		return _read_error("Partida de otra versión (esquema %d, se esperaba %d)" % [version, SCHEMA_VERSION])
	if typeof(data.get("entities")) != TYPE_ARRAY:
		return _read_error("Partida dañada: falta la lista de entidades")
	for key in ["config", "params", "clock", "climate", "groups", "relationships",
			"territory", "stats", "genetics"]:
		if typeof(data.get(key)) != TYPE_DICTIONARY:
			return _read_error("Partida dañada: falta la sección «%s»" % key)
	return {"ok": true, "data": data, "error": ""}


## Resumen de una ranura para los botones «Continuar» de `StartScreen`, sin cargarla:
## `{exists, ok, saved_at, day_index, year, error}`. Pasa por `read`, así que un save
## dañado o de otra `schema_version` sale con `ok = false` y su `error` para el jugador.
static func peek(slot: String) -> Dictionary:
	var out: Dictionary = {
		"exists": FileAccess.file_exists(path_for(slot)),
		"ok": false, "saved_at": "", "day_index": 0, "year": 0, "error": "",
	}
	var r: Dictionary = read(slot)
	if not r.ok:
		out.error = r.error
		return out
	var climate: Dictionary = r.data.climate
	out.ok = true
	out.saved_at = String(r.data.get("saved_at", ""))
	out.day_index = int(climate.get("day_index", 0))
	out.year = int(climate.get("year", 0))
	return out


## Vuelca `config` y `params` del save a `SimConfig` y `GlobalParams`. Va ANTES de
## instanciar el mundo (lo hace quien arranca la carga, como `StartScreen` con una
## partida nueva): `World`/`Spawner` leen `SimConfig` en su `_ready`. La semilla de
## biomas es la resuelta al guardar, así el mapa es el mismo aunque el preset fuese -1.
static func apply_settings(data: Dictionary) -> void:
	var config: Dictionary = data.get("config", {})
	for key in CONFIG_KEYS:
		if config.has(key):
			var v: Variant = config[key]
			SimConfig.set(key, v.duplicate(true) if v is Dictionary else v)
	SimConfig.biome_seed = int(config.get("biome_seed", -1))
	var params: Dictionary = data.get("params", {})
	for key in PARAM_KEYS:
		if params.has(key):
			# Asignación directa (no todos los campos tienen rama en `set_param`), y
			# luego `set_param` para que los que sí la tienen avisen por `changed`.
			GlobalParams.set(key, params[key])
			GlobalParams.set_param(key, float(params[key]))
	var mods: Dictionary = params.get("species_modifiers", {})
	for species in mods:
		for mod_key in mods[species]:
			GlobalParams.set_species_mod(species, mod_key, float(mods[species][mod_key]))


## Restaura reloj, clima, entidades bajo `spawner` y sistemas. La llama `Spawner._on_terrain_ready`
## tras `await_nav_ready()` (las esferas consultan el navmesh). `apply_settings` ya
## corrió antes de crear el mundo. Devuelve `node_of`: el nodo de cada índice de save.
static func restore(spawner: Node, data: Dictionary) -> Array:
	assert(not SimulationClock._ticking, "SaveGame.restore dentro del tick")
	# 1. Reloj ANTES de activar: `Sphere.activate` lee `get_tick_count()`.
	var clock: Dictionary = data.clock
	SimulationClock.restore_state(int(clock.tick), float(clock.speed), float(clock.accumulator))
	Climate.from_save(data.climate)
	var timers: Dictionary = data.get("spawner", {})
	spawner._seed_timer = float(timers.get("seed_timer", 0.0))
	spawner._resource_timer = float(timers.get("resource_timer", 0.0))
	# 2. Instanciar TODAS las entidades primero, para que `node_of` esté completo cuando
	# `from_save` resuelva referencias a entidades posteriores en la lista. Cada tipo
	# vuelve al padre que le da el juego: esferas y cadáveres (`Corpse.spawn` usa el
	# padre de la esfera muerta) al nodo de esferas; árboles y yacimientos al Spawner;
	# granjas al World (`GroupSystem._spawn_farm`); plantas al nodo de plantas o al
	# World según `in_plants_node` (ver `capture`).
	var spheres_parent: Node = spawner._resolve_parent(spawner.spheres_parent_path)
	var plants_parent: Node = spawner._resolve_parent(spawner.plants_parent_path)
	var world: Node = spawner.get_parent() if spawner.get_parent() != null else spawner
	var node_of: Array = []
	var entities: Array = data.entities
	for d in entities:
		var node: Node = null
		var parent: Node = null
		match StringName(d.get("k", &"")):
			&"sphere":
				node = SPHERE_SCENE.instantiate()
				parent = spheres_parent
			&"plant":
				node = PLANT_SCENE.instantiate()
				parent = plants_parent if bool(d.get("in_plants_node", true)) else world
			&"tree":
				node = TREE_SCENE.instantiate()
				parent = spawner
			&"deposit":
				node = DEPOSIT_SCENE.instantiate()
				parent = spawner
			&"farm":
				node = FARM_SCENE.instantiate()
				parent = world
			&"corpse":
				node = CORPSE_SCENE.instantiate()
				parent = spheres_parent
			_:
				push_warning("SaveGame.restore: tipo de entidad desconocido %s" % str(d.get("k")))
		if node != null:
			parent.add_child(node)
			if not (node is Corpse):
				node.world_bounds = spawner.world_bounds
		node_of.append(node)
	# 3. `from_save` (que hace `activate()` dentro) en el orden guardado = orden de tick:
	# reproduce `_entities` y `_slow` tal cual.
	for i in entities.size():
		if node_of[i] != null:
			node_of[i].from_save(entities[i], node_of)
	# 4. Sistemas, DESPUÉS de todas las entidades (resuelven índices con `node_of`).
	# Stats el último: nada de lo anterior debe poder tocar sus contadores.
	Groups.from_save(data.groups, node_of)
	Relationships.from_save(data.relationships, node_of)
	TerritorySystem.from_save(data.territory)
	Genetics.from_save(data.genetics)
	Stats.from_save(data.stats)
	return node_of


## Captura + escritura + evento `game_saved` (la medida de coste del guardado).
static func save_now(spawner: Node, slot: String) -> Error:
	var t0: int = Time.get_ticks_usec()
	var data: Dictionary = capture(spawner)
	data["kind"] = slot
	var err: Error = write(slot, data)
	var bytes: int = 0
	var f: FileAccess = FileAccess.open(path_for(slot), FileAccess.READ)
	if f != null:
		bytes = f.get_length()
		f.close()
	EventLog.log_event(&"game_saved", {
		"slot": slot,
		"entities": (data.entities as Array).size(),
		"bytes": bytes,
		"ms": float(Time.get_ticks_usec() - t0) / 1000.0,
		"error": error_string(err) if err != OK else "",
	}, &"system")
	return err


static func _capture_config() -> Dictionary:
	var config: Dictionary = {}
	for key in CONFIG_KEYS:
		var v: Variant = SimConfig.get(key)
		config[key] = v.duplicate(true) if v is Dictionary else v
	# La semilla REAL, no la del preset: con `biome_seed = -1` la usada vive en Biomes.
	config[&"biome_seed"] = Biomes.seed_value
	return config


static func _capture_params() -> Dictionary:
	var params: Dictionary = {}
	for key in PARAM_KEYS:
		params[key] = GlobalParams.get(key)
	params[&"species_modifiers"] = GlobalParams.species_modifiers.duplicate(true)
	return params


static func _read_error(msg: String) -> Dictionary:
	return {"ok": false, "data": {}, "error": msg}
