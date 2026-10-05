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
## Hover para el halo de estado: última posición del ratón y si se movió desde el
## último `_process` (la búsqueda O(n) solo se hace entonces).
var _mouse_pos: Vector2 = Vector2.ZERO
var _mouse_moved: bool = false

## Seguimiento de cámara. El pivote (`global_position`) persigue al objetivo con un
## lerp frame-rate-independiente. GROUP sigue el centroide cacheado del grupo.
enum FollowMode { NONE, UNIT, GROUP }
var _follow_mode: int = FollowMode.NONE
var _follow_group_id: int = -1
## Rigidez del seguimiento: mayor = la cámara se pega más rápido al objetivo.
const FOLLOW_SMOOTH: float = 8.0


func _ready() -> void:
	# El alejamiento máximo (y el plano lejano) se escalan con el tamaño del mundo
	# para que mapas grandes quepan en pantalla. No reduce los límites por defecto.
	max_distance = maxf(max_distance, SimConfig.world_size * 1.6)
	_camera.far = maxf(_camera.far, SimConfig.world_size * 3.0)
	_apply_top_down_reset()
	# Seguir automáticamente al seleccionar una esfera o marcar un grupo.
	Selection.selected_changed.connect(_on_selection_changed)
	Selection.group_highlight_changed.connect(_on_group_highlight_changed)
	# Al salir el ratón de la ventana no hay nada bajo el cursor.
	get_window().mouse_exited.connect(_on_mouse_exited)


func _unhandled_input(event: InputEvent) -> void:
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
		_mouse_pos = mm.position
		_mouse_moved = true
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
	_update_hover()
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
	var best: Sphere = _sphere_at(screen_pos)
	if best != null:
		Selection.select(best)
	else:
		Selection.clear()


## Picking sin físicas: proyecta cada esfera al screen y devuelve la más cercana a
## `screen_pos` dentro de un umbral (escalado por su tamaño y el zoom), o null. La
## usan el clic (`_pick_at`) y el hover del halo (`_update_hover`).
func _sphere_at(screen_pos: Vector2) -> Sphere:
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
	return best


## Escribe `Selection.hovered` con la esfera bajo el cursor, solo si el ratón se movió.
## Una esfera muerta deja de estar en hover.
func _update_hover() -> void:
	if Selection.hovered != null and not is_instance_valid(Selection.hovered):
		Selection.hovered = null
	if not _mouse_moved:
		return
	_mouse_moved = false
	Selection.hovered = _sphere_at(_mouse_pos)


func _on_mouse_exited() -> void:
	_mouse_moved = false
	Selection.hovered = null


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
