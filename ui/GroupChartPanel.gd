class_name GroupChartPanel
extends PanelContainer
## Gráfico de barras PERMANENTE de los grupos vivos (arriba a la derecha, bajo
## el header). Una barra por grupo: altura ∝ nº de miembros, color = color del
## grupo (el mismo con el que se tiñen sus esferas en el plano, ver
## `GroupSystem._color_for_id`). Ordenadas por tamaño descendente.
##
## El título y los márgenes dejan pasar el ratón (el picking de esferas sigue
## funcionando bajo ellos); el área del gráfico SÍ captura clics: clicar una
## barra resalta a los miembros de ese grupo en el plano (overlay
## `GroupHighlight`) y dibuja un contorno en la barra. Se crea desde `Hud`.

const COLOR_BG: Color = Color(0.08, 0.08, 0.1, 0.4)
const COLOR_AXIS: Color = Color(0.5, 0.5, 0.5, 0.6)
## Tope de barras dibujadas: con muchos grupos pequeños, dibujar todos los hace
## ilegibles. El resto se indica en el título ("top N").
const MAX_BARS: int = 24
const BAR_GAP: float = 2.0
## Refresco ~2-3 veces por segundo a x1 (30 ticks/s). Suficiente: los grupos
## cambian despacio.
const REFRESH_TICKS: int = 12

var _title: Label
var _chart: Control
var _summary: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var margin := MarginContainer.new()
	margin.add_theme_constant_override(&"margin_left", 10)
	margin.add_theme_constant_override(&"margin_right", 10)
	margin.add_theme_constant_override(&"margin_top", 8)
	margin.add_theme_constant_override(&"margin_bottom", 8)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	_title = Label.new()
	_title.text = "Grupos: 0"
	_title.add_theme_font_size_override(&"font_size", 13)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_title)

	_chart = Control.new()
	_chart.custom_minimum_size = Vector2(300, 150)
	_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# El área del gráfico SÍ captura clics (el resto del panel los deja pasar):
	# clicar una barra resalta a los miembros de ese grupo en el plano.
	_chart.mouse_filter = Control.MOUSE_FILTER_STOP
	_chart.draw.connect(_draw_chart)
	_chart.gui_input.connect(_on_chart_gui_input)
	vbox.add_child(_chart)

	SimulationClock.tick.connect(_on_tick)
	# Redibujar el contorno de la barra activa si el resaltado cambia desde fuera
	# (p. ej. el overlay lo limpia al disolverse el grupo).
	Selection.group_highlight_changed.connect(func(_id: int) -> void: _chart.queue_redraw())
	_refresh()


func _on_tick(_dt: float) -> void:
	if SimulationClock.get_tick_count() % REFRESH_TICKS != 0:
		return
	_refresh()


## Clic en el área del gráfico: resalta el grupo de la barra pulsada (toggle).
## Clic fuera de cualquier barra → quita el resaltado.
func _on_chart_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed \
			or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var shown: int = mini(_summary.size(), MAX_BARS)
	if shown <= 0:
		Selection.clear_group_highlight()
		return
	var bar_w: float = _chart.size.x / float(shown)
	var idx: int = int(event.position.x / bar_w)
	if idx < 0 or idx >= shown:
		Selection.clear_group_highlight()
		return
	var gid: int = int(_summary[idx]["id"])
	if Selection.highlighted_group_id == gid:
		Selection.clear_group_highlight()   # re-clic en el mismo → apagar
	else:
		Selection.highlight_group(gid)
	_chart.queue_redraw()


func _refresh() -> void:
	_summary = Groups.get_groups_summary()
	# Si el grupo resaltado se disolvió, soltar el resaltado.
	if Selection.highlighted_group_id != -1 \
			and not Groups.has_group(Selection.highlighted_group_id):
		Selection.clear_group_highlight()
	if _summary.is_empty():
		_title.text = "Grupos: 0"
	else:
		var members: int = 0
		var max_size: int = 0
		for g in _summary:
			members += int(g["size"])
			max_size = maxi(max_size, int(g["size"]))
		_title.text = "Grupos: %d · %d esferas · mayor %d" % [
			_summary.size(), members, max_size]
		if _summary.size() > MAX_BARS:
			_title.text += "  (top %d)" % MAX_BARS
	if _chart != null:
		_chart.queue_redraw()


func _draw_chart() -> void:
	var sz: Vector2 = _chart.size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	_chart.draw_rect(Rect2(Vector2.ZERO, sz), COLOR_BG)

	var font: Font = ThemeDB.fallback_font
	if _summary.is_empty():
		_chart.draw_string(font, Vector2(8.0, sz.y * 0.5), "sin grupos",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, COLOR_AXIS)
		return

	var max_size: int = 1
	for g in _summary:
		max_size = maxi(max_size, int(g["size"]))

	var shown: int = mini(_summary.size(), MAX_BARS)
	# Espacio reservado: arriba para que la barra más alta no toque el borde;
	# abajo para la línea base.
	var top_pad: float = 4.0
	var bottom_pad: float = 4.0
	var plot_h: float = sz.y - top_pad - bottom_pad
	var base_y: float = sz.y - bottom_pad
	var bar_w: float = sz.x / float(shown)

	_chart.draw_line(Vector2(0.0, base_y), Vector2(sz.x, base_y), COLOR_AXIS, 1.0)

	for i in shown:
		var g: Dictionary = _summary[i]
		var h: float = (float(g["size"]) / float(max_size)) * plot_h
		var x: float = float(i) * bar_w
		var col: Color = g["color"]
		col.a = 0.9
		_chart.draw_rect(Rect2(x + BAR_GAP * 0.5, base_y - h,
			maxf(1.0, bar_w - BAR_GAP), h), col)
		# Contorno en toda la columna del grupo resaltado (no solo en la barra,
		# para que se vea aunque la barra sea baja).
		if int(g["id"]) == Selection.highlighted_group_id:
			_chart.draw_rect(Rect2(x + BAR_GAP * 0.5, top_pad,
				maxf(1.0, bar_w - BAR_GAP), base_y - top_pad),
				Color(1, 1, 1, 0.95), false, 2.0)
		# Etiqueta con el nº de miembros solo si la barra es bastante ancha
		# (con pocos grupos); con muchas barras estrechas se omite por legible.
		if bar_w >= 16.0:
			_chart.draw_string(font, Vector2(x, base_y - h - 2.0), str(int(g["size"])),
				HORIZONTAL_ALIGNMENT_CENTER, bar_w, 9, Color(1, 1, 1, 0.85))
