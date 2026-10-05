shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled, fog_disabled;

// Halo de estado (plan «Game Feel y Efectos Juicy», M6): contorno por casco invertido.
// Se pone como `material_overlay` de las mallas del modelo (`EntityModel.set_halo`):
// la malla se vuelve a dibujar hinchada sobre la normal y solo con las caras traseras,
// así que lo que asoma alrededor del cuerpo es un borde de color plano.
// - `vertex()` corre tras el skinning: el casco sigue a la animación.
// - `grow` va en espacio de modelo, así que crece con la escala del modelo
//   (`_t_visual_scale`, `fx_squash`); es aceptable.
// - Cuatro materiales compartidos (uno por estado), ninguno por instancia.
// Ver docs: docs/GDD/Arte y Estética.md (halo de estado).

uniform vec3 halo_color : source_color = vec3(1.0);
uniform float grow = 0.03;

void vertex() {
	VERTEX += NORMAL * grow;
}

void fragment() {
	ALBEDO = halo_color;
}
