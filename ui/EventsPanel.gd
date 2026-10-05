extends "res://ui/DraggablePanel.gd"
## Panel de eventos del entorno (tecla `V`).
##
## Lista los eventos activos con un «Parar» por fila (`Climate.stop_event`), deja
## desencadenar uno a mano con tipo e intensidad (`Climate.start_event`, que reemplaza
## al activo del mismo tipo) y ajusta en vivo el ritmo del disparo aleatorio
## (`GlobalParams.random_events_per_year`). Intervenir sobre el entorno no requiere
## el modo experimentación. Construido por código, como `SpeciesPanel` y `StatsPanel`.
##
## Ver docs: docs/GDD/UI - UX.md · docs/GDD/Mecánicas.md (eventos del entorno).

## Eventos que se pueden desencadenar a mano, en el orden del selector.
const EVENT_PATHS: Array[String] = [
	"res://data/events/sequia.tres",
	"res://data/events/ola_de_frio.tres",
	"res://data/events/tormenta.tres",
	"res://data/events/abundancia.tres",
	"res://data/events/plaga.tres",
]

## Icono por `EnvironmentEvent.Kind` (lo usa también el `EventLabel` del HUD).
const KIND_ICONS: Dictionary = {
	EnvironmentEvent.Kind.DROUGHT: "🌵",
	EnvironmentEvent.Kind.COLD_WAVE: "❄",
	EnvironmentEvent.Kind.STORM: "⛈",
	EnvironmentEvent.Kind.ABUNDANCE: "🌾",
	EnvironmentEvent.Kind.PLAGUE: "☣",
}

const RATE_MAX: float = 12.0
const LABEL_WIDTH: float = 110.0
const VALUE_WIDTH: float = 48.0
## Cada cuántos ticks se refresca el texto de las filas activas (como el HUD).
const REFRESH_TICKS: int = 6

var _events: Array[EnvironmentEvent] = []
var _active_box: VBoxContainer
var _active_labels: Dictionary = {}   # kind (int) → Label de su fila
var _empty_label: Label
var _kind_option: OptionButton
var _intensity_slider: HSlider
var _intensity_value: Label
var _trigger_button: Button
var _rate_slider: HSlider
var _rate_value: Label


## Una línea por evento activo: «🌵 Sequía 60% · 4 d» (intensidad nominal y días que
## quedan, redondeados hacia arriba). Cadena vacía sin eventos.
static func format_event(e: Dictionary) -> String:
	return "%s %s %d%% · %d d" % [
		KIND_ICONS.get(int(e["kind"]), "•"), String(e["name"]),
		roundi(float(e["intensity"]) * 100.0), ceili(float(e["days_left"]))]


