extends Node
## Selección global (autoload `Selection`).
##
## La esfera seleccionada se actualiza desde `CameraRig` cuando el
## jugador hace click. El `InspectPanel` y la cámara (foco con `F`)
## escuchan el cambio.
##
## Ver docs: docs/GDD/UI - UX.md (sección "Inspección de un individuo").

signal selected_changed(sphere)
## Emitida al cambiar el grupo resaltado desde el gráfico de grupos.
signal group_highlight_changed(group_id: int)

var current: Sphere = null
## Grupo resaltado desde el gráfico de grupos (-1 = ninguno). Lo consume el
## overlay `GroupHighlight` para marcar a los miembros del grupo en el plano.
var highlighted_group_id: int = -1


func select(sphere: Sphere) -> void:
	if sphere == current:
		return
	if current != null and is_instance_valid(current):
		if current.died.is_connected(_on_current_died):
			current.died.disconnect(_on_current_died)
	current = sphere
	if sphere != null:
		sphere.died.connect(_on_current_died, CONNECT_ONE_SHOT)
	selected_changed.emit(sphere)


func clear() -> void:
	select(null)


## Marca un grupo (por id) para resaltar a sus miembros en el plano. Volver a
## marcar el mismo no hace nada (el toggle vive en el gráfico que lo invoca).
func highlight_group(group_id: int) -> void:
	if highlighted_group_id == group_id:
		return
	highlighted_group_id = group_id
	group_highlight_changed.emit(group_id)


func clear_group_highlight() -> void:
	if highlighted_group_id == -1:
		return
	highlighted_group_id = -1
	group_highlight_changed.emit(-1)


func _on_current_died(_cause: StringName) -> void:
	clear()
