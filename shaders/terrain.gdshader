shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Terreno con paleta por estación (plan «Game Feel y Efectos Juicy», M5).
// - `World._generate_biomes` hornea por vértice los pesos de bioma en CUSTOM0:
//   (forest_w, desert_w·dry_w, cold_w·dry_w, water_w). Aquí se rehace el mismo
//   encadenado de mezclas que hornea el COLOR: PLAIN → FOREST → DESERT → COLD → WATER.
// - Las paletas (índices = enum BiomeSystem.Biome: PLAIN, FOREST, DESERT, WATER, COLD)
//   las pone `World`: `palette_from` → `palette_to` con `blend` 0..1 (fundido de 3 s).
// - Replica el StandardMaterial3D anterior (albedo = COLOR crudo, sin conversión sRGB,
//   rugosidad 0,95, metálico 0, especular 0,5): por eso las paletas NO llevan
//   `source_color`, igual que el COLOR horneado con `vertex_color_is_srgb = false`.
//   Con la paleta de primavera el terreno se ve como antes de M5.
// Ver docs: docs/GDD/Arte y Estética.md y world/World.gd.

uniform vec4 palette_from[5];
uniform vec4 palette_to[5];
uniform float blend : hint_range(0.0, 1.0) = 1.0;

varying vec3 v_albedo;

vec3 pal(int i) {
	return mix(palette_from[i].rgb, palette_to[i].rgb, blend);
}

void vertex() {
	// Mezcla por vértice (como el COLOR horneado) e interpolada por el rasterizador.
	vec3 c = pal(0);                    // PLAIN
	c = mix(c, pal(1), CUSTOM0.x);      // FOREST · forest_w
	c = mix(c, pal(2), CUSTOM0.y);      // DESERT · desert_w·dry_w
	c = mix(c, pal(4), CUSTOM0.z);      // COLD   · cold_w·dry_w
	c = mix(c, pal(3), CUSTOM0.w);      // WATER  · water_w
	v_albedo = c;
}

void fragment() {
	ALBEDO = v_albedo;
	METALLIC = 0.0;
	ROUGHNESS = 0.95;
	SPECULAR = 0.5;
}
