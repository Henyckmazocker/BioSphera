class_name BiomeSystem
extends Node
## Sistema de biomas procedurales (autoload `Biomes`).
##
## Divide el plano en 5 biomas según dos capas de ruido:
## - `humidity` (Perlin escala A)
## - `temperature` (Perlin escala B, semilla distinta)
##
## La combinación define el bioma en cada punto (x,z). Los biomas
## modifican rasgos vivos (metabolismo, visión, crecimiento de plantas)
## y el agua actúa como barrera de movimiento.
##
## Ver docs: docs/GDD/Mundo y Niveles.md.

enum Biome { PLAIN, FOREST, DESERT, WATER, COLD }

const BIOME_KEYS: Array[StringName] = [&"plain", &"forest", &"desert", &"water", &"cold"]

const BIOME_COLOR: Dictionary = {
	Biome.PLAIN:  Color(0.78, 0.86, 0.55),   # verde claro
	Biome.FOREST: Color(0.32, 0.55, 0.30),   # verde oscuro
	Biome.DESERT: Color(0.92, 0.84, 0.55),   # ocre
	Biome.WATER:  Color(0.38, 0.62, 0.85),   # azul
	Biome.COLD:   Color(0.85, 0.90, 0.95),   # blanco azulado
}

## Paleta del terreno por estación (0=primavera 1=verano 2=otoño 3=invierno, como
## `Climate.season_index`). Primavera ES `BIOME_COLOR`: hasta el primer cambio de estación
## el terreno se ve igual que antes. La aplica `World` con `shaders/terrain.gdshader`;
## los colores van crudos, como el COLOR horneado (ver el shader). Sutil, estilo Mini Metro:
## verano algo más cálido y saturado, otoño con bosque ocre y llanura pajiza, invierno
## blanqueado y frío con el agua más gris.
## Ver docs: plan «Game Feel y Efectos Juicy», M5.
const SEASON_BIOME_COLOR: Array = [
	BIOME_COLOR,
	{   # verano
		Biome.PLAIN:  Color(0.80, 0.85, 0.45),
		Biome.FOREST: Color(0.26, 0.50, 0.21),
		Biome.DESERT: Color(0.95, 0.81, 0.47),
		Biome.WATER:  Color(0.33, 0.61, 0.87),
		Biome.COLD:   Color(0.86, 0.90, 0.93),
	},
	{   # otoño
		Biome.PLAIN:  Color(0.86, 0.80, 0.52),
		Biome.FOREST: Color(0.66, 0.50, 0.24),
		Biome.DESERT: Color(0.90, 0.77, 0.52),
		Biome.WATER:  Color(0.36, 0.56, 0.74),
		Biome.COLD:   Color(0.84, 0.86, 0.88),
	},
	{   # invierno
		Biome.PLAIN:  Color(0.80, 0.86, 0.82),
		Biome.FOREST: Color(0.48, 0.58, 0.55),
		Biome.DESERT: Color(0.86, 0.82, 0.73),
		Biome.WATER:  Color(0.50, 0.60, 0.68),
		Biome.COLD:   Color(0.94, 0.96, 0.99),
	},
]

## Tinte que multiplica la luz del sol por estación (mismo índice). Muy suave (±10–15 %):
## primavera neutra, verano cálido, otoño dorado, invierno frío.
const SEASON_LIGHT_TINT: Array[Color] = [
	Color(1.0, 1.0, 1.0),
	Color(1.0, 0.96, 0.88),
	Color(1.0, 0.91, 0.80),
	Color(0.87, 0.93, 1.0),
]

