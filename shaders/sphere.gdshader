shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert_wrap, specular_disabled;

// Shader esférico minimalista para BioSphera.
// - El color heredable HSV llega por instancia vía MultiMesh (`use_colors`):
//   se lee del built-in COLOR. EntityRenderer lo sube ya en espacio LINEAL
//   (Color.srgb_to_linear), replicando lo que hacía el antiguo uniform
//   `base_color : source_color`.
// - `emission_strength` sube cuando la esfera está en un estado fuerte
//   (en combate, en celo, recién nacida...). Hoy es global y vale 0.
// - `rim_strength` da un halo sutil que mejora la lectura sobre el plano.

uniform float emission_strength : hint_range(0.0, 4.0) = 0.0;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.6;
uniform float rim_power : hint_range(0.5, 8.0) = 2.5;

// COLOR es un built-in de la etapa de vértice; se reexpone a fragment.
varying vec3 v_color;

void vertex() {
	v_color = COLOR.rgb;
}

void fragment() {
	ALBEDO = v_color;
	ROUGHNESS = 0.55;
	METALLIC = 0.0;

	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	EMISSION = v_color * (emission_strength + rim * rim_strength);
}
