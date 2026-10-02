class_name StartScreen
extends Control
## Pantalla de inicio: el jugador ajusta la configuración de la simulación
## antes de lanzarla.
##
## Escribe los valores elegidos en `SimConfig` y carga la escena principal.
## Es la escena de arranque del juego (`run/main_scene` en project.godot).

const SIMULATION_SCENE: String = "res://main/Main.tscn"

## Definición de cada slider: clave SimConfig, etiqueta, rango y paso.
# Los mínimos de plantas/población/comida son 0 para permitir el preset
# "Sandbox vacío" (mundo sin esferas ni plantas) desde el propio slider.
const FIELDS: Array[Dictionary] = [
	{"key": "world_size", "label": "Tamaño del terreno", "min": 60.0, "max": 600.0, "step": 20.0, "suffix": " u"},
	{"key": "initial_plants", "label": "Plantas iniciales", "min": 0.0, "max": 800.0, "step": 50.0, "suffix": ""},
	{"key": "initial_population_per_species", "label": "Población por especie", "min": 0.0, "max": 400.0, "step": 10.0, "suffix": ""},
	{"key": "min_plant_seeds", "label": "Comida mínima mantenida", "min": 0.0, "max": 800.0, "step": 25.0, "suffix": ""},
]

## Presets disponibles (escenarios de partida). Se cargan en `_ready`; los que
## fallen al cargar se omiten. Ver `data/presets/` y `SimPreset`.
const PRESET_PATHS: Array[String] = [
	"res://data/presets/genesis.tres",
	"res://data/presets/escasez.tres",
	"res://data/presets/abundancia_eterna.tres",
	"res://data/presets/sandbox_vacio.tres",
	"res://data/presets/dos_tribus.tres",
	"res://data/presets/depredador_apex.tres",
]

## Arquetipos de especie (presets de comportamiento + modificadores). Se cargan en
## `_ready`; los que fallen al cargar se omiten. Ver `data/presets/species/` y
## `SpeciesPreset`.
const SPECIES_PRESET_PATHS: Array[String] = [
	"res://data/presets/species/equilibrada.tres",
	"res://data/presets/species/pacifica.tres",
	"res://data/presets/species/agresiva.tres",
	"res://data/presets/species/territorial.tres",
]

## Sliders para las medias iniciales de rasgos de comportamiento (0.0 – 1.0).
## Se muestran POR ESPECIE (una columna por especie de `GlobalParams.SPECIES_KEYS`):
## por defecto iguales → divergencia emergente, pero el jugador puede sembrar
## diferencias de partida entre especies.
const TRAIT_FIELDS: Array[Dictionary] = [
	{"key": &"aggression", "label": "Agresividad"},
	{"key": &"sociability", "label": "Sociabilidad"},
	{"key": &"loyalty", "label": "Lealtad"},
	{"key": &"bravery", "label": "Valentía"},
	{"key": &"reproductive_appetite", "label": "Apetito reproductivo"},
	{"key": &"selectivity", "label": "Selectividad"},
	{"key": &"territoriality", "label": "Territorialidad"},
]

var _sliders: Dictionary = {}
# Sliders de rasgo anidados: species(StringName) -> { rasgo(StringName) -> HSlider }.
var _trait_sliders: Dictionary = {}
# Sliders de modificador por especie: species(StringName) -> { mod(StringName) -> HSlider }.
var _mod_sliders: Dictionary = {}
# Arquetipos de especie cargados (paralelos a las entradas 1..N del OptionButton).
var _species_presets: Array[SpeciesPreset] = []
# Label de descripción del arquetipo por especie: species(StringName) -> Label.
var _species_preset_desc: Dictionary = {}
# Presets cargados (paralelo a las entradas 1..N del OptionButton; el 0 es "Personalizado").
var _presets: Array[SimPreset] = []
# Preset elegido actualmente (null = "Personalizado").
var _selected_preset: SimPreset = null
var _preset_desc: Label
# Casilla "empezar controlando una esfera nueva" (modo control en 3ª persona).
var _control_check: CheckButton


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_load_presets()
	_load_species_presets()
	_build_ui()


