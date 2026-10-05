class_name GroupInspectPanel
extends "res://ui/DraggablePanel.gd"
## Ventana flotante con la información del grupo seleccionado en el gráfico de
## grupos (clic en una barra). Espejo de `InspectPanel` pero a nivel de grupo:
## líder, recursos de la bolsa común, poder, unidades con arma, nº de granjas y nido.
##
## Se muestra cuando `Selection.highlighted_group_id != -1` (lo fija el clic en
## `GroupChartPanel`) y se oculta al deseleccionar o si el grupo se disuelve.
## Datos vía `GroupSystem.get_group_info`.
##
## Ver docs: docs/GDD/UI - UX.md.

## Refresco ~6 veces/s a x1 (igual cadencia que InspectPanel).
const REFRESH_TICKS: int = 5

var _title: Label
var _body: Label
var _gid: int = -1


func _ready() -> void:
	super._ready()
	visible = false
	custom_minimum_size = Vector2(300.0, 0.0)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override(&"margin_left", 10)
	margin.add_theme_constant_override(&"margin_right", 10)
	margin.add_theme_constant_override(&"margin_top", 8)
	margin.add_theme_constant_override(&"margin_bottom", 8)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 4)
	margin.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override(&"font_size", 14)
	vbox.add_child(_title)

	_body = Label.new()
	_body.add_theme_font_size_override(&"font_size", 12)
	vbox.add_child(_body)

	Selection.group_highlight_changed.connect(_on_group_changed)
	SimulationClock.tick.connect(_on_tick)


func _on_group_changed(group_id: int) -> void:
	_gid = group_id
	if group_id == -1 or not Groups.has_group(group_id):
		visible = false
		return
	visible = true
	_refresh()


func _on_tick(_dt: float) -> void:
	if not visible or _gid == -1:
		return
	if SimulationClock.get_tick_count() % REFRESH_TICKS != 0:
		return
	if not Groups.has_group(_gid):
		visible = false
		return
	_refresh()


func _refresh() -> void:
	var info: Dictionary = Groups.get_group_info(_gid)
	if info.is_empty():
		visible = false
		return
	var gname: String = String(info["name"])
	_title.text = gname if gname != "" else "Grupo %d" % _gid
	_body.text = (
		"líder: %s\n"
		+ "unidades: %d · con arma: %d\n"
		+ "objetivo: %s · cohesión: %.0f\n"
		+ "poder: %.2f · granjas: %d\n"
		+ "%s\n"
		+ "bolsa — 🪵 %d · 🪨 %d · 🟡 %d"
	) % [
		info["leader"],
		int(info["size"]), int(info["armed"]),
		_goal_name(int(info["goal"])), float(info["cohesion"]),
		float(info["power"]), int(info["farms"]),
		_nest_line(int(info.get("nest_day", -1))),
		int(info["wood"]), int(info["stone"]), int(info["gold"]),
	]
	# Línea de guerra solo si el grupo tiene un objetivo enemigo activo.
	var war_target: String = String(info.get("war_target", ""))
	if war_target != "":
		var modo: String = "⚔ a muerte (líder)" if bool(info.get("war_leader", false)) else "invadir"
		_body.text += "\n%s → %s" % [modo, war_target]


## `nest_day` llega en base 0 (`Climate.day_index`); se muestra en base 1, como el
## día de las ranuras de guardado en StartScreen.
func _nest_line(nest_day: int) -> String:
	if nest_day < 0:
		return "Nido: nómada"
	return "Nido: desde el día %d" % (nest_day + 1)


func _goal_name(goal: int) -> String:
	match goal:
		Groups.Goal.FORAGE: return "forrajear"
		Groups.Goal.MIGRATE: return "migrar"
		Groups.Goal.BUILD_FARM: return "construir granja"
		Groups.Goal.INVADE: return "invadir/guerra"
		_: return "reagrupar"
