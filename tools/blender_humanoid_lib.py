# -*- coding: utf-8 -*-
"""Librería compartida para generar humanoides low-poly suavizados en Blender 4.0.

No se ejecuta sola: la importan los scripts `blender_warrior.py` y `blender_scout.py`
(y reutiliza piezas `blender_sword.py`). Pensada para correr en modo headless:

    blender -b -P tools/blender_warrior.py

Convención del repo: comentarios en español, identificadores en inglés.
"""

import os
import sys
import math
from math import radians

import bpy

try:
    import numpy as np
except ImportError:  # numpy viene incluido en Blender, pero por si acaso
    np = None


# ---------------------------------------------------------------------------
# Atlas de textura
# ---------------------------------------------------------------------------

# Cada zona ocupa un rectángulo (u0, v0, u1, v1) normalizado del atlas (rejilla 3x2).
ZONES = {
    "skin":   (0.00, 0.00, 0.33, 0.50),
    "cloth":  (0.33, 0.00, 0.66, 0.50),
    "pants":  (0.66, 0.00, 1.00, 0.50),
    "boots":  (0.00, 0.50, 0.33, 1.00),
    "hair":   (0.33, 0.50, 0.66, 1.00),
    "accent": (0.66, 0.50, 1.00, 1.00),
}

# Margen interior para que las UVs no muestreen el borde de la zona vecina.
UV_INSET = 0.03


def make_atlas_image(name, palette, seed=0, size=256):
    """Genera una imagen-atlas con una zona de color por cada clave de `palette`.

    Cada zona = color base + ruido suave + franjas verticales sutiles. La imagen
    se empaqueta (`pack`) para que quede embebida dentro del .glb exportado.
    """
    img = bpy.data.images.new(name, width=size, height=size, alpha=True)

    if np is not None:
        rng = np.random.default_rng(seed)
        buf = np.zeros((size, size, 4), dtype=np.float32)
        buf[:, :, 3] = 1.0
        for zone, (u0, v0, u1, v1) in ZONES.items():
            col = palette.get(zone, (0.5, 0.5, 0.5))
            x0, x1 = int(u0 * size), int(u1 * size)
            y0, y1 = int(v0 * size), int(v1 * size)
            h, w = y1 - y0, x1 - x0
            noise = (rng.random((h, w)) - 0.5) * 0.12
            stripe = 0.05 * np.sin(np.arange(w) / max(w, 1) * math.pi * 6.0)
            for c in range(3):
                buf[y0:y1, x0:x1, c] = np.clip(col[c] + noise + stripe, 0.0, 1.0)
        img.pixels.foreach_set(buf.ravel())
    else:
        # Camino lento de respaldo sin numpy.
        pixels = [0.0] * (size * size * 4)
        for y in range(size):
            for x in range(size):
                u, v = x / size, y / size
                col = (0.5, 0.5, 0.5)
                for zone, (u0, v0, u1, v1) in ZONES.items():
                    if u0 <= u < u1 and v0 <= v < v1:
                        col = palette.get(zone, col)
                        break
                i = (y * size + x) * 4
                pixels[i:i + 4] = [col[0], col[1], col[2], 1.0]
        img.pixels[:] = pixels

    img.pack()
    return img