## Modificadores por bioma. Multiplican el rasgo correspondiente.
## metabolism_mod: multiplica la quema de energía por tick.
## vision_mod: multiplica el rango de visión efectivo.
## speed_mod: multiplica la velocidad de movimiento.
## plant_growth_mod: multiplica la tasa de crecimiento de plantas.
## mutation_mod: hostilidad 0..1 del bioma de nacimiento para la mutación (la pesa
##   GlobalParams.mutation_biome_factor). Columna propia, no derivada de plant_growth_mod,
##   para tunearla sin acoplarla al crecimiento vegetal. Debe estar en TODOS los biomas:
##   get_mod devuelve 1.0 si falta la clave.
## walkable: si false, las esferas no pueden entrar (barrera).
const BIOME_EFFECTS: Dictionary = {
	Biome.PLAIN:  {"metabolism_mod": 1.0, "vision_mod": 1.0, "speed_mod": 1.0, "plant_growth_mod": 1.0, "mutation_mod": 0.0, "walkable": true},
	Biome.FOREST: {"metabolism_mod": 0.9, "vision_mod": 0.6, "speed_mod": 0.9, "plant_growth_mod": 1.3, "mutation_mod": 0.0, "walkable": true},
	Biome.DESERT: {"metabolism_mod": 1.5, "vision_mod": 1.1, "speed_mod": 1.0, "plant_growth_mod": 0.3, "mutation_mod": 1.0, "walkable": true},
	Biome.WATER:  {"metabolism_mod": 1.0, "vision_mod": 1.0, "speed_mod": 0.0, "plant_growth_mod": 0.0, "mutation_mod": 0.0, "walkable": false},
	Biome.COLD:   {"metabolism_mod": 0.7, "vision_mod": 0.9, "speed_mod": 0.7, "plant_growth_mod": 0.6, "mutation_mod": 0.7, "walkable": true},
}

# Tamaño de bioma RELATIVO al mapa: nº de periodos de ruido a lo ancho del mundo.
# La frecuencia se deriva en `_rebuild_noise` como `periodos / world_size`, así los
# biomas escalan con el mapa (mismo nº de parches a cualquier tamaño) en lugar de
# fragmentarse al agrandarlo. Pocos periodos = parches grandes y bien definidos.
const HUMIDITY_PERIODS: float = 1.6
const TEMP_PERIODS: float = 1.1
## Centro de la banda de transición visual del agua. La malla del terreno
## se hunde con un smoothstep en `[WATER_HUMIDITY_MIN ± WATER_VISUAL_BAND]`
## (ver `World._generate_biomes`).
const WATER_HUMIDITY_MIN: float = 0.55
## Semi-anchura de la transición visual. Definido aquí (no en World) para
## que la clasificación de bioma y la deformación visual queden alineadas:
## un punto solo es "tierra walkable" si su Y NO está hundida por el agua.
const WATER_VISUAL_BAND: float = 0.12
const COLD_THRESHOLD: float = -0.15
const DESERT_THRESHOLD: float = 0.35
const FOREST_THRESHOLD: float = 0.25

var world_bounds: Vector2 = Vector2(60.0, 60.0)
var seed_value: int = 0
var is_generated: bool = false
var _humidity_noise: FastNoiseLite
var _temperature_noise: FastNoiseLite

# Grid de walkability precalculado a la misma resolución que la malla visual.
# Garantiza que is_walkable_at coincide exactamente con lo que el jugador ve.
var _walkability_grid: Array = []   # [row][col] -> bool
# Grid de bioma precalculado a la MISMA resolución y en el MISMO bake que el de
# walkability. Evita muestrear los dos ruidos Perlin (FastNoiseLite) en cada
# `biome_at`: con cientos de esferas llamándolo ~2 veces por tick, el muestreo
# de ruido fractal era el grueso del coste de script (ver profiler, 2026-06-08).
# El lookup es O(1) por vecino-más-cercano, idéntico patrón que `is_walkable_at`.
var _biome_grid: Array = []         # [row][col] -> int (Biome)
var _wgrid_cols: int = 0
var _wgrid_rows: int = 0


func _ready() -> void:
	_rebuild_noise(randi())


