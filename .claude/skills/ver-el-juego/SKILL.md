---
name: ver-el-juego
description: Arrancar BioSphera CON VENTANA y conducirlo desde un script para mirarlo y capturar PNG, sin tocar el ratón ni el teclado de David. Úsala cuando haya que comprobar algo que se ve (StartScreen, HUD, paneles, la pantalla de consentimiento, si un texto cabe) o cuando pidan «arranca el juego», «hazme una captura», «compruébalo».
---

# Ver el juego — BioSphera con ventana

Esto **mira**, no mide. Para medir están `tools/SmokeTest.tscn` (salud de la simulación) y, con
`AUGUR_KEY`, las gráficas de Augur. Una etapa de medición (3 partidas de 1 año de *Dos tribus* a la
vez, headless, cada una con su raíz `user://augur_run_<n>/`, y la subida final) es:

```bash
AUGUR_KEY=… tools/measure_stage.sh <label>     # la clave solo en la línea de comando
```

No lances `measure_run.gd` en paralelo a mano sin `BIOSPHERA_AUGUR_ROOT`: con un `user://augur/`
compartido el SDK de una partida borra las sesiones de las otras.

## Antes de lanzar nada: memoria

Las reglas son las de `CLAUDE.md` («Ejecución de simulaciones») y no se saltan:

```bash
tools/run_godot.sh <s> --path . --script res://tools/_ver_<algo>.gd   # RAM, techo y parada
pgrep -a -x godot-4         # al acabar: debe salir vacío
```

Las variables de entorno pasan tal cual: `VAR=x tools/run_godot.sh …`. **No** uses
`systemd-run --scope … timeout godot-4`: el snap saca a Godot de ese scope y ni lo limita ni lo mata
(ver `CLAUDE.md`).

**Ruido esperado, no es un fallo:** Godot no consigue Vulkan con la AMD 780M y cae a OpenGL 3
(`ERROR: Condition "err != VK_SUCCESS"` + `switching to OpenGL 3`). Los `Texture with GL ID … leaked`
al salir, también.

## Conducir por código, nunca con input de X

🔴 La ventana sale en el escritorio de David (`DISPLAY=:0`) y **le roba el foco al abrirse**: si él
está escribiendo o hace clic, su input llega al juego. El 2026-10-02 eso arrancó la simulación varias
veces sin que nadie la pidiera y aceptó un consentimiento solo. Por eso:

- **No** se prueba lanzando `godot-4 --path .` y mirando: no se distingue lo que hace el código de lo
  que hace David.
- **No** se inyectan clics con XTest/xdotool: mueven el ratón de David.
- **Sí** un conductor `extends SceneTree` que monta la escena y pulsa los botones con
  `boton.pressed.emit()`.

```gdscript
extends SceneTree
## TEMPORAL — se borra al acabar.

var _hecho := false

func _process(_d: float) -> bool:      # los nodos se montan AQUÍ: en _initialize() no hay root
	if _hecho:
		return false
	_hecho = true
	_todo()
	return false

func _todo() -> void:
	var ss: Node = load("res://ui/StartScreen.tscn").instantiate()
	root.add_child(ss)
	for i in 10:
		await process_frame
	await _cap("1_inicio.png")
	quit()

func _cap(nombre: String) -> void:
	await RenderingServer.frame_post_draw   # sin esto guardas el frame ANTERIOR
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_capturas_tmp/"))
	root.get_texture().get_image().save_png("res://_capturas_tmp/" + nombre)
```

- Los autoloads (`Analytics`, `Augur`, `SimConfig`…) **sí** se cargan con `--script`: están en
  `root.get_node("Analytics")`.
- `--script` con ventana **no** lleva `--headless` (sin ventana no hay nada que capturar).
- Las pantallas modales (`ui/ConsentScreen.gd`) se encuentran por su señal, no por nombre:
  `for c in ss.get_children(): if c.has_signal("decided"): …`. Expone `accept_button`,
  `decline_button` y `back_button`.
- Para entrar en la simulación, el mismo camino que el botón: `ss._on_start_pressed()`.

## Las trampas

1. **El conductor y las capturas van bajo `res://`, nunca en `/tmp`.** El snap de Godot no lee
   `/tmp`. Nómbralos `tools/_ver_<algo>.gd` y `_capturas_tmp/`, y **bórralos al terminar** (también
   el `.uid` que genere): no se commitean.
2. **`user://` es el de David.** Vive en `~/snap/godot-4/<revisión>/.local/share/godot/app_userdata/BioSphera/`
   (la revisión cambia con las actualizaciones del snap; hoy `40`). Lo que una prueba escriba ahí
   (`augur/`, `logs/`) lo verá él en su siguiente arranque: si la prueba crea estado de Augur, se
   borra al acabar.
3. **`AUGUR_KEY` en el entorno manda datos a producción.** Para probar sin red, lanza con
   `env -u AUGUR_KEY`. Si hace falta clave, va en la línea de comando, nunca en un fichero del repo.
4. **`quit()` no es cerrar la ventana**: no dispara `Augur.closing` ni el `session_end` del SDK.
5. 🔴 **El conductor no nombra `class_name` de entidades** (`Sphere`, `Plant`, `Farm`…), ni en tipos
   ni en `is`. Un script `--script` que los nombra compila `entities/Sphere.gd` **antes** que los
   autoloads, que lo necesitan, y lo deja roto para toda la sesión. Usa `Node`, `has_method()` o
   `has_signal()` (encontrado el 2026-10-02 en la verificación de M3 de «Integración con Augur»).
6. **×16 con ventana no es ×16.** Con ~300 esferas la simulación va a ~×6 efectivo: un año simulado
   tarda bastante más de los ~12,5 min teóricos. Para conducir hasta un estado concreto, espera por
   `Climate.day_index` o por tiempo simulado, no por segundos reales.
7. **Los `.uid` de ficheros nuevos** no los genera una ejecución normal; sí
   `godot-4 --headless --path . --import` (con los mismos límites de memoria).

## Mirar la captura

Cópiala al scratchpad de la sesión y **ábrela con la herramienta de imagen**. Una captura negra es un
fallo de arranque, no una foto; un PNG que nadie abre no ha verificado nada.
