class_name Hud
extends CanvasLayer
## HUD (Fase 2).
##
## Barra superior siempre visible + panel plegable de parámetros globales
## en vivo + indicador de modo experimentación.
##
## Ver docs: docs/GDD/UI - UX.md.

@onready var _root: Control = $Root
@onready var _speed_label: Label = %SpeedLabel
@onready var _tick_label: Label = %TickLabel
@onready var _pop_label: Label = %PopulationLabel
@onready var _plant_label: Label = %PlantLabel
@onready var _gen_label: Label = %GenerationLabel
@onready var _exp_label: Label = %ExperimentationLabel
@onready var _params_panel: PanelContainer = %ParamsPanel
@onready var _help_panel: PanelContainer = %HelpPanel
@onready var _mutation_slider: HSlider = %MutationSlider
@onready var _aggression_slider: HSlider = %AggressionSlider
@onready var _sociability_slider: HSlider = %SociabilitySlider
@onready var _lifespan_slider: HSlider = %LifespanSlider
@onready var _repro_slider: HSlider = %ReproSlider
@onready var _territoriality_slider: HSlider = %TerritorialitySlider
@onready var _memory_slider: HSlider = %MemorySlider
@onready var _mutation_value: Label = %MutationValue
@onready var _aggression_value: Label = %AggressionValue
@onready var _sociability_value: Label = %SociabilityValue
@onready var _lifespan_value: Label = %LifespanValue
@onready var _repro_value: Label = %ReproValue
@onready var _territoriality_value: Label = %TerritorialityValue
@onready var _memory_value: Label = %MemoryValue
@onready var _navmesh_button: Button = %NavMeshButton
@onready var _territory_button: Button = %TerritoryButton
@onready var _control_button: Button = %ControlButton
@onready var _control_label: Label = %ControlLabel

const SpeciesPanelScript: GDScript = preload("res://ui/SpeciesPanel.gd")
const StatsPanelScript: GDScript = preload("res://ui/StatsPanel.gd")
const GroupChartPanelScript: GDScript = preload("res://ui/GroupChartPanel.gd")
const GroupInspectPanelScript: GDScript = preload("res://ui/GroupInspectPanel.gd")
var _species_panel: PanelContainer
var _stats_panel: PanelContainer
var _group_chart_panel: PanelContainer
var _group_inspect_panel: PanelContainer

var _ui_visible: bool = true