func generate(bounds: Vector2, new_seed: int = -1) -> void:
	world_bounds = bounds
	if new_seed < 0:
		new_seed = randi()
	_rebuild_noise(new_seed)
	is_generated = true


func _rebuild_noise(s: int) -> void:
	seed_value = s
	# Frecuencia derivada del tamaño del mapa (ver HUMIDITY_PERIODS/TEMP_PERIODS).
	# OJO con el orden: `_ready()` llama aquí con `world_bounds` provisional (60 por
	# defecto), pero `generate(bounds, seed)` —que el Spawner invoca al cargar la
	# escena— fija `world_bounds = bounds` ANTES de este `_rebuild_noise`, así que
	# esa construcción inicial siempre queda superseded antes de cualquier muestreo.
	var size: float = maxf(world_bounds.x, 1.0)
	# Un solo octavo: biomas contiguos y bordes limpios (el 2.º octavo añadía motas
	# de alta frecuencia que fragmentaban los parches y generaban píxeles de agua
	# aislados). A menor frecuencia las transiciones ya se suavizan solas en mundo.
	_humidity_noise = FastNoiseLite.new()
	_humidity_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_humidity_noise.seed = s
	_humidity_noise.frequency = HUMIDITY_PERIODS / size
	_humidity_noise.fractal_octaves = 1

	_temperature_noise = FastNoiseLite.new()
	_temperature_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_temperature_noise.seed = s + 7919
	_temperature_noise.frequency = TEMP_PERIODS / size
	_temperature_noise.fractal_octaves = 1

	# El bioma cacheado pertenece a la semilla anterior: invalidarlo para que
	# `biome_at` vuelva al muestreo en vivo hasta el próximo `bake_walkability_grid`.
	_biome_grid.clear()


func biome_at(pos: Vector3) -> int:
	# Tras el bake, lookup O(1) en el grid (sin muestrear ruido). Antes del bake
	# (o tras rebakear semilla), muestreo en vivo. Mismo valor que `biome_at_xz`
	# en el vértice de malla más próximo: idéntico a lo que ya hace walkability.
	if not _biome_grid.is_empty():
		var rc: Vector2i = _grid_rc(pos.x, pos.z)
		return _biome_grid[rc.x][rc.y]
	return biome_at_xz(pos.x, pos.z)


func biome_at_xz(x: float, z: float) -> int:
	if _humidity_noise == null:
		return Biome.PLAIN
	var h: float = _humidity_noise.get_noise_2d(x, z)
	var t: float = _temperature_noise.get_noise_2d(x, z)
	# Lagos / agua: clasificamos como WATER ya desde el inicio de la depresión
	# visual (no desde el centro). Si se clasificara en `WATER_HUMIDITY_MIN`,
	# habría vértices "tierra" con Y hundida (smoothstep > 0) → la esfera
	# parecería andar sobre el agua y el navmesh asomaría sobre la depresión.
	if h > WATER_HUMIDITY_MIN - WATER_VISUAL_BAND:
		return Biome.WATER
	# Zona fría: temperatura muy baja.
	if t < COLD_THRESHOLD:
		return Biome.COLD
	# Desierto: temperatura alta y humedad baja.
	if t > DESERT_THRESHOLD and h < 0.0:
		return Biome.DESERT
	# Bosque: humedad media-alta.
	if h > FOREST_THRESHOLD:
		return Biome.FOREST
	return Biome.PLAIN


func get_color(biome: int) -> Color:
	return BIOME_COLOR.get(biome, Color.WHITE)


func get_mod(biome: int, key: String) -> float:
	var d: Dictionary = BIOME_EFFECTS.get(biome, {})
	return float(d.get(key, 1.0))


func is_walkable(biome: int) -> bool:
	var d: Dictionary = BIOME_EFFECTS.get(biome, {})
	return bool(d.get("walkable", true))


