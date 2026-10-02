class_name CameraRig
extends Node3D
## Cámara libre tipo viewport de editor.
##
## - Paneo: click central + arrastrar, o WASD.
## - Zoom: rueda del ratón.
## - Órbita: click derecho + arrastrar.
## - Seguimiento: automático al seleccionar una esfera o marcar un grupo; la
##   cámara persigue suavemente al objetivo. Panear a mano lo suelta; `F` lo
##   reengancha al seleccionado actual. Zoom y órbita NO lo cancelan.
## - Reset cenital puro: tecla `R`.
##
## Ver docs: docs/GDD/UI - UX.md (sección "Cámara — controles tipo editor").

@export var pan_speed: float = 20.0
@export var zoom_speed: float = 4.0
@export var orbit_speed: float = 0.005
@export var min_distance: float = 5.0
@export var max_distance: float = 200.0

@onready var _yaw: Node3D = $Yaw
@onready var _pitch: Node3D = $Yaw/Pitch
@onready var _camera: Camera3D = $Yaw/Pitch/Camera3D

var _distance: float = 50.0
var _orbiting: bool = false
var _panning: bool = false
var _left_press_pos: Vector2 = Vector2.ZERO
var _left_dragging: bool = false

## Seguimiento de cámara. El pivote (`global_position`) persigue al objetivo con un
## lerp frame-rate-independiente. GROUP sigue el centroide cacheado del grupo.
enum FollowMode { NONE, UNIT, GROUP }
var _follow_mode: int = FollowMode.NONE
var _follow_group_id: int = -1
## Rigidez del seguimiento: mayor = la cámara se pega más rápido al objetivo.
const FOLLOW_SMOOTH: float = 8.0

## Modo control (3ª persona): la cámara orbita pegada a la esfera poseída con
## mouse-look. Distancia corta, leve picado y un pivote algo elevado para encuadrar
## al humanoide. Ver `PlayerControl` y docs/GDD/UI - UX.md (sección "Modo control").
const THIRD_PERSON_DISTANCE: float = 6.0
const THIRD_PERSON_HEIGHT: float = 1.2
const THIRD_PERSON_PITCH: float = -0.35   # radianes (~-20°), ligeramente picado
var _third_person: bool = false


func _ready() -> void:
	# El alejamiento máximo (y el plano lejano) se escalan con el tamaño del mundo
	# para que mapas grandes quepan en pantalla. No reduce los límites por defecto.
	max_distance = maxf(max_distance, SimConfig.world_size * 1.6)
	_camera.far = maxf(_camera.far, SimConfig.world_size * 3.0)
	_apply_top_down_reset()
	# Seguir automáticamente al seleccionar una esfera o marcar un grupo.
	Selection.selected_changed.connect(_on_selection_changed)
	Selection.group_highlight_changed.connect(_on_group_highlight_changed)
	# Entrar/salir de 3ª persona al tomar/soltar el control de una esfera.
	PlayerControl.control_started.connect(_on_control_started)
	PlayerControl.control_ended.connect(_on_control_ended)


