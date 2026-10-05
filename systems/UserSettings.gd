class_name UserSettings
extends RefCounted
## Preferencias del jugador (gusto visual), en `user://settings.cfg`, sección `[visual]`.
##
## Clase estática y no autoload: no hace falta estado vivo, porque las variables `static`
## sobreviven al cambio de escena `StartScreen → World`, y quien necesita el valor lo lee
## cada frame. Por eso no tiene señales. No va a la partida guardada (no entra en
## `SaveGame.PARAM_KEYS`): una partida compartida no impone el gusto visual de otro.
##
## Ver docs: docs/Planes/…/Plan - Game Feel y Efectos Juicy.md (Arquitectura → Contratos).

enum EffectsIntensity { OFF, LOW, MEDIUM, HIGH }
enum HaloMode { ALWAYS, HOVER, NEVER }

const PATH: String = "user://settings.cfg"
const SECTION: String = "visual"

static var effects_intensity: int = EffectsIntensity.LOW
static var halo_mode: int = HaloMode.HOVER

## Ya se leyó el fichero (o alguien fijó los valores a propósito): `load_settings` no
## vuelve a leer. Así es idempotente y no pisa lo que se asignó después de cargar.
static var _loaded: bool = false


## Lee el fichero una sola vez por proceso. Si no existe (primer arranque, herramientas
## headless) se quedan los valores por defecto y **no** se crea: solo escribe `set_*`.
## Un valor ausente, de otro tipo o fuera de rango vuelve al de por defecto.
static func load_settings() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	effects_intensity = _valid_or(cfg.get_value(SECTION, "effects_intensity", null),
		EffectsIntensity.size(), EffectsIntensity.LOW)
	halo_mode = _valid_or(cfg.get_value(SECTION, "halo_mode", null),
		HaloMode.size(), HaloMode.HOVER)


## Asigna y guarda. Un valor fuera de rango se ignora.
static func set_effects_intensity(v: int) -> void:
	if v < 0 or v >= EffectsIntensity.size():
		push_warning("UserSettings: effects_intensity fuera de rango: %d" % v)
		return
	load_settings()  # que guardar no pise con defaults lo que aún no se leyó
	effects_intensity = v
	_save()


## Asigna y guarda. Un valor fuera de rango se ignora.
static func set_halo_mode(v: int) -> void:
	if v < 0 or v >= HaloMode.size():
		push_warning("UserSettings: halo_mode fuera de rango: %d" % v)
		return
	load_settings()
	halo_mode = v
	_save()


static func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)  # conserva otras secciones si las hubiera; si no existe, parte de vacío
	cfg.set_value(SECTION, "effects_intensity", effects_intensity)
	cfg.set_value(SECTION, "halo_mode", halo_mode)
	var err: Error = cfg.save(PATH)
	if err != OK:
		push_warning("UserSettings: no se pudo guardar %s (%s)" % [PATH, error_string(err)])


static func _valid_or(v: Variant, count: int, fallback: int) -> int:
	if typeof(v) != TYPE_INT:
		return fallback
	var i: int = v
	return i if i >= 0 and i < count else fallback