func _load_presets() -> void:
	for path in PRESET_PATHS:
		var res: Resource = load(path)
		if res is SimPreset:
			_presets.append(res)
		else:
			push_warning("StartScreen: preset no cargado: %s" % path)


func _load_species_presets() -> void:
	for path in SPECIES_PRESET_PATHS:
		var res: Resource = load(path)
		if res is SpeciesPreset:
			_species_presets.append(res)
		else:
			push_warning("StartScreen: preset de especie no cargado: %s" % path)


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.11, 0.13)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Raíz a pantalla completa con márgenes: el menú ocupa todo el viewport en
	# lugar de un bloque centrado de ancho fijo que se salía por abajo.
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		root.add_theme_constant_override(m, 28)
	add_child(root)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	root.add_child(outer)

	var title := Label.new()
	title.text = "BioSphera"
	title.add_theme_font_size_override("font_size", 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Configuración de la simulación"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.modulate = Color(0.65, 0.68, 0.72)
	outer.add_child(subtitle)

	outer.add_child(HSeparator.new())

	# Zona desplazable de seguridad: si el contenido no cabe en alto, se hace
	# scroll en vez de recortarse. El scroll horizontal queda desactivado para que
	# las columnas se repartan el ancho disponible.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	# Columnas horizontales: [Escenario] | [Especie A] | [Especie B] ...
	var content := HBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 24)
	scroll.add_child(content)

	content.add_child(_build_scenario_column())
	for species in GlobalParams.SPECIES_KEYS:
		content.add_child(VSeparator.new())
		content.add_child(_build_species_column(species))

	outer.add_child(HSeparator.new())

	# Modo control: empezar poseyendo una esfera nueva (3ª persona). Ver
	# `PlayerControl` y `Spawner._spawn_controlled_sphere`.
	_control_check = CheckButton.new()
	_control_check.text = "Empezar controlando una esfera nueva (3ª persona)"
	_control_check.button_pressed = SimConfig.start_controlled
	outer.add_child(_control_check)

	var start_btn := Button.new()
	start_btn.text = "Iniciar simulación"
	start_btn.custom_minimum_size = Vector2(0.0, 46.0)
	start_btn.pressed.connect(_on_start_pressed)
	outer.add_child(start_btn)


## Columna izquierda: escenario (mundo) + sliders de mundo.
func _build_scenario_column() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)

	var header := Label.new()
	header.text = "Escenario y mundo"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 16)
	col.add_child(header)

	_add_preset_selector(col)
	col.add_child(HSeparator.new())
	for field in FIELDS:
		_add_slider(col, field)
	return col


## Una columna por especie: arquetipo + medias de rasgos + modificadores ×. Agrupar
## todo lo de cada especie en su columna mantiene el menú ancho y poco alto.
func _build_species_column(species: StringName) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)

	var header := Label.new()
	header.text = "Especie %s" % String(species)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 16)
	col.add_child(header)

	_add_species_preset_selector(col, species)

	var traits_title := Label.new()
	traits_title.text = "Rasgos (media)"
	traits_title.modulate = Color(0.65, 0.68, 0.72)
	col.add_child(traits_title)
	_trait_sliders[species] = {}
	for tfield in TRAIT_FIELDS:
		_add_trait_slider(col, species, tfield)

	var mods_title := Label.new()
	mods_title.text = "Modificadores (×)"
	mods_title.modulate = Color(0.65, 0.68, 0.72)
	col.add_child(mods_title)
	_mod_sliders[species] = {}
	for key in GlobalParams.SPECIES_MOD_KEYS:
		_add_mod_slider(col, species, key)
	return col


