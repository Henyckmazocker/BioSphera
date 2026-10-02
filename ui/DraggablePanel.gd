extends PanelContainer
## Panel movible por drag con el ratón (ventana flotante estilo SO).
##
## Usar como base para StatsPanel, SpeciesPanel, ParamsPanel, InspectPanel.

var _dragging := false
var _drag_offset := Vector2.ZERO

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_offset = get_global_mouse_position() - global_position
				mouse_filter = Control.MOUSE_FILTER_IGNORE
			else:
				_dragging = false
				mouse_filter = Control.MOUSE_FILTER_STOP
	elif event is InputEventMouseMotion and _dragging:
		global_position = get_global_mouse_position() - _drag_offset

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
