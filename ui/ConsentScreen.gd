class_name ConsentScreen
extends CanvasLayer
## Pantalla de consentimiento de la analítica (port de la de Balactorio).
##
## 🔴 NO habla con `Augur` ni con `Analytics`: solo emite la decisión, y quien la
## monta (`StartScreen`) llama a `Analytics.set_consent()`. Así sigue en pie la
## regla de que solo `Analytics` toca `Augur`.
##
## Dos modos:
## - `first_run`: primer arranque, sin decisión en disco. Tapa la pantalla de
##   inicio con un fondo opaco que se traga el input y no se cierra sin elegir.
## - `change`: desde el botón «Privacidad». Enseña la decisión actual y deja
##   volver sin cambiar nada (`closed`): abrirla por curiosidad no obliga a decidir.
##
## Ver docs: plan «Integración con Augur», sección "Pantalla de consentimiento".

signal decided(granted: bool)
signal closed

const MODE_FIRST_RUN: String = "first_run"
const MODE_CHANGE: String = "change"

# Texto fijado por el plan: la mención a la IA externa la exige el SDK, y «si
# rechazas, no se guarda nada» lo cumple `set_consent(false)`, que borra la cola local.
const TITLE_TEXT: String = "¿Nos ayudas a mejorar BioSphera?"
const BODY_TEXT: String = "Si aceptas, el juego guarda de forma anónima cómo evoluciona cada partida: población, nacimientos y muertes, combates, grupos y granjas, y los rasgos medios de las especies. Sirve para ajustar el equilibrio de la simulación.\n\nNo se recoge tu nombre, ni tu IP, ni nada fuera del juego. Los datos se identifican con un número aleatorio de esta instalación, se guardan en un servidor propio y pueden analizarse bajo demanda con un servicio de IA externo (Anthropic Claude).\n\nPuedes cambiar de opinión cuando quieras desde [b]Privacidad[/b] en la pantalla de inicio. Si rechazas, no se guarda nada."

# Misma paleta que `StartScreen._build_ui()`.
const BG_COLOR: Color = Color(0.09, 0.11, 0.13)
const PANEL_COLOR: Color = Color(0.13, 0.15, 0.18)
const MUTED_COLOR: Color = Color(0.65, 0.68, 0.72)

var mode: String = MODE_FIRST_RUN
var current: bool = false
var accept_button: Button
var decline_button: Button
var back_button: Button = null


## Construye la pantalla. Llamar antes de añadirla al árbol.
func initialize(p_mode: String, p_current: bool = false) -> void:
	mode = p_mode
	current = p_current
	# Si algún día se abre con el árbol en pausa, no debe congelarse.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func _build_ui() -> void:
	# Por encima de la pantalla de inicio (canvas por defecto, capa 0).
	layer = 10

	# Fondo opaco a pantalla completa que se traga los clicks: lo de debajo no se
	# puede pulsar mientras la pantalla está abierta.
	var overlay := ColorRect.new()
	overlay.color = BG_COLOR
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)

	# El panel se mide por su contenido y crece hacia los dos lados desde el centro.
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.set_corner_radius_all(4)
	style.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", style)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = TITLE_TEXT
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	# RichTextLabel para poder poner «Privacidad» en negrita.
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.text = BODY_TEXT
	body.fit_content = true
	body.scroll_active = false
	body.custom_minimum_size = Vector2(560.0, 0.0)
	vbox.add_child(body)

	# En modo `change` el jugador tiene que ver qué eligió antes de cambiarlo.
	if mode == MODE_CHANGE:
		var status := Label.new()
		status.text = "Ahora mismo: " + ("aceptado" if current else "rechazado")
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		status.modulate = MUTED_COLOR
		vbox.add_child(status)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	vbox.add_child(buttons)

	# Los dos botones iguales y sin color propio: nada de patrón oscuro que
	# empuje a aceptar.
	accept_button = _make_button("Aceptar")
	accept_button.pressed.connect(_on_decided.bind(true))
	buttons.add_child(accept_button)

	decline_button = _make_button("No, gracias")
	decline_button.pressed.connect(_on_decided.bind(false))
	buttons.add_child(decline_button)

	if mode == MODE_CHANGE:
		back_button = Button.new()
		back_button.text = "Volver"
		back_button.pressed.connect(_on_back)
		vbox.add_child(back_button)
		# Marca la decisión actual dejando el foco en su botón (diferido: el foco
		# solo se coge dentro del árbol).
		_focus_current.call_deferred()


func _focus_current() -> void:
	if is_inside_tree():
		(accept_button if current else decline_button).grab_focus()


func _make_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(180.0, 46.0)
	btn.add_theme_font_size_override("font_size", 18)
	return btn


func _on_decided(granted: bool) -> void:
	decided.emit(granted)
	queue_free()


func _on_back() -> void:
	closed.emit()
	queue_free()
