# CLAUDE.md — BioSphera

## Documentación: qué se publica y qué es local

El diseño de BioSphera (GDD, arquitectura, decisiones) vive en un vault privado de Obsidian y
**no se publica en este repo**. En la máquina de desarrollo se accede por dos symlinks locales,
ignorados en `.gitignore`:

- `AGENTS.md` → página del proyecto en el vault (visión, milestones, decisiones globales cerradas).
- `docs/` → carpeta del proyecto en el vault (`docs/Programación.md`, `docs/GDD/…`).

Si existen, **léelos antes de proponer o implementar cualquier cambio no trivial**. En un clon del
repo público no existen: las referencias `docs/…` de este fichero y de los comentarios del código
(`## Ver docs: docs/GDD/…`) son referencias de diseño, no enlaces navegables.

Documentación que **sí** está en el repo:

- **Plan de implementación y backlog ejecutable:** [.github/IMPLEMENTATION_PLAN.md](.github/IMPLEMENTATION_PLAN.md)
- **Instrucciones de código GDScript:** [.github/instructions/gdscript.instructions.md](.github/instructions/gdscript.instructions.md)

---

## Contexto del proyecto

BioSphera es una simulación sandbox de ecosistema 3D en Godot 4. El jugador es observador y experimentador: no controla individuos, sino que ajusta condiciones globales y observa cómo evoluciona la vida. Las esferas son seres vivos con rasgos heredables, evolución darwinista real (mutación gaussiana + selección natural) y comportamiento dirigido por Utility AI.

**Motor:** Godot 4.6 (Forward+, GDScript) | **Plataforma:** PC Linux/Windows | **Tono:** zen + dopamínico

> Spec en el segundo cerebro: `/home/david/Documents/workspace/Brain/03 - Proyectos/BioSphera.md`
> (panorama, milestones y estado). El detalle de diseño/arquitectura vive en la misma carpeta del
> vault, accesible en local por los symlinks `AGENTS.md` y `docs/` (no publicados).

---

## Reglas de código

- **Lenguaje:** GDScript puro. No usar C# ni GDExtension salvo cuello de botella demostrado y medido con el profiler.
- **Convenciones:** `class_name` siempre que sea reutilizable, `snake_case` para variables y funciones, `PascalCase` para clases, `MAYÚSCULAS` para constantes, señales para desacoplar sistemas.
- **Autoloads:** solo para sistemas globales. Los registrados en `project.godot` son: `SimConfig`,
  `SimulationClock`, `EventLog`, `GlobalParams`, `SpatialIndex`, `TerritorySystem`, `Genetics`,
  `Relationships`, `Climate`, `Selection`, `Groups`, `Biomes`, `Stats`, `PlayerControl`. No abusar
  ni añadir sin justificación.
- **Estructura `res://`:** respetar la existente (definida en `docs/Programación.md`, local). No crear carpetas nuevas sin justificación.
- **Idioma:** commits y comentarios en español; identificadores en código en inglés.

---

## Workflow esperado

1. Antes de implementar una feature, leer la sección correspondiente del GDD o de Programación.
2. Si la doc no cubre la decisión, **preguntar** antes de inventar diseño.
3. El backlog ejecutable son las tareas `[ ]` en `.github/IMPLEMENTATION_PLAN.md`. Al cerrar una, marcarla `[x]` y propagar decisiones nuevas a la doc correspondiente.
4. No copiar texto de la doc al código; enlazar desde comentarios cuando aporte contexto.
5. Tras cualquier cambio que toque el tick de simulación, verificar rendimiento (objetivo: 100 esferas a 60 fps).

---

## Ejecución de simulaciones

- **No ejecutar simulaciones propias** (`godot`, escenas de prueba, benchmarks del tick, etc.): consumen demasiada memoria en este entorno y disparan el uso de swap.
- Siempre **pedir al usuario que ejecute** la simulación o escena correspondiente y que pegue los resultados (logs, FPS, capturas, métricas).
- Aplica también a cualquier herramienta auxiliar que arranque el motor o cargue el proyecto completo en memoria.
