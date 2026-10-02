extends "res://ui/DraggablePanel.gd"
## Panel plegable con sliders por especie (en vivo).
##
## Multiplicadores que se aplican sobre el rasgo del genoma de cada
## individuo de la especie. 1.0 = neutro. Se construye programáticamente
## desde `GlobalParams.SPECIES_KEYS` / `SPECIES_MOD_KEYS`.
##
## Ver docs: docs/GDD/UI - UX.md.

# Etiquetas de modificador: fuente única en GlobalParams.SPECIES_MOD_LABELS
# (compartida con StartScreen). Se lee en tiempo de ejecución al construir el panel.

const SPECIES_COLORS: Dictionary = {
	&"A": Color(1.0, 0.55, 0.45, 1.0),
	&"B": Color(0.45, 0.75, 1.0, 1.0),
}

const MOD_MIN: float = 0.0
const MOD_MAX: float = 3.0
const MOD_STEP: float = 0.05
const LABEL_WIDTH: float = 130.0
const VALUE_WIDTH: float = 56.0

var _sliders: Dictionary = {}
var _values: Dictionary = {}


func _ready() -> void:
	custom_minimum_size = Vector2(340, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override(&"margin_left", 12)
	margin.add_theme_constant_override(&"margin_right", 12)
	margin.add_theme_constant_override(&"margin_top", 12)
	margin.add_theme_constant_override(&"margin_bottom", 12)
	add_child(margin)

	var root_vbox: VBoxContainer = VBoxContainer.new()
	root_vbox.add_theme_constant_override(&"separation", 4)
	margin.add_child(root_vbox)

	var title: Label = Label.new()
	title.text = "Modificadores por especie (×)"
	title.add_theme_font_size_override(&"font_size", 16)
	root_vbox.add_child(title)

	var hint: Label = Label.new()
	hint.text = "Multiplican el rasgo del genoma. 1.0 = neutro."
	hint.modulate = Color(1, 1, 1, 0.6)
	root_vbox.add_child(hint)

	for species in GlobalParams.SPECIES_KEYS:
		root_vbox.add_child(HSeparator.new())
		_build_species_section(root_vbox, species)

	root_vbox.add_child(HSeparator.new())
	var reset: Button = Button.new()
	reset.text = "Reset a ×1.00"
	reset.pressed.connect(_reset_all)
	root_vbox.add_child(reset)


func _build_species_section(parent: VBoxContainer, species: StringName) -> void:
	var header: Label = Label.new()
	header.text = "Especie %s" % String(species)
	header.add_theme_font_size_override(&"font_size", 14)
	header.modulate = SPECIES_COLORS.get(species, Color.WHITE)
	parent.add_child(header)

	_sliders[species] = {}
	_values[species] = {}
	for key in GlobalParams.SPECIES_MOD_KEYS:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		parent.add_child(row)

		var label: Label = Label.new()
		label.text = String(GlobalParams.SPECIES_MOD_LABELS.get(key, String(key)))
		label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
		row.add_child(label)

		var slider: HSlider = HSlider.new()
		slider.min_value = MOD_MIN
		slider.max_value = MOD_MAX
		slider.step = MOD_STEP
		slider.value = GlobalParams.get_species_mod(species, key)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.custom_minimum_size = Vector2(0, 18)
		row.add_child(slider)

		var value_label: Label = Label.new()
		value_label.text = "×%s" % String.num(slider.value, 2)
		value_label.custom_minimum_size = Vector2(VALUE_WIDTH, 0)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value_label)

		_sliders[species][key] = slider
		_values[species][key] = value_label

		slider.value_changed.connect(_on_slider_changed.bind(species, key))


func _on_slider_changed(value: float, species: StringName, key: StringName) -> void:
	GlobalParams.set_species_mod(species, key, value)
	_values[species][key].text = "×%s" % String.num(value, 2)


func _reset_all() -> void:
	for species in _sliders.keys():
		for key in _sliders[species].keys():
			_sliders[species][key].value = 1.0
