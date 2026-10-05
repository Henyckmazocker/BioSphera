# BioSphera

Simulación *sandbox* de ecosistema en 3D hecha con Godot 4. Sobre un mundo con biomas, una población
de seres vivos con rasgos heredables se alimenta, se agrupa, compite por territorio, se reproduce y
muere. La evolución es darwinista real: cada cría hereda la media de sus dos progenitores más una
mutación gaussiana, y la selección natural hace el resto.

El jugador no dirige a nadie: **observa y experimenta**. Pausa, acelera el tiempo, ajusta los
parámetros globales del mundo y mira cómo responde el ecosistema.

<!-- TODO: captura de la simulación (assets/readme/captura.png) -->

## Estado

En desarrollo (Beta). Las fases de prototipo y Alpha están cerradas. Funciona hoy:

- Rasgos heredables, reproducción sexual y nombres por linaje.
- Comportamiento por Utility AI.
- Grupos, relaciones y memoria social.
- Combate y territorialidad.
- Economía de recursos (madera, piedra, oro, granjas y armas).
- Estadísticas e inspección individual.

Pendiente: guardado y carga de escenarios, y eventos del entorno.

## Requisitos

- [Godot 4.6](https://godotengine.org/download) (versión estándar, no la .NET). Renderer Forward+.
- PC con Linux o Windows.

## Abrir y ejecutar

1. Clona el repositorio.
2. En el gestor de proyectos de Godot, *Importar* y elige `project.godot`.
3. La primera apertura reimporta todos los assets y tarda un poco: es normal.
4. Pulsa *Ejecutar* (F5). Se abre la pantalla de inicio (`ui/StartScreen.tscn`), donde se elige un
   escenario (`data/presets/`) y se configuran las especies iniciales.

### Controles

| Tecla | Acción |
|---|---|
| `Espacio` | Pausa / reanudar |
| `1`–`5` | Velocidad x1 / x2 / x4 / x8 / x16 |
| `W` `A` `S` `D` | Desplazar la cámara |
| `F` / `R` | Enfocar la selección / reiniciar la cámara |
| `P` | Panel de parámetros globales |
| `T` | Estadísticas |
| `S` | Panel de especies |
| `O` | Overlay de territorio (apagado → especie → grupo) |
| `E` | Modo experimentación |
| `H` | Ocultar la interfaz |
| `K` | Ayuda |
| `N` | Ver navmesh (depuración) |

## Prueba de regresión

`tools/SmokeTest.tscn` corre la simulación sin ventana durante 90 s simulados a velocidad x8. Mide
cambios de acción demasiado rápidos, esferas atascadas, colapso de población y salidas del mundo, y
termina con un veredicto `PASS`/`FAIL` (código de salida 0/1):

```bash
godot --headless tools/SmokeTest.tscn
```

`tools/analyze_logs.py` analiza en detalle los logs JSONL de una sesión.

## Privacidad

Si la analítica está configurada en el entorno (`AUGUR_KEY`) y aceptas en la pantalla de consentimiento,
el juego envía de forma anónima cómo evoluciona cada partida (población, nacimientos y muertes, combates,
grupos, granjas y rasgos medios) a un servidor propio. Sin esa variable o si rechazas, no se envía ni se
guarda nada. La decisión se cambia cuando quieras desde el botón «Privacidad» de la pantalla de inicio.

## Estructura

```
data/       recursos de datos: rasgos, tuning (sim_tuning), presets de escenario
entities/   seres vivos y objetos del mundo (Sphere, Plant, Farm, Tree, Deposit…)
systems/    autoloads de simulación (reloj, genética, grupos, territorio, clima…)
world/      mundo, spawner, cámara y render
ui/         HUD, paneles y pantalla de inicio
shaders/    shaders del agua y de las entidades
assets/     modelos glTF y texturas
tools/      arnés de pruebas y scripts auxiliares (Blender, análisis de logs)
```

El documento de diseño (GDD) es privado y no está en este repositorio: las referencias `docs/…` del
código son notas de diseño, no enlaces navegables.

## Licencia

[MIT](LICENSE) © 2026 David Carvajal Abellán