func _add_slider(parent: VBoxContainer, field: Dictionary) -> void:
	var key: String = field["key"]
	var suffix: String = field["suffix"]
	var value: float = float(SimConfig.get(key))

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = field["label"]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var value_label := Label.new()
	value_label.text = "%d%s" % [int(value), suffix]
	header.add_child(name_label)
	header.add_child(value_label)
	row.add_child(header)

	var slider := HSlider.new()
	slider.min_value = field["min"]
	slider.max_value = field["max"]
	slider.step = field["step"]
	slider.value = clampf(value, field["min"], field["max"])
	slider.value_changed.connect(
		func(v: float) -> void: value_label.text = "%d%s" % [int(v), suffix])
	row.add_child(slider)

	parent.add_child(row)
	_sliders[key] = slider


## Crea un slider 0.0–1.0 (paso 0.05) para la media de un rasgo de una especie.
func _add_trait_slider(parent: VBoxContainer, species: StringName, field: Dictionary) -> void:
	var key: StringName = field["key"]
	var value: float = float(SimConfig.get_trait_means(species).get(key, SimConfig.INITIAL_TRAIT_MEAN_DEFAULT))

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = field["label"]
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var value_label := Label.new()
	value_label.add_theme_font_size_override("font_size", 12)
	value_label.text = String.num(value, 2)
	header.add_child(name_label)
	header.add_child(value_label)
	row.add_child(header)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = clampf(value, 0.0, 1.0)
	slider.value_changed.connect(
		func(v: float) -> void: value_label.text = String.num(v, 2))
	row.add_child(slider)

	parent.add_child(row)
	_trait_sliders[species][key] = slider


## Crea un slider de multiplicador (× , 0.0–3.0) para un modificador de una
## especie. Mismo rango que el panel en vivo (SpeciesPanel). 1.0 = neutro.
func _add_mod_slider(parent: VBoxContainer, species: StringName, key: StringName) -> void:
	var value: float = GlobalParams.get_species_mod(species, key)

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = String(GlobalParams.SPECIES_MOD_LABELS.get(key, String(key)))
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var value_label := Label.new()
	value_label.add_theme_font_size_override("font_size", 12)
	value_label.text = "×%s" % String.num(value, 2)
	header.add_child(name_label)
	header.add_child(value_label)
	row.add_child(header)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 3.0
	slider.step = 0.05
	slider.value = clampf(value, 0.0, 3.0)
	slider.value_changed.connect(
		func(v: float) -> void: value_label.text = "×%s" % String.num(v, 2))
	row.add_child(slider)

	parent.add_child(row)
	_mod_sliders[species][key] = slider


## Desplegable de escenarios + descripción. La entrada 0 es "Personalizado"
## (comportamiento clásico); 1..N son los presets cargados.
func _add_preset_selector(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Escenario"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var option := OptionButton.new()
	option.add_item("Personalizado", 0)
	for i in _presets.size():
		var preset: SimPreset = _presets[i]
		var item_text: String = preset.display_name if preset.display_name != "" else String(preset.id)
		option.add_item(item_text, i + 1)
	option.item_selected.connect(_on_preset_selected)
	row.add_child(option)
	parent.add_child(row)

	_preset_desc = Label.new()
	_preset_desc.add_theme_font_size_override("font_size", 12)
	_preset_desc.modulate = Color(0.65, 0.68, 0.72)
	_preset_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preset_desc.custom_minimum_size = Vector2(0.0, 34.0)
	parent.add_child(_preset_desc)


func _on_preset_selected(index: int) -> void:
	if index <= 0 or index > _presets.size():
		_selected_preset = null
		_preset_desc.text = ""
		return
	var preset: SimPreset = _presets[index - 1]
	_selected_preset = preset
	_preset_desc.text = preset.description
	_apply_preset_to_ui(preset)


## Rellena los sliders de ESCENARIO con los valores del preset (mundo/comida/
## población). Los rasgos por especie no los toca el escenario: van por su propio
## desplegable (ver `_apply_species_preset_to_ui`). Lo que quede en los sliders al
## pulsar "Iniciar" es lo que manda.
func _apply_preset_to_ui(preset: SimPreset) -> void:
	_sliders["world_size"].value = preset.world_size
	_sliders["initial_plants"].value = preset.initial_plants
	_sliders["initial_population_per_species"].value = preset.initial_population_per_species
	_sliders["min_plant_seeds"].value = preset.min_plant_seeds


## Desplegable de arquetipo de una especie. Igual que el selector de escenario, la
## entrada 0 es "Personalizado" (no toca los sliders); 1..N son los arquetipos.
func _add_species_preset_selector(parent: VBoxContainer, species: StringName) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Arquetipo"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var option := OptionButton.new()
	option.add_item("Personalizado", 0)
	for i in _species_presets.size():
		var preset: SpeciesPreset = _species_presets[i]
		var item_text: String = preset.display_name if preset.display_name != "" else String(preset.id)
		option.add_item(item_text, i + 1)
	option.item_selected.connect(_on_species_preset_selected.bind(species))
	row.add_child(option)
	parent.add_child(row)

	var desc := Label.new()
	desc.add_theme_font_size_override("font_size", 12)
	desc.modulate = Color(0.65, 0.68, 0.72)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0.0, 34.0)
	parent.add_child(desc)
	_species_preset_desc[species] = desc


