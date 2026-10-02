# -*- coding: utf-8 -*-
"""Humanoide 1: "guerrero" — corpulento, paleta terrosa.

Genera assets/models/warrior.glb con animaciones idle/walk/attack y textura.

Uso (headless):
    blender -b -P tools/blender_warrior.py
    blender -b -P tools/blender_warrior.py -- /ruta/custom/warrior.glb
"""

import os
import sys

# Permite importar la librería esté donde esté el CWD al lanzar Blender.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import blender_humanoid_lib as lib  # noqa: E402


# Proporciones corpulentas: más ancho, algo más bajo, cabeza grande.
PARAMS = {
    "width_mul": 1.15,
    "height_mul": 0.98,
    "head_mul": 1.05,
}

# Paleta terrosa.
PALETTE = {
    "skin":   (0.80, 0.62, 0.47),
    "cloth":  (0.45, 0.12, 0.10),  # rojo oscuro
    "pants":  (0.20, 0.18, 0.16),
    "boots":  (0.12, 0.10, 0.09),
    "hair":   (0.15, 0.10, 0.06),  # castaño oscuro
    "accent": (0.55, 0.55, 0.58),  # acero
}


def main():
    lib.clear_scene()
    lib.build_humanoid("Warrior", PARAMS, PALETTE, seed=1)
    out = lib.resolve_output_path(os.path.join("assets", "models", "warrior.glb"))
    lib.export_glb(out)


if __name__ == "__main__":
    main()
