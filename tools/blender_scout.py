# -*- coding: utf-8 -*-
"""Humanoide 2: "explorador" — esbelto y alto, paleta verde/cuero.

Genera assets/models/scout.glb con animaciones idle/walk/attack y textura.

Uso (headless):
    blender -b -P tools/blender_scout.py
    blender -b -P tools/blender_scout.py -- /ruta/custom/scout.glb
"""

import os
import sys

# Permite importar la librería esté donde esté el CWD al lanzar Blender.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import blender_humanoid_lib as lib  # noqa: E402


# Proporciones esbeltas: más estrecho, algo más alto, cabeza pequeña.
PARAMS = {
    "width_mul": 0.88,
    "height_mul": 1.06,
    "head_mul": 0.95,
}

# Paleta verde/cuero.
PALETTE = {
    "skin":   (0.86, 0.70, 0.58),
    "cloth":  (0.20, 0.38, 0.22),  # verde bosque
    "pants":  (0.34, 0.26, 0.16),  # cuero
    "boots":  (0.22, 0.16, 0.10),
    "hair":   (0.55, 0.40, 0.12),  # rubio oscuro
    "accent": (0.72, 0.58, 0.20),  # dorado
}


def main():
    lib.clear_scene()
    lib.build_humanoid("Scout", PARAMS, PALETTE, seed=2)
    out = lib.resolve_output_path(os.path.join("assets", "models", "scout.glb"))
    lib.export_glb(out)


if __name__ == "__main__":
    main()