func _on_species_preset_selected(index: int, species: StringName) -> void:
	var desc: Label = _species_preset_desc[species]
	if index <= 0 or index > _species_presets.size():
		desc.text = ""
		return
	var preset: SpeciesPreset = _species_presets[index - 1]
	desc.text = preset.description
	_apply_species_preset_to_ui(species, preset)


## Siembra los sliders de rasgos y de modificadores de una especie desde un
## arquetipo. La clave puede venir como StringName o String según cómo se guarde el
## .tres; se prueban ambas antes de caer al default (medias 0.5, mods 1.0).
func _apply_species_preset_to_ui(species: StringName, preset: SpeciesPreset) -> void:
	for key in _trait_sliders[species].keys():
		var v: float = float(preset.trait_means.get(
			key, preset.trait_means.get(String(key), SimConfig.INITIAL_TRAIT_MEAN_DEFAULT)))
		_trait_sliders[species][key].value = v
	for key in _mod_sliders[species].keys():
		var m: float = float(preset.species_mods.get(
			key, preset.species_mods.get(String(key), 1.0)))
		_mod_sliders[species][key].value = m


func _on_start_pressed() -> void:
	# Si hay preset, aplicar primero sus EXTRAS (semilla, layout, overrides de
	# GlobalParams) y luego dejar que los sliders sobrescriban los campos que
	# exponen: así un ajuste manual tras elegir el preset se respeta.
	if _selected_preset != null:
		SimConfig.apply_preset(_selected_preset)
		SimConfig.apply_to_global_params()
	SimConfig.world_size = _sliders["world_size"].value
	SimConfig.initial_plants = int(_sliders["initial_plants"].value)
	SimConfig.initial_population_per_species = int(_sliders["initial_population_per_species"].value)
	SimConfig.min_plant_seeds = int(_sliders["min_plant_seeds"].value)
	# Modo control: arrancar poseyendo una esfera nueva (3ª persona).
	SimConfig.start_controlled = _control_check != null and _control_check.button_pressed
	for species in _trait_sliders.keys():
		for key in _trait_sliders[species].keys():
			SimConfig.set_trait_mean(species, key, float(_trait_sliders[species][key].value))
	# Modificadores por especie: fuente de verdad viva en GlobalParams (autoload,
	# persiste al cambiar de escena). Se escriben siempre, también en "Personalizado".
	for species in _mod_sliders.keys():
		for key in _mod_sliders[species].keys():
			GlobalParams.set_species_mod(species, key, float(_mod_sliders[species][key].value))
	get_tree().change_scene_to_file(SIMULATION_SCENE)
