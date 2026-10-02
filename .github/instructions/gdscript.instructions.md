---
applyTo: "**/*.gd,**/*.tscn,**/*.gdshader,project.godot"
---
# Instrucciones para código del proyecto BioSphera (Godot 4 / GDScript)

Toda la documentación de diseño y arquitectura vive en el vault personal y está expuesta en el workspace vía symlinks. Consúltala siempre antes de proponer cambios no triviales.

## Documentación de referencia (symlinks → Brain vault)

> Solo existe en la máquina de desarrollo: `AGENTS.md` y `docs/` son symlinks locales ignorados en
> `.gitignore` y **no se publican**. En un clon del repo estos enlaces no resuelven; ver `CLAUDE.md`
> → «Documentación: qué se publica y qué es local».

- Visión general del proyecto e índice: [AGENTS.md](../../AGENTS.md)
- Arquitectura de código, estructura de carpetas, sistemas y stack: [docs/Programación.md](../../docs/Program%C3%A1ci%C3%B3n.md)
- Build y publicación: [docs/Build y Publicación.md](../../docs/Build%20y%20Publicaci%C3%B3n.md)
- GDD — Concepto: [docs/GDD/Concepto.md](../../docs/GDD/Concepto.md)
- GDD — Mecánicas: [docs/GDD/Mecánicas.md](../../docs/GDD/Mec%C3%A1nicas.md)
- GDD — Mundo y Niveles: [docs/GDD/Mundo y Niveles.md](../../docs/GDD/Mundo%20y%20Niveles.md)
- GDD — Personajes: [docs/GDD/Personajes.md](../../docs/GDD/Personajes.md)
- GDD — UI/UX: [docs/GDD/UI - UX.md](../../docs/GDD/UI%20-%20UX.md)
- GDD — Arte y Estética: [docs/GDD/Arte y Estética.md](../../docs/GDD/Arte%20y%20Est%C3%A9tica.md)
- GDD — Audio y Música: [docs/GDD/Audio y Música.md](../../docs/GDD/Audio%20y%20M%C3%BAsica.md)
- GDD — Narrativa: [docs/GDD/Narrativa.md](../../docs/GDD/Narrativa.md)

## Convenciones rápidas

- Motor: Godot 4.x estable. Lenguaje principal: **GDScript** (C# / GDExtension solo si hay cuellos de botella demostrados).
- Estructura `res://` propuesta definida en [docs/Programación.md](../../docs/Program%C3%A1ci%C3%B3n.md) — respétala al crear nuevos scripts/escenas.
- Sistemas globales como `SimulationClock`, `GeneticsSystem`, `BehaviorSystem` van en `systems/` como autoloads.
- Idioma del proyecto y de los commits/comentarios: **español**. Identificadores en código: inglés salvo que la doc indique otra cosa.
- Notación de enlaces tipo `[[BioSphera/...]]` en la doc son wikilinks de Obsidian; en este workspace el equivalente está bajo `docs/`.

## Workflow esperado del agente

1. Antes de implementar una feature, leer la sección correspondiente del GDD o de Programación.
2. Si la doc no cubre la decisión, **preguntar** antes de inventar diseño.
3. No copiar texto de la doc al código; enlazar a ella desde comentarios cuando aporte contexto.
