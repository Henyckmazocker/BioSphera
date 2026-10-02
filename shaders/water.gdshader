shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque, specular_schlick_ggx;

// Shader de agua estilizado para BioSphera (zen + minimalista).
// - La superficie es una malla PLANA generada por `World._build_water_surface`,
//   solo en las celdas del bioma de agua (coincide con el hueco del navmesh).
// - Toda la PROFUNDIDAD del agua se hornea por vértice en COLOR.r (0 en la orilla,
//   1 en lo más hondo): así no hace falta DEPTH_TEXTURE y el coste es mínimo.
// - El movimiento es solo de NORMALES (ripple animado con TIME); la geometría no se
//   desplaza, fiel a "sin oleaje pesado".
// - `daylight` (0 noche → 1 día) lo sube `World._on_day_advanced` para oscurecer el
//   agua de noche en sincronía con el cielo.
// Ver docs: docs/GDD/Mundo y Niveles.md y world/World.gd.

// Paleta coherente con Biomes.BIOME_COLOR[WATER] = (0.38, 0.62, 0.85).
uniform vec4 shallow_color : source_color = vec4(0.45, 0.78, 0.82, 1.0); // turquesa de orilla
uniform vec4 deep_color : source_color = vec4(0.12, 0.34, 0.62, 1.0);    // azul hondo
uniform vec4 foam_color : source_color = vec4(0.92, 0.97, 1.0, 1.0);     // espuma casi blanca
uniform vec4 night_tint : source_color = vec4(0.04, 0.07, 0.16, 1.0);    // tinte nocturno

// Orilla / espuma.
uniform float foam_width : hint_range(0.0, 0.5) = 0.14;   // ancho de la banda de espuma (en profundidad 0..1)
uniform float shore_softness : hint_range(0.01, 0.5) = 0.18; // suavizado del gradiente cerca de la orilla

// Ripple de normales.
uniform float wave_speed : hint_range(0.0, 2.0) = 0.35;
uniform float wave_scale : hint_range(0.5, 16.0) = 6.0;
uniform float wave_strength : hint_range(0.0, 1.0) = 0.18;

// Translucidez por profundidad.
uniform float alpha_shallow : hint_range(0.0, 1.0) = 0.45;
uniform float alpha_deep : hint_range(0.0, 1.0) = 0.92;

// Ciclo día/noche (lo modula World).
uniform float daylight : hint_range(0.0, 1.0) = 1.0;

// Profundidad horneada (COLOR.r) reexpuesta a fragment.
varying float v_depth;
varying vec2 v_uv;

void vertex() {
	v_depth = COLOR.r;
	v_uv = UV;
}

// Dos ondas senoidales cruzadas que se desplazan con el tiempo: barato y suave.
vec2 ripple_gradient(vec2 p, float t) {
	float a = sin(p.x * wave_scale + t) + sin((p.x + p.y) * wave_scale * 0.7 - t * 1.3);
	float b = cos(p.y * wave_scale - t * 1.1) + sin((p.x - p.y) * wave_scale * 0.9 + t * 0.8);
	return vec2(a, b);
}

void fragment() {
	float depth = clamp(v_depth, 0.0, 1.0);
	float t = TIME * wave_speed * TAU;

	// --- Ripple: inclinar la normal plana (+Y mundo) con el gradiente de las ondas ---
	vec2 grad = ripple_gradient(v_uv, t) * wave_strength;
	// Normal perturbada en MUNDO (superficie horizontal → eje vertical +Y) y luego a
	// espacio de vista (VIEW_MATRIX es ortonormal). Da un brillo del sol cambiante sin
	// mover vértices.
	vec3 n_world = normalize(vec3(grad.x, 1.0, grad.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// --- Color por profundidad (con orilla suave) ---
	float body = smoothstep(0.0, shore_softness + foam_width, depth);
	vec3 water = mix(shallow_color.rgb, deep_color.rgb, body);

	// --- Espuma fina pegada a la orilla, con leve temblor temporal ---
	float foam_edge = foam_width * (1.0 + 0.25 * sin(v_uv.x * 40.0 + t) * sin(v_uv.y * 40.0 - t));
	float foam = smoothstep(foam_edge, 0.0, depth);
	vec3 col = mix(water, foam_color.rgb, foam);

	// --- Día/noche: virar hacia el tinte nocturno cuando baja la luz ---
	col = mix(night_tint.rgb, col, clamp(daylight, 0.0, 1.0));

	ALBEDO = col;
	ROUGHNESS = mix(0.08, 0.22, depth); // orilla más espejada, hondo más mate
	METALLIC = 0.0;
	// La orilla translúcida deja ver el fondo azul del terreno; el hondo es más opaco.
	// La espuma sube algo de opacidad para leerse bien.
	ALPHA = clamp(mix(alpha_shallow, alpha_deep, depth) + foam * 0.3, 0.0, 1.0);
}
