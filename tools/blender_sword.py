# -*- coding: utf-8 -*-
"""Espada estática (sin armature). Reutiliza piezas de blender_humanoid_lib.

Genera assets/models/sword.glb. Origen en la empuñadura (z=0) para poder
acoplarla a la mano de un humanoide más adelante.

Uso (headless):
    blender -b -P tools/blender_sword.py
    blender -b -P tools/blender_sword.py -- /ruta/custom/sword.glb
"""

import os
import sys

# Permite importar la librería esté donde esté el CWD al lanzar Blender.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import blender_humanoid_lib as lib  # noqa: E402


# Reutilizamos las claves de zona del atlas para la paleta de la espada.
PALETTE = {
    "accent": (0.62, 0.64, 0.68),  # hoja: acero
    "boots":  (0.28, 0.18, 0.10),  # empuñadura: cuero
    "hair":   (0.78, 0.62, 0.22),  # guarda y pomo: dorado
    # zonas no usadas, color neutro
    "skin":   (0.5, 0.5, 0.5),
    "cloth":  (0.5, 0.5, 0.5),
    "pants":  (0.5, 0.5, 0.5),
}


def main():
    lib.clear_scene()

    mb = lib.MeshBuilder()
    # (centro, tamaño, zona) — la espada se alza a lo largo de +Z.
    mb.add_box((0, 0, -0.11), (0.06, 0.06, 0.06), "hair")   # pomo (dorado)
    mb.add_box((0, 0, 0.00),  (0.045, 0.045, 0.18), "boots")  # empuñadura (cuero)
    mb.add_box((0, 0, 0.10),  (0.24, 0.05, 0.04), "hair")   # guarda (dorado)
    mb.add_box((0, 0, 0.55),  (0.06, 0.02, 0.82), "accent")  # hoja (acero)
    mb.add_box((0, 0, 0.99),  (0.025, 0.02, 0.12), "accent")  # punta

    image = lib.make_atlas_image("Sword_atlas", PALETTE, seed=3)
    material = lib.make_textured_material("Sword_mat", image, metallic=0.7, roughness=0.35)
    mb.build("Sword", material, smooth=False)  # bordes crispados, look metálico

    out = lib.resolve_output_path(os.path.join("assets", "models", "sword.glb"))
    lib.export_glb(out)


if __name__ == "__main__":
    main()
