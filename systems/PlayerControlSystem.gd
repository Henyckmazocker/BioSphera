extends Node
## Control directo de una esfera (autoload `PlayerControl`).
##
## "Modo control": un modo PARALELO al de observador en el que el jugador POSEE
## una esfera y la maneja en 3ª persona (mover, correr, atacar, interactuar). La
## esfera sigue siendo un organismo real de la simulación (gasta energía, puede
## morir); al morir se sale del modo. Coordina los tres lados del modo:
##   - `Sphere`: salta su IA mientras está poseída (ver `Sphere.set_controlled`).
##   - `PlayerController`: traduce input a movimiento/acciones por frame.
##   - `CameraRig`: pasa a 3ª persona con mouse-look.
##
## Holder de estado al estilo de `SelectionSystem.gd`: el resto de sistemas
## reaccionan a sus señales en vez de acoplarse entre sí.
##
## Ver docs: docs/GDD/UI - UX.md (sección "Modo control").

## Emitida al empezar a controlar `sphere` (la cámara entra en 3ª persona).
signal control_started(sphere)
## Emitida al soltar el control (la cámara vuelve a observador).
signal control_ended()

## Esfera poseída actualmente (null = modo observador normal).
var pawn: Sphere = null


func is_active() -> bool:
	return pawn != null and is_instance_valid(pawn)


## Toma el control de `sphere`. Suelta la esfera anterior si la había. No hace
## nada si `sphere` es nula/inválida o ya es la poseída.
func take_control(sphere) -> void:
	if sphere == null or not is_instance_valid(sphere) or not (sphere is Sphere):
		return
	if sphere == pawn:
		return
	if is_active():
		release()
	pawn = sphere
	pawn.set_controlled(true)
	# Salir del modo automáticamente cuando la esfera muere (hambre, combate, edad).
	pawn.died.connect(_on_pawn_died, CONNECT_ONE_SHOT)
	control_started.emit(pawn)


## Suelta el control y devuelve el mando al modo observador.
func release() -> void:
	if not is_active():
		pawn = null
		control_ended.emit()
		return
	if pawn.died.is_connected(_on_pawn_died):
		pawn.died.disconnect(_on_pawn_died)
	pawn.set_controlled(false)
	pawn = null
	control_ended.emit()


func _on_pawn_died(_cause: StringName) -> void:
	# La esfera ya se libera sola (`Sphere._die`); aquí solo cerramos el modo.
	pawn = null
	control_ended.emit()
