class_name PlayerController
extends Node
## Traductor de input → esfera poseída (modo control en 3ª persona).
##
## Hijo de `World`. Solo actúa cuando `PlayerControl` está activo; en modo
## observador no hace nada (el control de cámara/selección sigue en `CameraRig`).
## Lee el input al estilo de `CameraRig` (teclas hardcodeadas, sin InputMap):
##   - WASD: mover, relativo a la orientación de la cámara (mouse-look).
##   - Shift mantenido: correr.
##   - Clic izquierdo mantenido: atacar (combate continuo).
##   - E: interactuar (comer / recolectar / reproducirse, contextual).
##   - Esc: soltar el control y volver a observador.
##
## Ver docs: docs/GDD/UI - UX.md (sección "Modo control").


func _process(delta: float) -> void:
	if not PlayerControl.is_active() or SimulationClock.is_paused():
		return
	var pawn: Sphere = PlayerControl.pawn
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	# Dirección de avance relativa a la cámara, aplanada a XZ.
	var forward: Vector3 = -cam.global_transform.basis.z
	var right: Vector3 = cam.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	var move_dir: Vector3 = Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move_dir += forward
	if Input.is_key_pressed(KEY_S):
		move_dir -= forward
	if Input.is_key_pressed(KEY_D):
		move_dir += right
	if Input.is_key_pressed(KEY_A):
		move_dir -= right
	var sprint: bool = Input.is_key_pressed(KEY_SHIFT)
	pawn.drive_player(move_dir, sprint, delta)
	# Ataque continuo mientras se mantiene el clic izquierdo.
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		pawn.player_attack(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not PlayerControl.is_active():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key: InputEventKey = event
		if key.keycode == KEY_E:
			PlayerControl.pawn.player_interact()
			get_viewport().set_input_as_handled()
		elif key.keycode == KEY_ESCAPE:
			PlayerControl.release()
			get_viewport().set_input_as_handled()