func _ready() -> void:
	SimulationClock.speed_changed.connect(_on_speed_changed)
	SimulationClock.tick.connect(_on_tick)
	_on_speed_changed(SimulationClock.speed)

	_mutation_slider.value = GlobalParams.mutation_base_rate
	_aggression_slider.value = GlobalParams.aggression_modifier
	_sociability_slider.value = GlobalParams.sociability_modifier
	_lifespan_slider.value = GlobalParams.lifespan_multiplier
	_repro_slider.value = GlobalParams.reproductive_appetite_modifier
	_territoriality_slider.value = GlobalParams.territoriality_modifier
	_memory_slider.value = GlobalParams.social_memory_capacity
	_update_slider_labels()

	_mutation_slider.value_changed.connect(func(v: float) -> void:
		GlobalParams.set_param(&"mutation_base_rate", v); _update_slider_labels())
	_aggression_slider.value_changed.connect(func(v: float) -> void:
		GlobalParams.set_param(&"aggression_modifier", v); _update_slider_labels())
	_sociability_slider.value_changed.connect(func(v: float) -> void:
		GlobalParams.set_param(&"sociability_modifier", v); _update_slider_labels())
	_lifespan_slider.value_changed.connect(func(v: float) -> void:
		GlobalParams.set_param(&"lifespan_multiplier", v); _update_slider_labels())
	_repro_slider.value_changed.connect(func(v: float) -> void:
		GlobalParams.set_param(&"reproductive_appetite_modifier", v); _update_slider_labels())
	_territoriality_slider.value_changed.connect(func(v: float) -> void:
		GlobalParams.set_param(&"territoriality_modifier", v); _update_slider_labels())
	_memory_slider.value_changed.connect(func(v: float) -> void:
		GlobalParams.set_param(&"social_memory_capacity", v); _update_slider_labels())

	_refresh_experimentation_label()

	_navmesh_button.toggled.connect(_on_navmesh_toggled)
	_territory_button.toggled.connect(_on_territory_toggled)

	# Botón de "Modo control" (3ª persona). Su etiqueta/acción dependen de la
	# selección actual y de si ya se está controlando una esfera.
	_control_button.pressed.connect(_on_control_button_pressed)
	Selection.selected_changed.connect(_on_control_state_changed)
	Selection.group_highlight_changed.connect(_on_control_state_changed)
	PlayerControl.control_started.connect(_on_control_state_changed)
	PlayerControl.control_ended.connect(_on_control_state_changed)
	_refresh_control_ui()

	_species_panel = SpeciesPanelScript.new()
	_species_panel.visible = false
	# Anclado al borde derecho, debajo del panel de globales.
	_species_panel.anchor_left = 1.0
	_species_panel.anchor_right = 1.0
	_species_panel.anchor_top = 0.0
	_species_panel.anchor_bottom = 0.0
	_species_panel.offset_left = -360.0
	_species_panel.offset_top = 440.0
	_species_panel.offset_right = -12.0
	_species_panel.offset_bottom = 880.0
	_species_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_species_panel.grow_vertical = Control.GROW_DIRECTION_END
	_root.add_child(_species_panel)

	_stats_panel = StatsPanelScript.new()
	_stats_panel.visible = false
	# Esquina inferior izquierda, encima del panel de ayuda.
	_stats_panel.anchor_left = 0.0
	_stats_panel.anchor_right = 0.0
	_stats_panel.anchor_top = 0.0
	_stats_panel.anchor_bottom = 0.0
	_stats_panel.offset_left = 12.0
	_stats_panel.offset_top = 60.0
	_stats_panel.offset_right = 372.0
	_stats_panel.offset_bottom = 520.0
	_root.add_child(_stats_panel)

	# Gráfico de barras PERMANENTE de grupos: arriba a la derecha, bajo el header.
	_group_chart_panel = GroupChartPanelScript.new()
	_group_chart_panel.anchor_left = 1.0
	_group_chart_panel.anchor_right = 1.0
	_group_chart_panel.anchor_top = 0.0
	_group_chart_panel.anchor_bottom = 0.0
	_group_chart_panel.offset_left = -332.0
	_group_chart_panel.offset_top = 44.0
	_group_chart_panel.offset_right = -12.0
	_group_chart_panel.offset_bottom = 244.0
	_group_chart_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_group_chart_panel.grow_vertical = Control.GROW_DIRECTION_END
	_root.add_child(_group_chart_panel)
	# Detrás de los paneles plegables (ParamsPanel comparte la esquina): así al
	# abrir P el panel de parámetros lo cubre en vez de quedar tapado por él.
	_root.move_child(_group_chart_panel, 1)

	# Ventana de inspección de grupo: aparece al clicar una barra del gráfico,
	# justo debajo de él. Movible (DraggablePanel); oculta hasta seleccionar.
	_group_inspect_panel = GroupInspectPanelScript.new()
	_group_inspect_panel.anchor_left = 1.0
	_group_inspect_panel.anchor_right = 1.0
	_group_inspect_panel.anchor_top = 0.0
	_group_inspect_panel.anchor_bottom = 0.0
	_group_inspect_panel.offset_left = -332.0
	_group_inspect_panel.offset_top = 252.0
	_group_inspect_panel.offset_right = -12.0
	_group_inspect_panel.offset_bottom = 392.0
	_group_inspect_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_group_inspect_panel.grow_vertical = Control.GROW_DIRECTION_END
	_root.add_child(_group_inspect_panel)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				SimulationClock.toggle_pause()
			KEY_1:
				SimulationClock.set_speed(1.0)
			KEY_2:
				SimulationClock.set_speed(2.0)
			KEY_3:
				SimulationClock.set_speed(4.0)
			KEY_4:
				SimulationClock.set_speed(8.0)
			KEY_5:
				SimulationClock.set_speed(16.0)
			KEY_H:
				_ui_visible = not _ui_visible
				_root.visible = _ui_visible
			KEY_P:
				_params_panel.visible = not _params_panel.visible
			KEY_S:
				if _species_panel != null:
					_species_panel.visible = not _species_panel.visible
			KEY_K:
				if _help_panel != null:
					_help_panel.visible = not _help_panel.visible
			KEY_T:
				if _stats_panel != null:
					_stats_panel.visible = not _stats_panel.visible
			KEY_E:
				# En modo control E es "interactuar" (lo maneja PlayerController); no
				# togglear experimentación a la vez.
				if not PlayerControl.is_active():
					GlobalParams.experimentation_mode = not GlobalParams.experimentation_mode
					_refresh_experimentation_label()
			KEY_N:
				# Toggle del visualizador del navmesh (debug). El botón y la
				# tecla quedan sincronizados gracias a `set_pressed_no_signal`.
				var world: World = _find_world()
				if world != null:
					var v: bool = world.toggle_navmesh_visible()
					_navmesh_button.set_pressed_no_signal(v)
			KEY_O:
				# Ciclo del overlay territorial: apagado → especie → grupo.
				var w: World = _find_world()
				if w != null:
					_refresh_territory_button(w.cycle_territory_overlay())


