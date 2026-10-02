class_name InspectPanel
extends "res://ui/DraggablePanel.gd"
## Panel lateral con datos de la esfera seleccionada.
##
## Se muestra cuando `Selection.current` no es null. Se actualiza
## periódicamente (cada N ticks) para que cambien energía/edad/etc.
##
## Ver docs: docs/GDD/UI - UX.md (sección "Inspección de un individuo").

@onready var _name_label: Label = %InspectName
@onready var _species_label: Label = %InspectSpecies
@onready var _state_label: Label = %InspectState
@onready var _traits_label: Label = %InspectTraits
@onready var _social_label: Label = %InspectSocial
@onready var _action_label: Label = %InspectAction

var _target: Sphere = null


func _ready() -> void:
	visible = false
	Selection.selected_changed.connect(_on_selected_changed)
	SimulationClock.tick.connect(_on_tick)


func _on_selected_changed(sphere) -> void:
	_target = sphere
	if sphere == null:
		visible = false
		return
	visible = true
	_refresh()


func _on_tick(_dt: float) -> void:
	if not visible or _target == null:
		return
	if SimulationClock.get_tick_count() % 5 != 0:
		return
	if not is_instance_valid(_target) or not _target._alive:
		Selection.clear()
		return
	_refresh()


func _refresh() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	_name_label.text = _target.full_name()
	var species: String = String(_target.genome.get("species", &"?"))
	_species_label.text = "Especie %s · gen %d" % [species, _target.generation]
	_state_label.text = "E %.0f · ❤ %.0f · estrés %.0f · edad %.1f" % [
		_target.energy, _target.health, _target.stress, _target.age,
	]
	_traits_label.text = (
		"tam %.2f · vel %.2f · vis %.1f · meta %.2f\n"
		+ "agro %.2f · soc %.2f · valor %.2f · leal %.2f · terr %.2f · ind %.2f"
	) % [
		float(_target.genome.get("size", 0.0)),
		float(_target.genome.get("speed", 0.0)),
		float(_target.genome.get("vision", 0.0)),
		float(_target.genome.get("metabolism", 0.0)),
		float(_target.genome.get("aggression", 0.0)),
		float(_target.genome.get("sociability", 0.0)),
		float(_target.genome.get("bravery", 0.0)),
		float(_target.genome.get("loyalty", 0.0)),
		float(_target.genome.get("territoriality", 0.0)),
		float(_target.genome.get("industriousness", 0.0)),
	]
	_social_label.text = "grupo %s · linaje %s\n%s" % [
		_group_label(_target.group_id),
		_target.genome.get("lineage", "?"),
		_economy_label(_target),
	]
	_action_label.text = "→ %s" % _action_description(_target)


## Línea de economía: recursos disponibles para la esfera (bolsa del grupo si es
## miembro, inventario propio si es loner) y nivel de arma.
func _economy_label(s: Sphere) -> String:
	var origin: String = "bolsa" if s.group_id != -1 and Groups.has_group(s.group_id) else "propio"
	var weapon: String = "—" if s.weapon_level <= 0 else "nv %d" % s.weapon_level
	return "rec(%s): 🪵%d 🪨%d 🟡%d · arma %s" % [
		origin,
		s.available_resource(ResourceNode.Type.WOOD),
		s.available_resource(ResourceNode.Type.STONE),
		s.available_resource(ResourceNode.Type.GOLD),
		weapon,
	]


func _group_label(group_id: int) -> String:
	if group_id == -1:
		return "—"
	var goal: int = Groups.get_goal(group_id)
	var goal_name: String = "reagrupar"
	match goal:
		Groups.Goal.FORAGE: goal_name = "forrajear"
		Groups.Goal.MIGRATE: goal_name = "migrar"
		Groups.Goal.BUILD_FARM: goal_name = "construir granja"
		Groups.Goal.INVADE: goal_name = "invadir/guerra"
		Groups.Goal.GATHER: goal_name = "reagrupar"
	var gname: String = Groups.get_group_name(group_id)
	var base: String = "%d (%s)" % [group_id, goal_name] if gname == "" \
		else "%s (%s)" % [gname, goal_name]
	# Cohesión: media de afinidades internas (~[-100,100]); decae con conflictos.
	# Poder: derivado del oro de la bolsa (atrae aliados, facilita absorciones).
	return "%s · coh %.0f · poder %.2f" % [
		base, Groups.get_cohesion(group_id), Groups.power(group_id)]


func _action_description(s: Sphere) -> String:
	var action: int = s._current_action
	match action:
		BehaviorSystem.Action.WANDER:
			return "deambular"
		BehaviorSystem.Action.SEEK_FOOD:
			if s._target_plant != null and is_instance_valid(s._target_plant):
				if s._target_plant is Corpse:
					return "comer (cadáver)"
				return "buscar comida"
			return "buscar comida"
		BehaviorSystem.Action.SEEK_MATE:
			if s._target_mate != null and is_instance_valid(s._target_mate):
				return "cortejar a %s" % s._target_mate.full_name()
			return "buscar pareja"
		BehaviorSystem.Action.FLEE:
			if s._flee_target != null and is_instance_valid(s._flee_target):
				return "huir de %s" % s._flee_target.full_name()
			return "huir"
		BehaviorSystem.Action.FIGHT:
			if s._fight_target != null and is_instance_valid(s._fight_target):
				return "atacar a %s" % s._fight_target.full_name()
			return "atacar"
		BehaviorSystem.Action.FOLLOW_GROUP:
			return "seguir grupo"
		BehaviorSystem.Action.GATHER:
			if s._is_harvestable_node(s._target_resource):
				return "recolectar %s" % ResourceNode.type_name(s._target_resource.type)
			return "recolectar"
		_:
			return "?"
