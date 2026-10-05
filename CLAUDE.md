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
  `Relationships`, `Climate`, `Selection`, `Groups`, `Biomes`, `Stats`, `Augur`,
  `Analytics`. `Augur` es el SDK de analítica (`addons/augur/`): se carga siempre pero no hace nada
  sin `AUGUR_KEY` en el entorno. `Analytics` es el único cliente de `Augur` y es autoload porque
  vive entre escenas (`StartScreen` → simulación). No abusar ni añadir sin justificación.
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

Se **pueden** lanzar el juego, escenas de prueba y simulaciones (`godot-4`, `tools/SmokeTest.tscn`,
capturas visuales…), pero la memoria de este entorno es justa y el swap se llena con facilidad. Por
eso, siempre:

- **Lanzar siempre con `tools/run_godot.sh <segundos> <args de godot-4…>`**, nunca `godot-4` a
  secas. El script no lanza si hay menos de 4 GiB disponibles, pone el techo de memoria (4 GiB, sin
  swap) y de tiempo, y al acabar para Godot entero. Ejemplo:
  `env -u AUGUR_KEY tools/run_godot.sh 200 --headless tools/SmokeTest.tscn`.
- **Regresión del guardado:** `env -u AUGUR_KEY tools/save_load_test.sh` guarda una partida y la carga
  en otro proceso, compara el estado campo a campo y sale con 0 si coinciden. Pásalo tras cualquier
  cambio que añada o mueva estado de la simulación: un campo que no se guarde sale como diferencia.
  `BIOSPHERA_SAVE_TEST_S=<s>` alarga la fase de guardado (por defecto 120 s). Fundar un nido exige
  150 s, así que para cubrir nidos usa `BIOSPHERA_SAVE_TEST_S=330`.
- **Rendimiento de render:** `env -u AUGUR_KEY tools/run_godot.sh 90 --path . --script res://tools/fps_bench.gd -- --spheres=100 --fx=off`
  (con ventana, sin vsync; `--fx=off|low|medium|high`, `--halo=always|hover|never`). Imprime
  `avg_ms`/`p99_ms`/`fps`. El escritorio mete ruido: compara siempre contra un `--fx=off` de la misma
  tanda. Abre ventana en el escritorio y roba el foco (ver la skill `ver-el-juego`).
- 🔴 **`systemd-run --scope -p MemoryMax=…` y `timeout` NO sirven con el snap**: el snap mete a Godot
  en su propio scope (`snap.godot-4.godot-4-<uuid>.scope`), fuera del envoltorio, así que ni lo
  limitan ni lo matan (visto el 2026-10-02). `run_godot.sh` actúa sobre el scope del snap.
- **Comprobar al acabar** con `pgrep -a -x godot-4` que no queda ninguno vivo. Si queda alguno:
  `systemctl --user stop <scope>`, con el scope sacado de `/proc/<pid>/cgroup` (`kill` y `pkill` no
  tienen permiso desde el sandbox de Claude Code).

## Medir y leer resultados

- **Una etapa de medición** (3 partidas de *Dos tribus*, 1 año corto, sin ventana, en paralelo):
  `AUGUR_KEY=… tools/measure_stage.sh <label>`. Tarda ~22–28 min; los resultados van a Augur con
  `run_label = <label>`. Nunca lanzar varias `measure_run` a la vez sin `BIOSPHERA_AUGUR_ROOT` propia:
  compartirían `user://augur/` y el SDK borraría sesiones ajenas.
- **Medir con un evento del entorno:** `BIOSPHERA_EVENT="<kind>:<intensidad>:day=<n>:dur=<días>"`
  (kinds `drought`, `cold_wave`, `storm`, `abundance`, `plague`; `day` relativo al día de arranque).
  Lo leen `tools/measure_run.gd` (y por tanto `measure_stage.sh`) y la fase save de
  `tools/save_load_test.sh`; el juego no lo lee.
- **Medir con otro tuning:** `BIOSPHERA_TUNING="clave=valor,clave=valor"` cambia propiedades de
  `SimTuning` solo en `tools/measure_run.gd` (y por tanto en `measure_stage.sh`), p. ej.
  `nest_min_members=999` apaga los nidos. Sirve para bisecar regresiones; una clave desconocida sale
  con 1.
- **Si `measure_stage.sh` deja una raíz sin subir** (`augur_run_<n>`, «conserva N eventos sin
  subir»), la siguiente etapa no arranca. Hay que relanzar su subida con la clave cargada:
  `BIOSPHERA_AUGUR_ROOT="user://augur_run_<n>/" GODOT_MEM_MAX=2G tools/run_godot.sh 400 --headless --path .`.
  Con `UPLOAD_PASS_S=400` pasa menos.
- **La `AUGUR_KEY` de producción** (write_key del proyecto `biosphera`, id 3) vive en
  `~/.config/augur/biosphera-prod.env` (600, fuera del repo). No está en el entorno por defecto: se
  carga solo para la ejecución que deba enviar datos, p. ej.
  `(set -a; . ~/.config/augur/biosphera-prod.env; set +a; tools/measure_stage.sh <label>)`.
- **Leer Augur:** `tools/augur-query.sh <acción> ['<json>']` (p. ej. `chart.query` con una
  `ChartDefinition`, `session.list`, `board.get`). Usa el usuario **viewer** de Claude, cuyas
  credenciales viven en `~/.config/augur/claude-viewer.env` (fuera del repo). Solo lectura.
- Las gráficas del tablero «Fidelidad» se versionan en `tools/augur-boards.json` y se suben con
  `tools/augur-setup.sh` (pide la contraseña de David).