func _on_speed_changed(speed: float) -> void:
	if speed <= 0.0:
		_speed_label.text = "⏸ PAUSA"
	else:
		_speed_label.text = "▶ x%s" % String.num(speed, 1)


func _on_tick(_dt: float) -> void:
	if SimulationClock.get_tick_count() % 6 != 0:
		return
	_tick_label.text = "tick %d" % SimulationClock.get_tick_count()
	var tree: SceneTree = get_tree()
	var spheres: Array = tree.get_nodes_in_group(&"spheres")
	_pop_label.text = "👥 %d" % spheres.size()
	_plant_label.text = "🌱 %d" % tree.get_nodes_in_group(&"plants").size()
	var max_gen: int = 1
	for s in spheres:
		if s is Sphere and s.generation > max_gen:
			max_gen = s.generation
	_gen_label.text = "gen %d" % max_gen

	_repro_value.text = "×%s" % String.num(GlobalParams.reproductive_appetite_modifier, 2)
	_memory_value.text = "%d" % GlobalParams.social_memory_capacity

func _update_slider_labels() -> void:
	_mutation_value.text = String.num(GlobalParams.mutation_base_rate, 2)
	_aggression_value.text = "×%s" % String.num(GlobalParams.aggression_modifier, 2)
	_sociability_value.text = "×%s" % String.num(GlobalParams.sociability_modifier, 2)
	_lifespan_value.text = "×%s" % String.num(GlobalParams.lifespan_multiplier, 2)
	_territoriality_value.text = "×%s" % String.num(GlobalParams.territoriality_modifier, 2)


func _refresh_experimentation_label() -> void:
	if GlobalParams.experimentation_mode:
		_exp_label.text = "🧪 EXPERIMENTACIÓN"
		_exp_label.modulate = Color(1.0, 0.5, 0.3, 1.0)
	else:
		_exp_label.text = ""


func _on_navmesh_toggled(pressed: bool) -> void:
	var world: World = _find_world()
	if world != null:
		world.set_navmesh_visible(pressed)


func _on_territory_toggled(pressed: bool) -> void:
	var world: World = _find_world()
	if world != null:
		world.set_territory_overlay_enabled(pressed)
	_refresh_territory_button(1 if pressed else 0)


## Sincroniza el botón "Territorio" con el estado del overlay (0=off, 1=especie,
## 2=grupo): pulsado si está encendido y la etiqueta según el modo.
func _refresh_territory_button(state: int) -> void:
	_territory_button.set_pressed_no_signal(state != 0)
	match state:
		1:
			_territory_button.text = "Territorio: especie"
		2:
			_territory_button.text = "Territorio: grupo"
		_:
			_territory_button.text = "Territorio (O)"


## Localiza la escena `World` actual sin acoplarse a una ruta concreta.
func _find_world() -> World:
	var arr: Array = get_tree().get_nodes_in_group(&"world")
	if arr.is_empty():
		return null
	return arr[0] as World


# ---------------- MODO CONTROL ----------------

## Acción del botón de control según el estado: salir si ya se controla; si no,
## tomar control de la esfera seleccionada o, en su defecto, del líder del grupo
## marcado. Ver `PlayerControl`.
func _on_control_button_pressed() -> void:
	if PlayerControl.is_active():
		PlayerControl.release()
		return
	if Selection.current != null and is_instance_valid(Selection.current):
		PlayerControl.take_control(Selection.current)
	elif Selection.highlighted_group_id != -1 and Groups.has_group(Selection.highlighted_group_id):
		PlayerControl.take_control(Groups.leader_of(Selection.highlighted_group_id))


## Refresca el botón/etiqueta al cambiar selección, grupo marcado o estado de control.
## Firma con argumento opcional para servir a las cuatro señales conectadas
## (selected_changed/group_highlight_changed pasan 1 arg; control_ended pasa 0).
func _on_control_state_changed(_arg = null) -> void:
	_refresh_control_ui()


func _refresh_control_ui() -> void:
	if PlayerControl.is_active():
		_control_button.text = "Salir de control"
		_control_button.disabled = false
		_control_label.text = "🎮 %s — WASD mover · Shift correr · Clic atacar · E interactuar · Esc salir" \
			% PlayerControl.pawn.full_name()
		return
	_control_label.text = ""
	if Selection.current != null and is_instance_valid(Selection.current):
		_control_button.text = "Tomar control"
		_control_button.disabled = false
	elif Selection.highlighted_group_id != -1 and Groups.has_group(Selection.highlighted_group_id):
		_control_button.text = "Controlar líder"
		_control_button.disabled = false
	else:
		_control_button.text = "Tomar control"
		_control_button.disabled = true
