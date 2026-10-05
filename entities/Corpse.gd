class_name Corpse
extends Node3D
## Cadáver con energía residual consumible.
##
## Cuando una esfera muere por combate o vejez deja un `Corpse` con
## energía proporcional a su tamaño. Otras esferas pueden comerlo (lo
## tratan como una planta madura más). Se descompone con el tiempo.
##
## Ver docs: docs/GDD/Mecánicas.md (combate).

const DECAY_TIME: float = 30.0
const BITE_ENERGY: float = 22.0
const MAX_BITES: int = 4

var bites_left: int = MAX_BITES
var age: float = 0.0
var color: Color = Color(0.4, 0.25, 0.2)

@onready var _mesh: MeshInstance3D = $Mesh


static func spawn(parent: Node, pos: Vector3, source_color: Color, size: float) -> Corpse:
	var scene: PackedScene = load("res://entities/Corpse.tscn")
	var c: Corpse = scene.instantiate()
	parent.add_child(c)
	c.global_position = pos
	c.color = source_color.darkened(0.4)
	c.bites_left = clampi(int(round(MAX_BITES * size)), 1, 8)
	c.activate()
	return c


## Activación explícita: se llama tras fijar posición y color. Centraliza
## el registro espacial, el tick y los visuales (que dependen de `color`)
## en un único momento. Ver Plant.activate() para el porqué.
func activate() -> void:
	# Cadencia lenta: solo cuenta el tiempo hasta descomponerse (30 s).
	SimulationClock.register_entity(self, true)
	SpatialIndex.register_plant(self)  # se trata como alimento por simplicidad
	if _mesh != null:
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 1.0
		_mesh.set_surface_override_material(0, mat)
		_mesh.scale = Vector3.ONE * 0.7


## Foto del cadáver para el save (ver `SaveGame` y `Sphere.to_save`).
func to_save(_ids: Dictionary) -> Dictionary:
	return {
		"k": &"corpse",
		"pos": global_position,
		"bites_left": bites_left,
		"age": age,
		"color": color,
	}


## Restaura desde `to_save`. Sustituye a `Corpse.spawn` en la carga: `color` va ANTES
## de `activate()`, que lo usa para el material; `activate()` no pisa nada guardado.
func from_save(d: Dictionary, _node_of: Array) -> void:
	global_position = d.pos
	color = d.color
	bites_left = int(d.bites_left)
	age = float(d.age)
	activate()


func _exit_tree() -> void:
	SimulationClock.unregister_entity(self)
	SpatialIndex.unregister_plant(self)


func consume() -> float:
	if bites_left <= 0:
		return 0.0
	bites_left -= 1
	if bites_left <= 0:
		queue_free()
	return BITE_ENERGY


func register_visit() -> void:
	pass


# Pseudo-API para que el seek_food de la esfera lo trate como planta madura.
var stage: int = Plant.Stage.MATURE


func _on_tick(dt_sim: float) -> void:
	age += dt_sim
	if age >= DECAY_TIME:
		queue_free()
