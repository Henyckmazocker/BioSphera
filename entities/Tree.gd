class_name TreeNode
extends ResourceNode
## Árbol: fuente de MADERA regenerable (clase base `ResourceNode`).
##
## NOTA: la clase se llama `TreeNode` y no `Tree` porque `Tree` es una clase
## integrada de Godot (el widget de UI) y `class_name Tree` colisionaría.
##
## A diferencia de la comida, no se reproduce por polinización ni muere al
## agotarse: crece hasta madurar, ofrece un número de extracciones de madera y,
## cuando se queda sin existencias, entra en `REGROWING` y rebrota tras un
## cooldown (recurso renovable estable, ver decisión de diseño "modelo mixto").
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Economía y recursos").

signal regrew

enum Stage { GROWING, MATURE, REGROWING }

const GROW_TIME: float = 15.0      # s de simulación hasta madurar desde plantón
const REGROW_TIME: float = 30.0    # s hasta volver a tener madera tras agotarse
const MAX_WOOD: int = 5            # unidades de madera por ciclo maduro
const WOOD_PER_HARVEST: int = 1   # unidades obtenidas por extracción

@export var stage: Stage = Stage.GROWING
var age: float = 0.0
var wood_left: int = 0


func _ready() -> void:
	_init_resource_node()
	type = Type.WOOD


## Activación explícita (último paso tras posicionar): registra tick lento + índice
## espacial + log. Mismo contrato que `Plant.activate`.
func activate() -> void:
	add_to_group(group_for(Type.WOOD))
	if stage == Stage.MATURE:
		wood_left = MAX_WOOD
	SimulationClock.register_entity(self, true)
	SpatialIndex.register_resource(self, Type.WOOD)
	EventLog.log_state_change(&"wood", &"spawn", {
		"id": get_instance_id(),
		"stage": _stage_name(stage),
		"position": [global_position.x, global_position.y, global_position.z],
	})


func harvest() -> float:
	if stage != Stage.MATURE or wood_left <= 0:
		return 0.0
	var amount: int = mini(WOOD_PER_HARVEST, wood_left)
	wood_left -= amount
	harvested.emit(Type.WOOD, float(amount))
	if wood_left <= 0:
		_transition_to(Stage.REGROWING)
	return float(amount)


func is_harvestable() -> bool:
	return stage == Stage.MATURE and wood_left > 0


func _on_tick(dt_sim: float) -> void:
	# El bosque acelera el crecimiento (mismo modificador que las plantas).
	var biome_growth: float = Biomes.get_mod(Biomes.biome_at(global_position), "plant_growth_mod")
	age += dt_sim * maxf(biome_growth, 0.1)
	match stage:
		Stage.GROWING:
			if age >= GROW_TIME:
				_transition_to(Stage.MATURE)
		Stage.REGROWING:
			if age >= REGROW_TIME:
				_transition_to(Stage.MATURE)
		Stage.MATURE:
			pass


func _transition_to(new_stage: Stage) -> void:
	var prev: Stage = stage
	stage = new_stage
	age = 0.0
	if new_stage == Stage.MATURE:
		wood_left = MAX_WOOD
		if prev == Stage.REGROWING:
			regrew.emit()
	EventLog.log_state_change(&"wood", &"stage_change", {
		"id": get_instance_id(),
		"position": [global_position.x, global_position.y, global_position.z],
		"prev_stage": _stage_name(prev),
		"new_stage": _stage_name(new_stage),
		"wood_left": wood_left,
	})


static func _stage_name(s: Stage) -> String:
	match s:
		Stage.GROWING: return "growing"
		Stage.MATURE: return "mature"
		Stage.REGROWING: return "regrowing"
		_: return "unknown"