def make_textured_material(name, image, metallic=0.0, roughness=0.6):
    """Material Principled BSDF con `image` conectada al Base Color (sockets de Blender 4.0)."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (400, 0)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (100, 0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness

    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.location = (-300, 0)
    tex.image = image
    tex.interpolation = "Closest"  # look low-poly, sin difuminar las zonas

    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    return mat


# ---------------------------------------------------------------------------
# Construcción de malla por cajas
# ---------------------------------------------------------------------------

# Caras de un cubo unidad (esquinas en -1..1), en orden CCW visto desde fuera.
_FACES = [
    [(1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)],      # +X
    [(-1, 1, -1), (-1, -1, -1), (-1, -1, 1), (-1, 1, 1)],  # -X
    [(1, 1, -1), (-1, 1, -1), (-1, 1, 1), (1, 1, 1)],      # +Y
    [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)],  # -Y
    [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)],      # +Z
    [(-1, 1, -1), (1, 1, -1), (1, -1, -1), (-1, -1, -1)],  # -Z
]


class MeshBuilder:
    """Acumula cajas con UVs por cara mapeadas a una zona del atlas."""

    def __init__(self):
        self.verts = []
        self.faces = []
        self.uvs = []  # plano: dos floats por loop

    def add_box(self, center, size, zone, rot_y=0.0):
        # `rot_y` (radianes): gira las esquinas alrededor del eje Y (vertical)
        # respecto al centro. Con 0.0 el resultado es idéntico a una caja alineada
        # a ejes (retrocompatible). Útil p.ej. para aspas en X.
        cx, cy, cz = center
        hx, hy, hz = size[0] / 2.0, size[1] / 2.0, size[2] / 2.0
        cos_y, sin_y = math.cos(rot_y), math.sin(rot_y)
        u0, v0, u1, v1 = ZONES[zone]
        u0 += UV_INSET; v0 += UV_INSET; u1 -= UV_INSET; v1 -= UV_INSET
        face_uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
        for face in _FACES:
            base = len(self.verts)
            for ox, oy, oz in face:
                lx, ly, lz = ox * hx, oy * hy, oz * hz
                rx = lx * cos_y + lz * sin_y
                rz = -lx * sin_y + lz * cos_y
                self.verts.append((cx + rx, cy + ly, cz + rz))
            self.faces.append((base, base + 1, base + 2, base + 3))
            for uu, vv in face_uv:
                self.uvs.extend((uu, vv))

    def build(self, name, material, smooth=True):
        mesh = bpy.data.meshes.new(name + "_mesh")
        mesh.from_pydata(self.verts, [], self.faces)
        mesh.update()
        # Saneamos la geometría: from_pydata puede dejar la malla marcada como
        # inválida (el exportador glTF avisa "Mesh is not valid"), lo que además
        # estropea el reparto de pesos automáticos.
        mesh.validate(verbose=False)
        mesh.update()
        uvl = mesh.uv_layers.new(name="UVMap")
        uvl.data.foreach_set("uv", self.uvs)
        if smooth:
            for poly in mesh.polygons:
                poly.use_smooth = True
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.collection.objects.link(obj)
        obj.data.materials.append(material)
        return obj


# ---------------------------------------------------------------------------
# Escena / armature / skinning
# ---------------------------------------------------------------------------

def clear_scene():
    """Vacía la escena por defecto y los datos huérfanos."""
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for coll in (bpy.data.meshes, bpy.data.armatures, bpy.data.materials,
                 bpy.data.images, bpy.data.actions):
        for block in list(coll):
            coll.remove(block)


# Nombres de hueso del esqueleto estándar (compartidos por ambos humanoides).
BONES = [
    "pelvis", "spine", "head",
    "upper_arm.L", "lower_arm.L", "hand.L",
    "upper_arm.R", "lower_arm.R", "hand.R",
    "upper_leg.L", "lower_leg.L", "foot.L",
    "upper_leg.R", "lower_leg.R", "foot.R",
]


def build_armature(name, bone_defs):
    """Crea un armature en EDIT mode. `bone_defs`: lista de dicts {name, head, tail, parent}."""
    arm_data = bpy.data.armatures.new(name + "_armdata")
    arm_obj = bpy.data.objects.new(name, arm_data)
    bpy.context.collection.objects.link(arm_obj)
    bpy.context.view_layer.objects.active = arm_obj
    arm_obj.select_set(True)

    bpy.ops.object.mode_set(mode="EDIT")
    created = {}
    for bd in bone_defs:
        eb = arm_data.edit_bones.new(bd["name"])
        eb.head = bd["head"]
        eb.tail = bd["tail"]
        eb.use_connect = False
        created[bd["name"]] = eb
    for bd in bone_defs:
        if bd["parent"]:
            created[bd["name"]].parent = created[bd["parent"]]
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm_obj


def skin_with_auto_weights(mesh_obj, arm_obj):
    """Parentea la malla al armature con pesos automáticos (bone heat)."""
    bpy.ops.object.select_all(action="DESELECT")
    mesh_obj.select_set(True)
    arm_obj.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")


# ---------------------------------------------------------------------------
# Animación (Actions -> pistas NLA -> clips glTF separados)
# ---------------------------------------------------------------------------

def _new_action(arm, name):
    if arm.animation_data is None:
        arm.animation_data_create()
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data.action = act
    # Aseguramos modo euler en todos los huesos antes de keyframear.
    for bn in BONES:
        arm.pose.bones[bn].rotation_mode = "XYZ"
    return act


def _stash_action(arm, act, name):
    """Vuelca la action activa en su propia pista NLA y limpia la action activa."""
    track = arm.animation_data.nla_tracks.new()
    track.name = name
    track.strips.new(name, 1, act)
    arm.animation_data.action = None


def _key_pose(arm, frame, pose):
    """Keyframea rotación euler de todos los huesos + location de pelvis.

    `pose`: dict bone_name -> (rx, ry, rz) en grados; clave especial '_loc' para
    la location (x, y, z) en espacio local de pelvis (su eje Y local apunta hacia arriba).
    """
    for bn in BONES:
        pb = arm.pose.bones[bn]
        rx, ry, rz = pose.get(bn, (0.0, 0.0, 0.0))
        pb.rotation_euler = (radians(rx), radians(ry), radians(rz))
        pb.keyframe_insert("rotation_euler", frame=frame)
    pelvis = arm.pose.bones["pelvis"]
    pelvis.location = pose.get("_loc", (0.0, 0.0, 0.0))
    pelvis.keyframe_insert("location", frame=frame)


def animate_idle(arm):
    """Respiración sutil + bob. ~48 frames, loopable (frame 48 == frame 1)."""
    _new_action(arm, "idle")
    rest = {"_loc": (0, 0, 0)}
    breathe = {
        "_loc": (0, 0.02, 0),          # leve subida (Y local de pelvis = arriba)
        "spine": (4, 0, 0),
        "head": (-2, 0, 0),
        "upper_arm.L": (3, 0, 0),
        "upper_arm.R": (3, 0, 0),
    }
    _key_pose(arm, 1, rest)
    _key_pose(arm, 24, breathe)
    _key_pose(arm, 48, rest)
    act = arm.animation_data.action
    _stash_action(arm, act, "idle")


def animate_walk(arm):
    """Ciclo de marcha. ~25 frames, loopable. Brazos en oposición a piernas."""
    _new_action(arm, "walk")
    # Avance del personaje hacia +Y. Signo de los brazos opuesto al de las piernas
    # para garantizar oposición natural aunque hubiera que invertir un signo global.
    contact_a = {
        "_loc": (0, -0.02, 0),
        "upper_leg.L": (-28, 0, 0), "lower_leg.L": (10, 0, 0),
        "upper_leg.R": (28, 0, 0),  "lower_leg.R": (22, 0, 0),
        "upper_arm.L": (22, 0, 0),  "lower_arm.L": (15, 0, 0),
        "upper_arm.R": (-22, 0, 0), "lower_arm.R": (15, 0, 0),
        "spine": (2, 0, 0),
    }
    passing_a = {
        "_loc": (0, 0.03, 0),
        "upper_leg.L": (-5, 0, 0), "lower_leg.L": (15, 0, 0),
        "upper_leg.R": (10, 0, 0), "lower_leg.R": (35, 0, 0),
        "upper_arm.L": (8, 0, 0),  "upper_arm.R": (-8, 0, 0),
    }
    # La segunda mitad es la imagen especular (L<->R) de la primera.
    contact_b = {
        "_loc": (0, -0.02, 0),
        "upper_leg.R": (-28, 0, 0), "lower_leg.R": (10, 0, 0),
        "upper_leg.L": (28, 0, 0),  "lower_leg.L": (22, 0, 0),
        "upper_arm.R": (22, 0, 0),  "lower_arm.R": (15, 0, 0),
        "upper_arm.L": (-22, 0, 0), "lower_arm.L": (15, 0, 0),
        "spine": (-2, 0, 0),
    }
    passing_b = {
        "_loc": (0, 0.03, 0),
        "upper_leg.R": (-5, 0, 0), "lower_leg.R": (15, 0, 0),
        "upper_leg.L": (10, 0, 0), "lower_leg.L": (35, 0, 0),
        "upper_arm.R": (8, 0, 0),  "upper_arm.L": (-8, 0, 0),
    }
    _key_pose(arm, 1, contact_a)
    _key_pose(arm, 7, passing_a)
    _key_pose(arm, 13, contact_b)
    _key_pose(arm, 19, passing_b)
    _key_pose(arm, 25, contact_a)  # cierra el loop
    act = arm.animation_data.action
    _stash_action(arm, act, "walk")


def animate_attack(arm):
    """Golpe descendente del brazo derecho con twist de torso. ~24 frames."""
    _new_action(arm, "attack")
    neutral = {"_loc": (0, 0, 0)}
    windup = {
        "_loc": (0, 0, 0),
        "upper_arm.R": (135, 0, 0), "lower_arm.R": (-45, 0, 0),
        "spine": (0, 0, -15), "head": (0, 0, -8),
        "upper_arm.L": (0, 0, 0),
    }
    strike = {
        "_loc": (0, -0.03, 0),
        "upper_arm.R": (-55, 0, 0), "lower_arm.R": (10, 0, 0),
        "spine": (8, 0, 20), "head": (0, 0, 6),
        "upper_arm.L": (-15, 0, 0),
    }
    follow = {
        "_loc": (0, -0.01, 0),
        "upper_arm.R": (-30, 0, 0), "lower_arm.R": (20, 0, 0),
        "spine": (4, 0, 10),
    }
    _key_pose(arm, 1, neutral)
    _key_pose(arm, 6, windup)
    _key_pose(arm, 12, strike)
    _key_pose(arm, 18, follow)
    _key_pose(arm, 24, neutral)
    act = arm.animation_data.action
    _stash_action(arm, act, "attack")


# ---------------------------------------------------------------------------
# Humanoide completo
# ---------------------------------------------------------------------------

def build_humanoid(name, params, palette, seed=0):
    """Construye malla + armature + skin + 3 animaciones. Devuelve (arm_obj, mesh_obj)."""
    wm = params.get("width_mul", 1.0)
    hm = params.get("height_mul", 1.0)
    hd = params.get("head_mul", 1.0)

    def C(x, y, z):       # centro escalado
        return (x * wm, y, z * hm)

    def S(x, y, z, head=False):  # tamaño escalado
        m = hd if head else 1.0
        return (x * wm * m, y * (m if head else 1.0), z * hm * m)

    # --- Cajas del cuerpo (solapadas en articulaciones para que el Subsurf las funda).
    mb = MeshBuilder()
    parts = [
        # (centro, tamaño, zona)
        (C(0, 0, 1.00),    S(0.36, 0.24, 0.26),         "pants"),   # pelvis
        (C(0, 0, 1.32),    S(0.44, 0.26, 0.48),         "cloth"),   # torso
        (C(0, 0, 1.70),    S(0.26, 0.26, 0.28, True),   "skin"),    # cabeza
        (C(0, 0, 1.82),    S(0.28, 0.28, 0.12, True),   "hair"),    # pelo
        # brazo izquierdo (+X)
        (C(0.27, 0, 1.32), S(0.14, 0.16, 0.34),         "cloth"),
        (C(0.27, 0, 0.99), S(0.12, 0.13, 0.32),         "cloth"),
        (C(0.27, 0, 0.80), S(0.12, 0.14, 0.14),         "skin"),
        # brazo derecho (-X)
        (C(-0.27, 0, 1.32), S(0.14, 0.16, 0.34),        "cloth"),
        (C(-0.27, 0, 0.99), S(0.12, 0.13, 0.32),        "cloth"),
        (C(-0.27, 0, 0.80), S(0.12, 0.14, 0.14),        "skin"),
        # pierna izquierda
        (C(0.11, 0, 0.70), S(0.18, 0.20, 0.44),         "pants"),
        (C(0.11, 0, 0.29), S(0.15, 0.17, 0.44),         "pants"),
        (C(0.11, 0.07, 0.05), S(0.15, 0.30, 0.12),      "boots"),
        # pierna derecha
        (C(-0.11, 0, 0.70), S(0.18, 0.20, 0.44),        "pants"),
        (C(-0.11, 0, 0.29), S(0.15, 0.17, 0.44),        "pants"),
        (C(-0.11, 0.07, 0.05), S(0.15, 0.30, 0.12),     "boots"),
    ]
    for center, size, zone in parts:
        mb.add_box(center, size, zone)

    image = make_atlas_image(name + "_atlas", palette, seed=seed)
    material = make_textured_material(name + "_mat", image)
    mesh_obj = mb.build(name + "_body", material, smooth=True)

    # Subdivisión para el look suavizado (se queda como modificador, se exporta).
    subsurf = mesh_obj.modifiers.new("Subsurf", "SUBSURF")
    subsurf.levels = 1
    subsurf.render_levels = 1

    # --- Armature (mismas escalas que las cajas).
    def H(x, z):
        return (x * wm, 0.0, z * hm)

    bone_defs = [
        {"name": "pelvis",      "head": H(0, 0.90),    "tail": H(0, 1.12),    "parent": None},
        {"name": "spine",       "head": H(0, 1.12),    "tail": H(0, 1.55),    "parent": "pelvis"},
        {"name": "head",        "head": H(0, 1.55),    "tail": H(0, 1.84),    "parent": "spine"},
        {"name": "upper_arm.L", "head": H(0.20, 1.45), "tail": H(0.27, 1.14), "parent": "spine"},
        {"name": "lower_arm.L", "head": H(0.27, 1.14), "tail": H(0.27, 0.86), "parent": "upper_arm.L"},
        {"name": "hand.L",      "head": H(0.27, 0.86), "tail": H(0.27, 0.72), "parent": "lower_arm.L"},
        {"name": "upper_arm.R", "head": H(-0.20, 1.45),"tail": H(-0.27, 1.14),"parent": "spine"},
        {"name": "lower_arm.R", "head": H(-0.27, 1.14),"tail": H(-0.27, 0.86),"parent": "upper_arm.R"},
        {"name": "hand.R",      "head": H(-0.27, 0.86),"tail": H(-0.27, 0.72),"parent": "lower_arm.R"},
        {"name": "upper_leg.L", "head": H(0.11, 0.90), "tail": H(0.11, 0.50), "parent": "pelvis"},
        {"name": "lower_leg.L", "head": H(0.11, 0.50), "tail": H(0.11, 0.10), "parent": "upper_leg.L"},
        {"name": "foot.L",      "head": H(0.11, 0.10), "tail": (0.11 * wm, 0.22, 0.06 * hm), "parent": "lower_leg.L"},
        {"name": "upper_leg.R", "head": H(-0.11, 0.90),"tail": H(-0.11, 0.50),"parent": "pelvis"},
        {"name": "lower_leg.R", "head": H(-0.11, 0.50),"tail": H(-0.11, 0.10),"parent": "upper_leg.R"},
        {"name": "foot.R",      "head": H(-0.11, 0.10),"tail": (-0.11 * wm, 0.22, 0.06 * hm),"parent": "lower_leg.R"},
    ]
    arm_obj = build_armature(name, bone_defs)

    # --- Skin con pesos automáticos.
    skin_with_auto_weights(mesh_obj, arm_obj)

    # --- Animaciones.
    bpy.context.scene.render.fps = 24
    animate_idle(arm_obj)
    animate_walk(arm_obj)
    animate_attack(arm_obj)

    return arm_obj, mesh_obj


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

def export_glb(filepath):
    """Exporta toda la escena a un .glb con las pistas NLA como clips separados."""
    os.makedirs(os.path.dirname(os.path.abspath(filepath)), exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=filepath,
        export_format="GLB",
        export_animations=True,
        export_animation_mode="NLA_TRACKS",
        export_apply=False,  # NO aplicar modificadores: rompería el Armature/skin
        use_selection=False,
    )
    print("[blender_humanoid_lib] exportado:", filepath)


def resolve_output_path(default_rel):
    """Devuelve la ruta de salida: argumento tras '--' si existe, si no la de por defecto.

    `default_rel` es relativa a la raíz del proyecto (carpeta padre de tools/).
    """
    argv = sys.argv
    if "--" in argv:
        extra = argv[argv.index("--") + 1:]
        if extra:
            return extra[0]
    here = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(here)
    return os.path.join(project_root, default_rel)
