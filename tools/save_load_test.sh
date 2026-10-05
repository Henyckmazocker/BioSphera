#!/usr/bin/env bash
# =============================================================================
# save_load_test.sh — ida y vuelta de guardado/carga en DOS procesos
# =============================================================================
# Uso:
#   env -u AUGUR_KEY tools/save_load_test.sh
#
# Fase `save`: arranca como tools/SmokeTest.tscn (semilla 20260519), corre 120 s de sim a
# x8 y guarda en la ranura `test` (user://saves/test.sav, bajo el snap). Fase `load`: en
# OTRO proceso (los autoloads no se resetean entre partidas), carga ese save, recaptura y
# compara campo a campo + el orden de `SimulationClock._entities`. Sale con el código de
# la fase que falle (0 = idénticas). Ambas pasan por tools/run_godot.sh (techo de memoria
# y de tiempo; ver CLAUDE.md, «Ejecución de simulaciones»).
#
# Con BIOSPHERA_SAVE_TEST_S=<segundos> la fase save corre ese tiempo de sim en vez de 120
# (p. ej. 330 para que dé tiempo a fundar nidos, plan «Nidos y Asentamientos», M0); el techo
# de tiempo real de la fase crece en proporción.
#
# Con BIOSPHERA_EVENT="<kind>:<i>:day=<n>:dur=<días>" la fase save dispara ese evento
# (día relativo al arranque) y guarda con él activo; la fase load lo lee del save.
# =============================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

save_s="${BIOSPHERA_SAVE_TEST_S:-120}"
# 400 s reales para 120 de sim (x8 y arranque holgados); más sim, más margen.
save_limit=$(awk -v s="$save_s" 'BEGIN { l = int(400 * s / 120); print (l > 400 ? l : 400) }')

echo "=== save_load_test: fase save (${save_s} s de sim) ==="
BIOSPHERA_SAVE_LOAD_PHASE=save tools/run_godot.sh "$save_limit" --headless tools/SaveLoadTest.tscn
code=$?
if [ "$code" -ne 0 ]; then
  echo "save_load_test: la fase save salió con $code" >&2
  exit "$code"
fi

echo "=== save_load_test: fase load ==="
BIOSPHERA_SAVE_LOAD_PHASE=load tools/run_godot.sh 200 --headless tools/SaveLoadTest.tscn
code=$?
if [ "$code" -ne 0 ]; then
  echo "save_load_test: la fase load salió con $code" >&2
fi
exit "$code"