## Precalcula el grid de walkability a la resolución exacta de la malla.
## Llamar desde World justo después de generar la geometría.
func bake_walkability_grid(cols: int, rows: int) -> void:
	_wgrid_cols = cols
	_wgrid_rows = rows
	_walkability_grid.clear()
	_biome_grid.clear()
	var half_x: float = world_bounds.x * 0.5
	var half_z: float = world_bounds.y * 0.5
	# Paso 1: grid crudo del ruido. Aprovechamos el mismo muestreo para cachear el
	# bioma por celda (`_biome_grid`), clasificación CRUDA (pre-erosión): es
	# exactamente lo que devolvía `biome_at` en vivo. La erosión de abajo solo
	# corrige walkability (píxeles de agua aislados), no la clasificación de bioma.
	for r in rows:
		var row: Array = []
		var biome_row: Array = []
		var fz: float = lerpf(-half_z, half_z, float(r) / float(rows - 1))
		for c in cols:
			var fx: float = lerpf(-half_x, half_x, float(c) / float(cols - 1))
			var b: int = biome_at_xz(fx, fz)
			biome_row.append(b)
			row.append(is_walkable(b))
		_walkability_grid.append(row)
		_biome_grid.append(biome_row)
	# Paso 2: erosión — una celda solo es inalcanzable si ≥2 vecinos cardinales
	# también lo son. Elimina píxeles de agua aislados que el ruido fractal genera
	# pero que son invisibles con filtro lineal en la textura.
	var eroded: Array = []
	for r in rows:
		var row: Array = []
		for c in cols:
			if _walkability_grid[r][c]:
				row.append(true)
			else:
				var blocked_neighbors: int = 0
				if r > 0        and not _walkability_grid[r - 1][c]: blocked_neighbors += 1
				if r < rows - 1 and not _walkability_grid[r + 1][c]: blocked_neighbors += 1
				if c > 0        and not _walkability_grid[r][c - 1]: blocked_neighbors += 1
				if c < cols - 1 and not _walkability_grid[r][c + 1]: blocked_neighbors += 1
				row.append(blocked_neighbors < 2)
		eroded.append(row)
	_walkability_grid = eroded


func is_walkable_at(pos: Vector3) -> bool:
	if _walkability_grid.is_empty():
		return is_walkable(biome_at(pos))
	var rc: Vector2i = _grid_rc(pos.x, pos.z)
	return _walkability_grid[rc.x][rc.y]


## Mapea una posición de mundo (x,z) a la celda del grid por vecino más cercano,
## igual que el vértice de malla más próximo. Devuelve `Vector2i(fila, columna)`:
## `.x` = fila (de z), `.y` = columna (de x) — para indexar `grid[fila][col]`.
## Lo comparten `is_walkable_at` y `biome_at` (mismos `_wgrid_cols/_wgrid_rows`).
func _grid_rc(wx: float, wz: float) -> Vector2i:
	var u: float = (wx + world_bounds.x * 0.5) / world_bounds.x * float(_wgrid_cols - 1)
	var v: float = (wz + world_bounds.y * 0.5) / world_bounds.y * float(_wgrid_rows - 1)
	var c: int = clampi(roundi(u), 0, _wgrid_cols - 1)
	var r: int = clampi(roundi(v), 0, _wgrid_rows - 1)
	return Vector2i(r, c)


## Genera una `ImageTexture` con el mapa de biomas para pintar el suelo.
## `resolution` es el lado del cuadrado en píxeles.
func build_color_texture(resolution: int = 256) -> ImageTexture:
	var img: Image = Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
	var half_x: float = world_bounds.x * 0.5
	var half_z: float = world_bounds.y * 0.5
	for py in resolution:
		for px in resolution:
			var u: float = float(px) / float(resolution - 1)
			var v: float = float(py) / float(resolution - 1)
			var wx: float = lerpf(-half_x, half_x, u)
			var wz: float = lerpf(-half_z, half_z, v)
			var b: int = biome_at_xz(wx, wz)
			img.set_pixel(px, py, get_color(b))
	return ImageTexture.create_from_image(img)
