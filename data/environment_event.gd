class_name EnvironmentEvent
extends Resource
## Evento global del entorno (sequía, ola de frío, tormenta, abundancia, plaga).
##
## Un `.tres` por evento en `data/events/`, editable en el inspector (mismo molde
## que `SimPreset`). No tiene lógica: `Climate.start_event` lo lee y compone sus
## multiplicadores con los estacionales. Ningún otro sistema sabe qué evento hay:
## consultan funciones de `Climate` (`pollination_modifier`, `plant_wilt_modifier`…).
##
## Los multiplicadores están dados A INTENSIDAD 1; el efectivo es
## `lerp(1.0, mult, intensity × ramp_01)`, con `ramp_01` trapezoidal (ver `Climate`).
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Eventos del entorno").

enum Kind { DROUGHT, COLD_WAVE, STORM, ABUNDANCE, PLAGUE }

@export var kind: Kind = Kind.DROUGHT
@export var display_name: String = ""
## Intensidad por defecto si `start_event` no recibe otra.
@export_range(0.0, 1.0, 0.05) var intensity: float = 0.5
@export_range(1.0, 60.0, 0.5) var duration_days: float = 10.0
## Días de rampa de entrada y, otra vez, de salida (dentro de `duration_days`).
@export_range(0.0, 10.0, 0.5) var ramp_days: float = 2.0

# --- Multiplicadores a intensidad 1 (1.0 = neutro) ---
@export var pollination_mult: float = 1.0
## ≥1 acelera la marchitez de las plantas maduras.
@export var wilt_mult: float = 1.0
@export var metabolism_mult: float = 1.0
@export var speed_mult: float = 1.0
@export var vision_mult: float = 1.0
## Se suma a la presión estacional de `Climate.mutation_pressure()`.
@export_range(0.0, 1.0, 0.05) var mutation_pressure: float = 0.0
