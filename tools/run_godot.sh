#!/usr/bin/env bash
# =============================================================================
# run_godot.sh — lanza godot-4 con techo de memoria y de tiempo, y lo mata siempre al acabar
# =============================================================================
# Uso:
#   tools/run_godot.sh <segundos> <args de godot-4…>
#   tools/run_godot.sh 200 --headless tools/SmokeTest.tscn
#   AUGUR_KEY=… BIOSPHERA_RUN_LABEL=baseline tools/run_godot.sh 2400 --headless --path . --script res://tools/measure_run.gd
#
# Por qué existe: el snap de godot-4 mete el proceso en SU propio scope de systemd
# (`snap.godot-4.godot-4-<uuid>.scope`), fuera de cualquier `systemd-run --scope` que lo envuelva.
# Así que `systemd-run -p MemoryMax=…` NO limita a Godot, y `timeout`/`systemctl stop` sobre el scope
# externo no lo matan (visto el 2026-10-02). Este script localiza el scope del snap, le pone el techo
# (`MemoryMax`, sin swap) en caliente y, al acabar o al pasar el tiempo, lo para entero.
#
# El scope se busca por el PID de SU `godot-4 &` (y sus descendientes), no con `pgrep -x godot-4`:
# con varias instancias a la vez (tools/measure_stage.sh) cogería el scope de otra y la pararía.
#
# Antes de lanzar comprueba la RAM disponible (CLAUDE.md, «Ejecución de simulaciones»). Las
# variables de entorno pasan tal cual a Godot. Sale con el código de Godot (124 si se agotó el tiempo).
# =============================================================================

set -uo pipefail

MEM_MAX="${GODOT_MEM_MAX:-4G}"
MIN_AVAILABLE_KIB=$((4 * 1024 * 1024))

if [ $# -lt 2 ]; then
  sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
LIMIT_S="$1"
shift

avail="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
if [ "$avail" -lt "$MIN_AVAILABLE_KIB" ]; then
  echo "run_godot: solo hay $((avail / 1024)) MiB disponibles (< 4 GiB); no se lanza" >&2
  exit 3
fi

godot-4 "$@" &
LAUNCHER=$!

# PID lanzado y todos sus descendientes (snap run suele hacer exec en el mismo PID, pero por si
# acaso se mira el árbol entero).
own_pids () {
  local queue=("$LAUNCHER") p
  while [ ${#queue[@]} -gt 0 ]; do
    p="${queue[0]}"
    queue=("${queue[@]:1}")
    echo "$p"
    for c in $(pgrep -P "$p"); do queue+=("$c"); done
  done
}

# El snap tarda un instante en mover el proceso a su scope: se espera a que aparezca.
SCOPE=""
for _ in $(seq 1 50); do
  for pid in $(own_pids); do
    s="$(sed -n 's#.*/\(snap\.godot-4\.[^/]*\.scope\)$#\1#p' "/proc/$pid/cgroup" 2>/dev/null)"
    if [ -n "$s" ]; then SCOPE="$s"; break 2; fi
  done
  sleep 0.1
done

stop_scope () {
  if [ -n "$SCOPE" ]; then
    systemctl --user stop "$SCOPE" >/dev/null 2>&1 || true
  fi
}
trap stop_scope EXIT INT TERM

if [ -n "$SCOPE" ]; then
  systemctl --user set-property --runtime "$SCOPE" MemoryMax="$MEM_MAX" MemorySwapMax=0 \
    || echo "run_godot: no se pudo poner el techo de memoria a $SCOPE" >&2
else
  echo "run_godot: no se encontró el scope del snap; Godot corre SIN techo de memoria" >&2
fi

# Espera a Godot con techo de tiempo propio (timeout no alcanza al proceso del snap).
CODE=0
elapsed=0
while kill -0 "$LAUNCHER" 2>/dev/null; do
  if [ "$elapsed" -ge "$LIMIT_S" ]; then
    echo "run_godot: se agotaron ${LIMIT_S}s; se para Godot" >&2
    CODE=124
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
if [ "$CODE" -eq 0 ]; then
  wait "$LAUNCHER"
  CODE=$?
fi
stop_scope
if [ "$CODE" -eq 124 ]; then
  [ -z "$SCOPE" ] && kill -KILL "$LAUNCHER" 2>/dev/null
  wait "$LAUNCHER" 2>/dev/null   # recoge el proceso: un zombi también responde a kill -0
fi
if kill -0 "$LAUNCHER" 2>/dev/null; then
  echo "run_godot: aviso, el godot-4 lanzado ($LAUNCHER) sigue vivo: pgrep -a -x godot-4" >&2
fi
exit "$CODE"