func _ready() -> void:
	super._ready()
	custom_minimum_size = Vector2(340, 0)

	for path in EVENT_PATHS:
		var ev: EnvironmentEvent = load(path) as EnvironmentEvent
		if ev != null:
			_events.append(ev)
		else:
			push_warning("EventsPanel: evento no cargado: %s" % path)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override(&"margin_left", 12)
	margin.add_theme_constant_override(&"margin_right", 12)
	margin.add_theme_constant_override(&"margin_top", 12)
	margin.add_theme_constant_override(&"margin_bottom", 12)
	add_child(margin)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 6)
	margin.add_child(vbox)

	var title: Label = Label.new()
	title.text = "Eventos del entorno (V)"
	title.add_theme_font_size_override(&"font_size", 16)
	vbox.add_child(title)

	# --- Activos ---
	vbox.add_child(HSeparator.new())
	vbox.add_child(_section_label("Activos"))
	_active_box = VBoxContainer.new()
	_active_box.add_theme_constant_override(&"separation", 4)
	vbox.add_child(_active_box)
	_empty_label = Label.new()
	_empty_label.text = "Ninguno"
	_empty_label.modulate = Color(1, 1, 1, 0.6)
	vbox.add_child(_empty_label)

	# --- Desencadenar a mano ---
	vbox.add_child(HSeparator.new())
	vbox.add_child(_section_label("Desencadenar"))
	var kind_row: HBoxContainer = _row("Tipo")
	_kind_option = OptionButton.new()
	_kind_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_kind_option.focus_mode = Control.FOCUS_NONE
	for ev in _events:
		_kind_option.add_item("%s %s" % [KIND_ICONS.get(int(ev.kind), "•"), ev.display_name])
	kind_row.add_child(_kind_option)
	vbox.add_child(kind_row)

	var int_row: HBoxContainer = _row("Intensidad")
	_intensity_slider = _slider(0.05, 1.0, 0.05, 0.5)
	int_row.add_child(_intensity_slider)
	_intensity_value = _value_label()
	int_row.add_child(_intensity_value)
	vbox.add_child(int_row)
	_intensity_slider.value_changed.connect(func(_v: float) -> void: _update_value_labels())

	_trigger_button = Button.new()
	_trigger_button.text = "Desencadenar"
	_trigger_button.tooltip_text = "Arranca el evento elegido; si ya hay uno de ese tipo, lo reemplaza"
	_trigger_button.focus_mode = Control.FOCUS_NONE
	_trigger_button.pressed.connect(_on_trigger_pressed)
	vbox.add_child(_trigger_button)

	# --- Disparo aleatorio ---
	vbox.add_child(HSeparator.new())
	var rate_row: HBoxContainer = _row("Eventos al año")
	_rate_slider = _slider(0.0, RATE_MAX, 1.0, GlobalParams.random_events_per_year)
	rate_row.add_child(_rate_slider)
	_rate_value = _value_label()
	rate_row.add_child(_rate_value)
	vbox.add_child(rate_row)
	_rate_slider.value_changed.connect(func(v: float) -> void:
		GlobalParams.set_param(&"random_events_per_year", v); _update_value_labels())

	GlobalParams.changed.connect(_on_param_changed)
	Climate.env_event_started.connect(func(_k: int, _i: float, _d: float) -> void: _rebuild_active())
	Climate.env_event_ended.connect(func(_k: int) -> void: _rebuild_active())
	SimulationClock.tick.connect(_on_tick)
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


func _section_label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", 14)
	return l


func _row(text: String) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	var label: Label = Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	row.add_child(label)
	return row


func _slider(min_v: float, max_v: float, step: float, value: float) -> HSlider:
	var s: HSlider = HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	return s


func _value_label() -> Label:
	var l: Label = Label.new()
	l.custom_minimum_size = Vector2(VALUE_WIDTH, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return l


func _update_value_labels() -> void:
	_intensity_value.text = "%d%%" % roundi(_intensity_slider.value * 100.0)
	_rate_value.text = "%d" % roundi(_rate_slider.value)


## Reconstruye las filas de activos (al arrancar o retirarse un evento, y al abrirse).
## No se rehace en cada tick: los botones «Parar» se liberarían bajo el ratón.
func _rebuild_active() -> void:
	for child in _active_box.get_children():
		_active_box.remove_child(child)
		child.queue_free()
	_active_labels.clear()
	var events: Array[Dictionary] = Climate.active_events()
	for e in events:
		var kind: int = int(e["kind"])
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		var label: Label = Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text = format_event(e)
		row.add_child(label)
		var stop: Button = Button.new()
		stop.text = "Parar"
		stop.tooltip_text = "Pasa el evento a su rampa de salida"
		stop.focus_mode = Control.FOCUS_NONE
		stop.pressed.connect(Climate.stop_event.bind(kind))
		row.add_child(stop)
		_active_box.add_child(row)
		_active_labels[kind] = label
	_empty_label.visible = events.is_empty()


func _on_tick(_dt: float) -> void:
	if not is_visible_in_tree() or SimulationClock.get_tick_count() % REFRESH_TICKS != 0:
		return
	var events: Array[Dictionary] = Climate.active_events()
	# Tras cargar una partida los activos llegan sin señal: se detecta por el conteo.
	if events.size() != _active_labels.size():
		_rebuild_active()
		return
	for e in events:
		var label: Label = _active_labels.get(int(e["kind"]))
		if label == null:
			_rebuild_active()
			return
		label.text = format_event(e)


func _on_visibility_changed() -> void:
	if not visible:
		return
	_rate_slider.set_value_no_signal(GlobalParams.random_events_per_year)
	_update_value_labels()
	_rebuild_active()


func _on_param_changed(key: StringName, value: float) -> void:
	if key == &"random_events_per_year":
		_rate_slider.set_value_no_signal(value)
		_update_value_labels()


func _on_trigger_pressed() -> void:
	var idx: int = _kind_option.selected
	if idx < 0 or idx >= _events.size():
		return
	Climate.start_event(_events[idx], _intensity_slider.value)
