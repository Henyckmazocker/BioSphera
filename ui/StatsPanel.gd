extends "res://ui/DraggablePanel.gd"
## Panel de estad\u00edsticas en vivo.
##
## Lee de `Stats` autoload. Muestra contadores (poblaci\u00f3n, plantas,
## generaci\u00f3n m\u00e1xima, nacimientos / muertes por causa) y dibuja un
## peque\u00f1o gr\u00e1fico de l\u00edneas con la historia de poblaci\u00f3n.
##
## Tecla `T` para mostrar/ocultar.

const COLOR_A: Color = Color(1.0, 0.55, 0.45)
const COLOR_B: Color = Color(0.45, 0.75, 1.0)
const COLOR_PLANTS: Color = Color(0.5, 0.85, 0.5)
const COLOR_AXIS: Color = Color(0.3, 0.3, 0.3, 0.6)
const COLOR_BG: Color = Color(0.08, 0.08, 0.1, 0.4)

var _summary_label: Label
var _causes_label: Label
var _chart: Control


func _ready() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override(&"margin_left", 12)
	margin.add_theme_constant_override(&"margin_right", 12)
	margin.add_theme_constant_override(&"margin_top", 10)
	margin.add_theme_constant_override(&"margin_bottom", 10)
	add_child(margin)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 6)
	margin.add_child(vbox)

	var title: Label = Label.new()
	title.text = "Estad\u00edsticas (T)"
	title.add_theme_font_size_override(&"font_size", 14)
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_summary_label)

	vbox.add_child(HSeparator.new())

	var legend: Label = Label.new()
	legend.text = "[A naranja]  [B azul]  [Plantas verde]"
	legend.add_theme_font_size_override(&"font_size", 10)
	vbox.add_child(legend)

	_chart = Control.new()
	_chart.custom_minimum_size = Vector2(320, 120)
	_chart.draw.connect(_draw_chart)
	vbox.add_child(_chart)

	vbox.add_child(HSeparator.new())

	_causes_label = Label.new()
	_causes_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_causes_label)

	Stats.sample_taken.connect(_refresh)
	_refresh()


func _refresh() -> void:
	_summary_label.text = "\n".join([
		"Poblaci\u00f3n A: %d" % Stats.pop_A,
		"Poblaci\u00f3n B: %d" % Stats.pop_B,
		"Plantas: %d" % Stats.plants_count,
		"Generaci\u00f3n m\u00e1x: %d" % Stats.max_generation,
		"Nacimientos: %d (A:%d B:%d)" % [
			Stats.total_births,
			int(Stats.births_by_species.get(&"A", 0)),
			int(Stats.births_by_species.get(&"B", 0)),
		],
		"Muertes: %d (A:%d B:%d)" % [
			Stats.total_deaths,
			int(Stats.deaths_by_species.get(&"A", 0)),
			int(Stats.deaths_by_species.get(&"B", 0)),
		],
	])
	var causes: PackedStringArray = PackedStringArray()
	causes.append("Muertes por causa:")
	if Stats.deaths_by_cause.is_empty():
		causes.append("  (sin datos)")
	else:
		var keys: Array = Stats.deaths_by_cause.keys()
		keys.sort()
		for k in keys:
			causes.append("  %s: %d" % [String(k), int(Stats.deaths_by_cause[k])])
	_causes_label.text = "\n".join(causes)
	if _chart != null:
		_chart.queue_redraw()


func _draw_chart() -> void:
	var size_v: Vector2 = _chart.size
	if size_v.x <= 0.0 or size_v.y <= 0.0:
		return
	_chart.draw_rect(Rect2(Vector2.ZERO, size_v), COLOR_BG)

	var hist_a: Array[int] = Stats.history_pop_A
	var hist_b: Array[int] = Stats.history_pop_B
	var hist_p: Array[int] = Stats.history_plants
	var n: int = hist_a.size()
	if n < 2:
		return

	# Escala Y: max de los tres histogramas (con m\u00ednimo razonable).
	var max_v: int = 1
	for v in hist_a:
		if v > max_v:
			max_v = v
	for v in hist_b:
		if v > max_v:
			max_v = v
	for v in hist_p:
		if v > max_v:
			max_v = v
	var max_f: float = float(max_v)

	# Eje base.
	_chart.draw_line(Vector2(0, size_v.y - 1), Vector2(size_v.x, size_v.y - 1), COLOR_AXIS, 1.0)

	_draw_series(hist_a, max_f, size_v, COLOR_A)
	_draw_series(hist_b, max_f, size_v, COLOR_B)
	_draw_series(hist_p, max_f, size_v, COLOR_PLANTS)

	# Etiqueta de m\u00e1ximo.
	var font: Font = ThemeDB.fallback_font
	_chart.draw_string(font, Vector2(4, 12), "max %d" % max_v,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, COLOR_AXIS)


func _draw_series(hist: Array, max_f: float, size_v: Vector2, color: Color) -> void:
	var n: int = hist.size()
	if n < 2:
		return
	var step_x: float = size_v.x / float(n - 1)
	var pts: PackedVector2Array = PackedVector2Array()
	pts.resize(n)
	for i in n:
		var v: float = float(hist[i])
		var y: float = size_v.y - (v / max_f) * (size_v.y - 4.0) - 2.0
		pts[i] = Vector2(i * step_x, y)
	for i in n - 1:
		_chart.draw_line(pts[i], pts[i + 1], color, 1.5)
