extends Node
## Log central de eventos relevantes de la simulación.
##
## Autoload `EventLog`. Sistemas y entidades empujan eventos aquí;
## la UI consume `event_logged` para mostrarlos. Además se persiste
## un JSONL por categoría en `user://logs/` para diagnóstico de
## comportamientos emergentes (especialmente cambios de estado).
##
## Categorías estándar: "world", "plants", "sphere_A", "sphere_B" (una
## por especie) y "territory" (snapshots periódicos de dominio territorial
## que vuelca `TerritorySystem` para análisis offline). Cualquier categoría
## nueva genera su propio fichero.
##
## Ver docs: docs/GDD/Narrativa.md (sección "Sistemas que generan narrativa").

signal event_logged(event: Dictionary)

const MAX_EVENTS: int = 2000
const LOG_DIR: String = "user://logs"

var _events: Array[Dictionary] = []
var _files: Dictionary = {}          # category -> FileAccess
var _session_stamp: String = ""
var enabled_disk: bool = true


func _ready() -> void:
	_session_stamp = Time.get_datetime_string_from_system().replace(":", "-")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
	# La carpeta también la creamos dentro del FS de Godot (user://).
	var d: DirAccess = DirAccess.open("user://")
	if d != null and not d.dir_exists("logs"):
		d.make_dir("logs")


func _exit_tree() -> void:
	for f in _files.values():
		if f != null:
			f.close()
	_files.clear()


func log_event(kind: StringName, data: Dictionary = {}, category: StringName = &"world") -> void:
	var entry: Dictionary = {
		"tick": SimulationClock.get_tick_count(),
		"t_sim": SimulationClock.get_sim_time() if SimulationClock.has_method("get_sim_time") else 0.0,
		"category": String(category),
		"kind": String(kind),
		"data": data,
	}
	_events.append(entry)
	if _events.size() > MAX_EVENTS:
		_events.pop_front()
	event_logged.emit(entry)
	if enabled_disk:
		_write_to_disk(String(category), entry)


func log_state_change(category: StringName, kind: StringName, snapshot: Dictionary) -> void:
	## Helper para registrar transiciones de estado de una entidad con su
	## snapshot completo (posición + estado interno). Pensado para depurar
	## decisiones de la IA y el ciclo de plantas.
	log_event(kind, snapshot, category)


func get_events() -> Array[Dictionary]:
	return _events.duplicate()


func clear() -> void:
	_events.clear()


func _write_to_disk(category: String, entry: Dictionary) -> void:
	var f: FileAccess = _files.get(category, null)
	if f == null:
		var path: String = "%s/%s_%s.jsonl" % [LOG_DIR, _session_stamp, category]
		f = FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return
		_files[category] = f
	f.store_line(JSON.stringify(entry))
	# flush implícito al cerrar; para diagnóstico en vivo forzamos cada N.
	if entry.tick % 60 == 0:
		f.flush()
