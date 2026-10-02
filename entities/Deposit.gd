class_name Deposit
extends ResourceNode
## Yacimiento FINITO de piedra u oro (clase base `ResourceNode`).
##
## Sirve los dos recursos no renovables: cada extracción descuenta unidades y,
## cuando se agota, el yacimiento desaparece (no rebrota). De ahí emerge la
## escasez de piedra/oro y el valor territorial de las zonas ricas (ver decisión
## de diseño "modelo mixto"). Es estático y NO tickea (coste cero por frame).
##
## El tipo (STONE/GOLD) y las existencias las fija quien lo spawnea ANTES de
## llamar a `activate()`.
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Economía y recursos").

@export var deposit_type: int = Type.STONE   # STONE o GOLD (fijado al spawnear)
@export var units_total: int = 8
@export var units_per_harvest: int = 1

var units_left: int = 0


func _ready() -> void:
	_init_resource_node()


## Activación explícita (último paso tras fijar tipo, posición y existencias):
## registra el índice espacial y loguea. No registra tick (yacimiento inerte).
func activate() -> void:
	type = deposit_type
	units_left = units_total
	add_to_group(group_for(type))
	SpatialIndex.register_resource(self, type)
	EventLog.log_state_change(StringName(type_name(type)), &"spawn", {
		"id": get_instance_id(),
		"units": units_left,
		"position": [global_position.x, global_position.y, global_position.z],
	})


func harvest() -> float:
	if units_left <= 0:
		return 0.0
	var amount: int = mini(units_per_harvest, units_left)
	units_left -= amount
	harvested.emit(type, float(amount))
	if units_left <= 0:
		_deplete()
	return float(amount)


func is_harvestable() -> bool:
	return units_left > 0


func _deplete() -> void:
	EventLog.log_state_change(StringName(type_name(type)), &"depleted", {
		"id": get_instance_id(),
		"position": [global_position.x, global_position.y, global_position.z],
	})
	depleted.emit()
	queue_free()
