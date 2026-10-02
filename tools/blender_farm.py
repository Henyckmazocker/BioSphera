# -*- coding: utf-8 -*-
"""Granja como MOLINO estilo Age of Empires 2.

Edificio: cuerpo de madera + tejado de paja a cuatro aguas + aspas de molino en X
al frente. NO es la parcela de cultivo. Reutiliza piezas de blender_humanoid_lib.

Origen en la base (Z=0) para que descanse a ras de suelo. ~2 m de alto.

Uso (headless):
    blender -b -P tools/blender_farm.py
    blender -b -P tools/blender_farm.py -- /ruta/custom/farm.glb
"""

import os
import sys
import math

# Permite importar la librería esté donde esté el CWD al lanzar Blender.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import blender_humanoid_lib as lib  # noqa: E402


# Paleta del molino (reutiliza las claves de zona del atlas).
PALETTE = {
    "boots":  (0.50, 0.36, 0.22),  # paredes de madera
    "hair":   (0.74, 0.60, 0.30),  # tejado de paja
    "skin":   (0.85, 0.82, 0.72),  # velas/lienzo de las aspas
    "accent": (0.32, 0.22, 0.12),  # buje y madera oscura
    "pants":  (0.28, 0.18, 0.10),  # puerta
    "cloth":  (0.5, 0.5, 0.5),     # no se usa
}


def add_pyramid(mb, cx, cy, cz, base, height, zone):
    """Tejado a cuatro aguas (pirámide de base cuadrada). Anexa a las listas del
    MeshBuilder: 4 esquinas de base + ápice → 4 caras triangulares + base cuadrada."""
    h = base * 0.5
    u0, v0, u1, v1 = lib.ZONES[zone]
    u0 += lib.UV_INSET; v0 += lib.UV_INSET; u1 -= lib.UV_INSET; v1 -= lib.UV_INSET
    b = len(mb.verts)
    mb.verts.append((cx - h, cy - h, cz))  # b+0
    mb.verts.append((cx + h, cy - h, cz))  # b+1
    mb.verts.append((cx + h, cy + h, cz))  # b+2
    mb.verts.append((cx - h, cy + h, cz))  # b+3
    mb.verts.append((cx, cy, cz + height))  # b+4 ápice
    # Caras laterales (CCW vistas desde fuera) → 3 pares de UV cada una.
    tri_uv = [(u0, v0), (u1, v0), ((u0 + u1) * 0.5, v1)]
    for a, c in [(b, b + 1), (b + 1, b + 2), (b + 2, b + 3), (b + 3, b)]:
        mb.faces.append((a, c, b + 4))
        for uu, vv in tri_uv:
            mb.uvs.extend((uu, vv))
    # Base (mirando hacia abajo) → 4 pares de UV.
    mb.faces.append((b + 3, b + 2, b + 1, b))
    for uu, vv in [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]:
        mb.uvs.extend((uu, vv))


def main():
    lib.clear_scene()
    mb = lib.MeshBuilder()

    # --- Cuerpo (paredes de madera) ---
    mb.add_box((0.0, 0.0, 0.70), (1.5, 1.5, 1.40), "boots")

    # --- Puerta (cara frontal -Y, parte baja) ---
    mb.add_box((0.0, -0.78, 0.45), (0.5, 0.12, 0.9), "pants")

    # --- Tejado de paja a cuatro aguas (sobre las paredes, con voladizo) ---
    add_pyramid(mb, 0.0, 0.0, 1.40, 1.7, 0.7, "hair")

    # --- Aspas del molino (cara frontal -Y, arriba) ---
    # Eje/buje saliente.
    mb.add_box((0.0, -0.82, 1.15), (0.18, 0.22, 0.18), "accent")
    # Dos barras cruzadas a ±45° → cruz de 4 brazos. Finas en Y (pegadas al frente),
    # largas en Z; al girar sobre el eje Y quedan en aspa en el plano X-Z.
    mb.add_box((0.0, -0.90, 1.15), (0.14, 0.05, 1.7), "skin", rot_y=math.radians(45.0))
    mb.add_box((0.0, -0.90, 1.15), (0.14, 0.05, 1.7), "skin", rot_y=math.radians(-45.0))

    image = lib.make_atlas_image("Farm_atlas", PALETTE, seed=4)
    material = lib.make_textured_material("Farm_mat", image, metallic=0.0, roughness=0.85)
    mb.build("Farm", material, smooth=False)  # bordes crispados

    out = lib.resolve_output_path(os.path.join("assets", "models", "farm.glb"))
    lib.export_glb(out)


if __name__ == "__main__":
    main()
