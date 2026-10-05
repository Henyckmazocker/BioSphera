# -*- coding: utf-8 -*-
"""Nido del clan: domo bajo de paja con ramas, entrada y una franja teñible.

Dos mallas:
  - "Nest": domo de paja + ramas cruzadas + entrada oscura (atlas, como la granja).
  - "NestTint": franja alrededor de la base y banderín en la cima, con material
    propio liso y blanco ("Nest_tint"). `world/NestLayer.gd` lo duplica y le pone
    el color del clan como albedo (blanco × color = color del clan).

Origen en la base (Z=0) para que descanse a ras de suelo. Huella nativa: 2.0 m de
diámetro (`VisualScale.NEST_NATIVE_FOOTPRINT`). Reutiliza blender_humanoid_lib.

Uso (headless):
    blender -b -P tools/blender_nest.py
    blender -b -P tools/blender_nest.py -- /ruta/custom/nest.glb
"""

import os
import sys
import math

import bpy

# Permite importar la librería esté donde esté el CWD al lanzar Blender.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import blender_humanoid_lib as lib  # noqa: E402


# Paleta del nido (reutiliza las claves de zona del atlas).
PALETTE = {
    "hair":   (0.78, 0.64, 0.34),  # paja del domo
    "boots":  (0.42, 0.29, 0.16),  # ramas
    "pants":  (0.12, 0.08, 0.05),  # hueco de la entrada
    "accent": (0.30, 0.20, 0.11),  # mástil del banderín
    "skin":   (0.5, 0.5, 0.5),     # no se usa
    "cloth":  (0.5, 0.5, 0.5),     # no se usa
}

RADIUS = 1.0        # radio de la base (huella 2.0)
HEIGHT = 0.7        # domo bajo: más ancho que alto
SEGMENTS = 14       # meridianos
RINGS = 5           # paralelos (sin contar el polo)


def _zone_uv(zone):
    u0, v0, u1, v1 = lib.ZONES[zone]
    return (u0 + lib.UV_INSET, v0 + lib.UV_INSET, u1 - lib.UV_INSET, v1 - lib.UV_INSET)


def _dome_point(ring, seg, radius=RADIUS, height=HEIGHT):
    """Punto del domo (elipsoide achatado). `ring` 0 = base, RINGS = polo."""
    phi = (math.pi * 0.5) * ring / RINGS
    theta = 2.0 * math.pi * seg / SEGMENTS
    r = radius * math.cos(phi)
    return (r * math.cos(theta), r * math.sin(theta), height * math.sin(phi))


def _ring_radius(z):
    """Radio del domo a la altura `z`."""
    return RADIUS * math.sqrt(max(0.0, 1.0 - (z / HEIGHT) ** 2))


def add_dome(mb, zone):
    """Domo de paja: anillos de quads y un abanico de triángulos en el polo."""
    u0, v0, u1, v1 = _zone_uv(zone)
    quad_uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
    for ring in range(RINGS - 1):
        for seg in range(SEGMENTS):
            b = len(mb.verts)
            mb.verts.append(_dome_point(ring, seg))
            mb.verts.append(_dome_point(ring, seg + 1))
            mb.verts.append(_dome_point(ring + 1, seg + 1))
            mb.verts.append(_dome_point(ring + 1, seg))
            mb.faces.append((b, b + 1, b + 2, b + 3))
            for uu, vv in quad_uv:
                mb.uvs.extend((uu, vv))
    pole = (0.0, 0.0, HEIGHT)
    tri_uv = [(u0, v0), (u1, v0), ((u0 + u1) * 0.5, v1)]
    for seg in range(SEGMENTS):
        b = len(mb.verts)
        mb.verts.append(_dome_point(RINGS - 1, seg))
        mb.verts.append(_dome_point(RINGS - 1, seg + 1))
        mb.verts.append(pole)
        mb.faces.append((b, b + 1, b + 2))
        for uu, vv in tri_uv:
            mb.uvs.extend((uu, vv))


def add_band(mb, zone, z0, z1, radius, radius_top=None):
    """Franja (caras hacia fuera) alrededor del domo: cilindro, o tronco de cono si
    `radius_top` difiere, para seguir la pendiente del domo y verse desde arriba."""
    if radius_top is None:
        radius_top = radius
    u0, v0, u1, v1 = _zone_uv(zone)
    quad_uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
    for seg in range(SEGMENTS):
        a0 = 2.0 * math.pi * seg / SEGMENTS
        a1 = 2.0 * math.pi * (seg + 1) / SEGMENTS
        b = len(mb.verts)
        mb.verts.append((radius * math.cos(a0), radius * math.sin(a0), z0))
        mb.verts.append((radius * math.cos(a1), radius * math.sin(a1), z0))
        mb.verts.append((radius_top * math.cos(a1), radius_top * math.sin(a1), z1))
        mb.verts.append((radius_top * math.cos(a0), radius_top * math.sin(a0), z1))
        mb.faces.append((b, b + 1, b + 2, b + 3))
        for uu, vv in quad_uv:
            mb.uvs.extend((uu, vv))


def make_flat_material(name, color, roughness=0.8):
    """Material liso (sin textura): Godot lo importa con este color como albedo."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


def main():
    lib.clear_scene()

    # --- Domo, ramas y entrada (atlas) ---
    mb = lib.MeshBuilder()
    add_dome(mb, "hair")
    # Ramas cruzadas apoyadas sobre el domo (palitos inclinados, ±rot_y).
    for i in range(6):
        ang = 2.0 * math.pi * (i + 0.5) / 6.0
        cx, cy = 0.62 * math.cos(ang), 0.62 * math.sin(ang)
        tilt = math.radians(35.0 if i % 2 == 0 else -35.0)
        mb.add_box((cx, cy, 0.45), (0.07, 0.07, 0.75), "boots", rot_y=tilt)
    # Entrada: hueco oscuro en la cara frontal (-Y).
    mb.add_box((0.0, -0.93, 0.22), (0.42, 0.16, 0.44), "pants")
    # Mástil del banderín en la cima.
    mb.add_box((0.0, 0.0, HEIGHT + 0.25), (0.05, 0.05, 0.6), "accent")
    image = lib.make_atlas_image("Nest_atlas", PALETTE, seed=7)
    material = lib.make_textured_material("Nest_mat", image, metallic=0.0, roughness=0.9)
    mb.build("Nest", material, smooth=False)  # bordes crispados, como la granja

    # --- Zona teñible (material propio, blanco): franja de la base, cinta a media
    # altura siguiendo la pendiente (lo que se ve con la cámara cenital) y banderín ---
    tint = lib.MeshBuilder()
    add_band(tint, "skin", 0.06, 0.2, RADIUS * 1.02)
    add_band(tint, "skin", 0.24, 0.48, _ring_radius(0.24) + 0.04, _ring_radius(0.48) + 0.04)
    tint.add_box((0.22, 0.0, HEIGHT + 0.4), (0.4, 0.04, 0.26), "skin")
    tint_mat = make_flat_material("Nest_tint", (1.0, 1.0, 1.0))
    tint.build("NestTint", tint_mat, smooth=False)

    out = lib.resolve_output_path(os.path.join("assets", "models", "nest.glb"))
    lib.export_glb(out)


if __name__ == "__main__":
    main()
