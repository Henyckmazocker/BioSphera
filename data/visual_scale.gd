class_name VisualScale
extends RefCounted
## Fuente ÚNICA de escala VISUAL del juego, en unidades de terreno.
##
## Regla de diseño (decisión cerrada, ver docs/GDD/Mundo y Niveles.md):
## - Escala ABSOLUTA y fija: un elemento mide lo mismo en cualquier mundo
##   (60–160 u); la cámara hace el zoom. No escala con `world_size`.
## - Lo VISUAL está desacoplado del GAMEPLAY: el rasgo `size` del genoma
##   (Traits.SIZE_MIN..SIZE_MAX) sigue alimentando combate/metabolismo/visión sin
##   cambios. Aquí solo se decide cómo de grande se DIBUJA cada cosa, mapeando el
##   `size` a una banda de altura estrecha para evitar enanos/gigantes.
##
## Jerarquía objetivo: planta/roca < entidad < nido (huella) < granja (huella) < árbol.
## Para retocar tamaños tras verlos en marcha, tocar SOLO este archivo.

const TraitsScript := preload("res://data/traits.gd")

# --- Entidades (esferas) ---
# El `size` del genoma [SIZE_MIN, SIZE_MAX] se mapea linealmente a esta banda de
# altura visual (en unidades de terreno). Con size=1.0 da ~1.0 u (entidad media).
const ENTITY_HEIGHT_MIN: float = 0.8
const ENTITY_HEIGHT_MAX: float = 1.8

# Altura nativa (AABB del mesh) de cada modelo .glb. Sirve para normalizar: dos
# especies con el mismo `size` deben dibujarse a la MISMA altura aunque sus .glb
# midan distinto de fábrica. Tunable si el import de Godot difiere del AABB medido.
const MODEL_NATIVE_HEIGHT_WARRIOR: float = 1.855   # especie A
const MODEL_NATIVE_HEIGHT_SCOUT: float = 2.0       # especie B

# --- Recursos / edificios ---
const TREE_HEIGHT: float = 3.2          # árbol maduro: más alto que cualquier entidad
const TREE_TOP_RADIUS: float = 0.48
const TREE_BOTTOM_RADIUS: float = 0.58
const PLANT_HEIGHT: float = 0.45
const STONE_HEIGHT: float = 0.6
const GOLD_HEIGHT: float = 0.6

# Granja: hito con huella claramente mayor que una entidad. Se calcula la escala
# uniforme del .glb a partir de su huella nativa.
const FARM_FOOTPRINT: float = 3.0
const FARM_NATIVE_FOOTPRINT: float = 1.78

# Nido: domo bajo del clan, entre la entidad y la granja. Misma normalización por
# huella nativa (diámetro de la base del .glb de `tools/blender_nest.py`).
const NEST_FOOTPRINT: float = 2.0
const NEST_NATIVE_FOOTPRINT: float = 2.0


## Altura visual (u de terreno) para un `size` de genoma dado. Lineal en la banda.
static func entity_height(size: float) -> float:
	var lo: float = TraitsScript.SIZE_MIN
	var hi: float = TraitsScript.SIZE_MAX
	var t: float = clampf((size - lo) / (hi - lo), 0.0, 1.0)
	return lerpf(ENTITY_HEIGHT_MIN, ENTITY_HEIGHT_MAX, t)


## Escala uniforme a aplicar al modelo .glb (de altura nativa `native_height`)
## para que su altura final sea `entity_height(size)`.
static func entity_model_scale(size: float, native_height: float) -> float:
	if native_height <= 0.0:
		return 1.0
	return entity_height(size) / native_height


## Escala uniforme del .glb de la granja para alcanzar la huella objetivo.
static func farm_scale() -> float:
	return FARM_FOOTPRINT / FARM_NATIVE_FOOTPRINT


## Escala uniforme del .glb del nido para alcanzar la huella objetivo.
static func nest_scale() -> float:
	return NEST_FOOTPRINT / NEST_NATIVE_FOOTPRINT