func _unhandled_input(event: InputEvent) -> void:
	# 3ª persona: el movimiento de ratón mira alrededor (mouse-look, sin botón);
	# el resto de controles de observador (pan/órbita/picking/R/F) quedan inertes.
	# El movimiento del pawn y `Esc` los gestiona `PlayerController`.
	if _third_person:
		if event is InputEventMouseMotion:
			var mm: InputEventMouseMotion = event
			_yaw.rotate_y(-mm.relative.x * orbit_speed)
			_pitch.rotate_x(-mm.relative.y * orbit_speed)
			_pitch.rotation.x = clampf(_pitch.rotation.x, -PI * 0.49, PI * 0.49)
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_left_press_pos = mb.position
				_left_dragging = false
			else:
				if not _left_dragging:
					_pick_at(mb.position)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom(-zoom_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom(zoom_speed)
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _orbiting:
			_yaw.rotate_y(-mm.relative.x * orbit_speed)
			_pitch.rotate_x(-mm.relative.y * orbit_speed)
			_pitch.rotation.x = clampf(_pitch.rotation.x, -PI * 0.49, PI * 0.49)
		elif _panning:
			_pan_screen_space(mm.relative)
		else:
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				if mm.position.distance_to(_left_press_pos) > 6.0:
					_left_dragging = true
	elif event is InputEventKey and event.pressed and not event.echo:
		var key: InputEventKey = event
		if key.keycode == KEY_R:
			_apply_top_down_reset()
		elif key.keycode == KEY_F:
			_focus_selected()


func _process(delta: float) -> void:
	# 3ª persona: el pivote persigue a la esfera poseída (WASD lo consume el
	# `PlayerController` para mover el pawn, no para panear). El yaw/pitch los fija
	# el mouse-look; aquí solo seguimos la posición.
	if _third_person:
		var pawn: Sphere = PlayerControl.pawn
		if pawn != null and is_instance_valid(pawn):
			var target: Vector3 = pawn.global_position + Vector3(0.0, THIRD_PERSON_HEIGHT, 0.0)
			var t: float = 1.0 - exp(-delta * FOLLOW_SMOOTH)
			global_position = global_position.lerp(target, t)
		return
	# WASD paneo en plano XZ relativo al yaw actual.
	var dir: Vector3 = Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		dir.z += 1.0
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if dir != Vector3.ZERO:
		# Paneo manual: el jugador toma el control, soltar el seguimiento.
		_cancel_follow()
		dir = dir.normalized()
		var multiplier: float = 1.0
		if Input.is_key_pressed(KEY_SHIFT):
			multiplier = 3.0
		elif Input.is_key_pressed(KEY_CTRL):
			multiplier = 0.3
		var world_dir: Vector3 = _yaw.global_transform.basis * dir
		world_dir.y = 0.0
		global_position += world_dir * pan_speed * multiplier * delta
		return
	# Sin paneo manual: si seguimos a algo, perseguir su posición suavemente.
	if _follow_mode != FollowMode.NONE:
		var target = _follow_target_pos()
		if target == null:
			_follow_mode = FollowMode.NONE
		else:
			# Lerp frame-rate-independiente: la cámara se pega al objetivo con
			# un retardo elástico constante sea cual sea el framerate.
			var t: float = 1.0 - exp(-delta * FOLLOW_SMOOTH)
			global_position = global_position.lerp(target, t)


func _pan_screen_space(relative: Vector2) -> void:
	# Arrastre central = paneo manual: soltar el seguimiento.
	_cancel_follow()
	var factor: float = _distance * 0.0015
	var right: Vector3 = _yaw.global_transform.basis.x
	var forward: Vector3 = _yaw.global_transform.basis.z
	right.y = 0.0
	forward.y = 0.0
	global_position += (-right * relative.x + forward * relative.y) * factor


func _zoom(amount: float) -> void:
	_distance = clampf(_distance + amount, min_distance, max_distance)
	_camera.position = Vector3(0.0, 0.0, _distance)


func _apply_top_down_reset() -> void:
	# Reset cenital = retomar el control libre: soltar el seguimiento.
	_cancel_follow()
	_yaw.rotation = Vector3.ZERO
	_pitch.rotation = Vector3(-PI * 0.49, 0.0, 0.0)
	_distance = 50.0
	_camera.position = Vector3(0.0, 0.0, _distance)


func _pick_at(screen_pos: Vector2) -> void:
	## Picking sin físicas: proyecta cada esfera al screen y elige la más
	## cercana al cursor dentro de un umbral (escalado por su tamaño y
	## el zoom).
	var spheres: Array = get_tree().get_nodes_in_group(&"spheres")
	var best: Sphere = null
	var best_score: float = 9999.0
	for s in spheres:
		if not (s is Sphere):
			continue
		if _camera.is_position_behind(s.global_position):
			continue
		var sp: Vector2 = _camera.unproject_position(s.global_position)
		var screen_radius: float = _screen_radius_for(s)
		var d: float = sp.distance_to(screen_pos)
		if d > screen_radius * 1.5:
			continue
		var score: float = d / maxf(screen_radius, 1.0)
		if score < best_score:
			best_score = score
			best = s
	if best != null:
		Selection.select(best)
	else:
		Selection.clear()


func _screen_radius_for(sphere: Sphere) -> float:
	# Aprox: radio mundo / distancia * altura_viewport / 2 / tan(fov/2)
	var world_radius: float = sphere.visual_ground_radius()
	var to_cam: float = _camera.global_position.distance_to(sphere.global_position)
	var fov_rad: float = deg_to_rad(_camera.fov)
	var viewport_h: float = get_viewport().get_visible_rect().size.y
	return (world_radius * viewport_h) / (2.0 * to_cam * tan(fov_rad * 0.5))


## Reengancha el seguimiento al objetivo actual (esfera seleccionada o, en su
## defecto, grupo marcado). Útil para volver a seguir tras panear a mano.
func _focus_selected() -> void:
	if Selection.current != null and is_instance_valid(Selection.current):
		_follow_mode = FollowMode.UNIT
		_follow_group_id = -1
	elif Selection.highlighted_group_id != -1 and Groups.has_group(Selection.highlighted_group_id):
		_follow_mode = FollowMode.GROUP
		_follow_group_id = Selection.highlighted_group_id


## Activa el seguimiento de unidad al seleccionar una esfera; lo suelta al
## deseleccionar (la esfera murió o se limpió la selección).
func _on_selection_changed(sphere) -> void:
	if sphere != null and is_instance_valid(sphere):
		_follow_mode = FollowMode.UNIT
		_follow_group_id = -1
	elif _follow_mode == FollowMode.UNIT:
		_follow_mode = FollowMode.NONE


## Activa el seguimiento de grupo al marcar uno en el gráfico de grupos; lo
## suelta al desmarcar o cuando el grupo se disuelve.
func _on_group_highlight_changed(group_id: int) -> void:
	if group_id != -1:
		_follow_mode = FollowMode.GROUP
		_follow_group_id = group_id
	elif _follow_mode == FollowMode.GROUP:
		_follow_mode = FollowMode.NONE
		_follow_group_id = -1


## Posición del objetivo seguido, o null si ya no es válido (esfera muerta,
## grupo disuelto o centroide aún no calculado).
func _follow_target_pos():
	match _follow_mode:
		FollowMode.UNIT:
			if Selection.current != null and is_instance_valid(Selection.current):
				return Selection.current.global_position
		FollowMode.GROUP:
			if Groups.has_group(_follow_group_id):
				var c: Vector3 = Groups.get_centroid(_follow_group_id)
				if is_finite(c.x):
					return c
	return null


## Detiene el seguimiento sin tocar la selección (el panel de inspección sigue
## abierto). Lo invoca cualquier control que devuelva el mando al jugador.
func _cancel_follow() -> void:
	_follow_mode = FollowMode.NONE
	_follow_group_id = -1


## Entra en 3ª persona al tomar el control de `sphere`: captura el ratón (mouse-look),
## acerca la cámara y la sitúa tras el pawn con un leve picado.
func _on_control_started(sphere) -> void:
	_cancel_follow()
	_third_person = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_distance = THIRD_PERSON_DISTANCE
	_camera.position = Vector3(0.0, 0.0, _distance)
	_pitch.rotation = Vector3(THIRD_PERSON_PITCH, 0.0, 0.0)
	if sphere != null and is_instance_valid(sphere):
		global_position = sphere.global_position + Vector3(0.0, THIRD_PERSON_HEIGHT, 0.0)


## Sale de 3ª persona al soltar el control: libera el ratón y vuelve a la vista cenital
## de observador.
func _on_control_ended() -> void:
	_third_person = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_apply_top_down_reset()
