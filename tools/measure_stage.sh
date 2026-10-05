#!/usr/bin/env bash
# =============================================================================
# measure_stage.sh — mide una etapa: N partidas de measure_run a la vez, cada una con su raíz de Augur
# =============================================================================
# Uso:
#   AUGUR_KEY=… tools/measure_stage.sh <label> [partidas=3]
#   AUGUR_KEY=… tools/measure_stage.sh baseline-rapida
#
# Por partida n lanza, en segundo plano y espaciadas STAGE_SPACING_S (5 s, para que run_godot.sh
# compruebe la RAM con la anterior ya cargada):
#   BIOSPHERA_RUN_LABEL=<label> BIOSPHERA_AUGUR_ROOT=user://augur_run_<n>/ GODOT_MEM_MAX=2G \
#     tools/run_godot.sh <MEASURE_RUN_LIMIT_S> --headless --path . --script res://tools/measure_run.gd
# Cada una tiene su propio estado de Augur: con un `user://augur/` compartido el SDK de una subiría y
# BORRARÍA las sesiones de las otras como huérfanas. El `user://augur/` de David no se toca.
#
# Al acabar las N imprime por partida: código de salida, duración real, días y población final A/B.
# Después, la pasada de subida: por cada raíz con eventos sin subir, un arranque headless de la escena
# principal (StartScreen) de hasta UPLOAD_PASS_S (120 s) con esa raíz; el SDK sube lo pendiente en
# configure(). Se para en cuanto no queda nada pendiente. Raíz sin nada pendiente → se borra.
#
# AUGUR_KEY sale del entorno, nunca de un fichero. Los logs de cada arranque van a un directorio
# temporal que se imprime al empezar. Sale ≠ 0 si alguna partida falló o quedó cola sin subir.
# Necesita jq. Ver docs: docs/Planes/…/Plan - Medición Rápida.md.
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_GODOT="$ROOT_DIR/tools/run_godot.sh"
# user:// del proyecto bajo el snap de godot-4 (la revisión cambia con las actualizaciones).
USERDATA="${BIOSPHERA_USERDATA:-$HOME/snap/godot-4/current/.local/share/godot/app_userdata/BioSphera}"
RUN_LIMIT_S="${MEASURE_RUN_LIMIT_S:-2400}"
UPLOAD_PASS_S="${UPLOAD_PASS_S:-120}"
SPACING_S="${STAGE_SPACING_S:-5}"
MEM_PER_RUN="2G"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
LABEL="$1"
RUNS="${2:-3}"
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "measure_stage: nº de partidas no válido: $RUNS" >&2; exit 2; }
[ -n "${AUGUR_KEY:-}" ] || { echo "measure_stage: falta AUGUR_KEY en el entorno" >&2; exit 2; }
command -v jq >/dev/null || { echo "measure_stage: falta 'jq' en el PATH" >&2; exit 1; }
[ -d "$USERDATA" ] || { echo "measure_stage: no existe $USERDATA (¿BIOSPHERA_USERDATA?)" >&2; exit 1; }

root_uri () { echo "user://augur_run_$1/"; }
root_dir () { echo "$USERDATA/augur_run_$1"; }

# Una raíz que ya existe es de una etapa anterior que no terminó de subir: no se mezcla.
for n in $(seq 1 "$RUNS"); do
  if [ -e "$(root_dir "$n")" ]; then
    echo "measure_stage: ya existe $(root_dir "$n") (etapa anterior sin subir); súbela o bórrala antes" >&2
    exit 1
  fi
done

# Eventos aún sin aceptar por el servidor en una raíz: por cada sesión en disco, los registros con
# seq > [acked] <sesión> de su state.cfg (ausente = -1).
pending_events () {
  local dir="$1" total=0 f sid acked n
  [ -d "$dir/sessions" ] || { echo 0; return; }
  for f in "$dir"/sessions/*.jsonl; do
    [ -e "$f" ] || continue
    sid="$(basename "$f" .jsonl)"
    acked="$(sed -n "/^\[acked\]/,/^\[/ s/^\"\{0,1\}$sid\"\{0,1\}=\(-\{0,1\}[0-9][0-9]*\)$/\1/p" \
      "$dir/state.cfg" 2>/dev/null | head -n 1)"
    acked="${acked:--1}"
    n="$(jq -R 'fromjson? | objects | select(has("seq")) | .seq' "$f" | awk -v a="$acked" '$1 > a' | wc -l)"
    total=$((total + n))
  done
  echo "$total"
}

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/measure_stage_${LABEL}_XXXX")"
STAGE_T0="$(date +%s)"
echo "measure_stage: etapa '$LABEL' · $RUNS partidas · logs en $LOGS"

# --- partidas en paralelo ----------------------------------------------------------------------
declare -a PIDS=()
for n in $(seq 1 "$RUNS"); do
  [ "$n" -gt 1 ] && sleep "$SPACING_S"
  (
    t0="$(date +%s)"
    set +e
    BIOSPHERA_RUN_LABEL="$LABEL" BIOSPHERA_AUGUR_ROOT="$(root_uri "$n")" GODOT_MEM_MAX="$MEM_PER_RUN" \
      "$RUN_GODOT" "$RUN_LIMIT_S" --headless --path "$ROOT_DIR" --script res://tools/measure_run.gd \
      >"$LOGS/run_$n.log" 2>&1
    code=$?
    echo "$code $(( $(date +%s) - t0 ))" >"$LOGS/run_$n.result"
  ) &
  PIDS+=("$!")
  echo "measure_stage: partida $n lanzada ($(root_uri "$n"))"
done
for pid in "${PIDS[@]}"; do wait "$pid" || true; done

FAILED=0
echo "measure_stage: partidas (código · duración real · días · población final):"
for n in $(seq 1 "$RUNS"); do
  read -r code secs <"$LOGS/run_$n.result" || { code="?"; secs=0; }
  done_line="$(grep -a '\[measure_run\] año completo' "$LOGS/run_$n.log" | tail -n 1 || true)"
  days="$(sed -n 's/.*day_index=\([0-9]*\).*/\1/p' <<<"$done_line")"
  pop="$(sed -n 's/.*\(A=[0-9]* B=[0-9]*\).*/\1/p' <<<"$done_line")"
  printf '  partida %d: código %s · %dm%02ds · días %s · %s\n' \
    "$n" "$code" $((secs / 60)) $((secs % 60)) "${days:-?}" "${pop:-sin población final}"
  if [ "$code" != "0" ] || [ -z "$done_line" ]; then FAILED=1; fi
done

# --- pasada de subida --------------------------------------------------------------------------
declare -a UP_PIDS=()
declare -a UP_RUNS=()
for n in $(seq 1 "$RUNS"); do
  dir="$(root_dir "$n")"
  [ -d "$dir" ] || continue
  if [ "$(pending_events "$dir")" -eq 0 ]; then continue; fi
  [ "${#UP_PIDS[@]}" -gt 0 ] && sleep "$SPACING_S"
  BIOSPHERA_AUGUR_ROOT="$(root_uri "$n")" GODOT_MEM_MAX="$MEM_PER_RUN" \
    "$RUN_GODOT" "$UPLOAD_PASS_S" --headless --path "$ROOT_DIR" >"$LOGS/upload_$n.log" 2>&1 &
  UP_PIDS+=("$!")
  UP_RUNS+=("$n")
  echo "measure_stage: subida de $(root_uri "$n") lanzada ($(pending_events "$dir") eventos pendientes)"
done
# Cada arranque se para (TERM a su run_godot.sh, que para su scope) en cuanto su raíz no tiene
# nada pendiente; si no, run_godot.sh lo para al agotar UPLOAD_PASS_S.
while [ "${#UP_PIDS[@]}" -gt 0 ]; do
  sleep 5
  declare -a keep_pids=() keep_runs=()
  for i in "${!UP_PIDS[@]}"; do
    pid="${UP_PIDS[$i]}"
    n="${UP_RUNS[$i]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      continue
    fi
    if [ "$(pending_events "$(root_dir "$n")")" -eq 0 ]; then
      sleep 1   # deja que el SDK termine de guardar state.cfg
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" || true
      continue
    fi
    keep_pids+=("$pid")
    keep_runs+=("$n")
  done
  UP_PIDS=("${keep_pids[@]}")
  UP_RUNS=("${keep_runs[@]}")
  unset keep_pids keep_runs
done

LEFT=0
for n in $(seq 1 "$RUNS"); do
  dir="$(root_dir "$n")"
  [ -d "$dir" ] || continue
  p="$(pending_events "$dir")"
  if [ "$p" -eq 0 ]; then
    rm -rf -- "$dir"
    echo "measure_stage: $(root_uri "$n") subida entera; raíz borrada"
  else
    LEFT=1
    echo "measure_stage: $(root_uri "$n") conserva $p eventos sin subir; raíz NO borrada" >&2
  fi
done

total=$(( $(date +%s) - STAGE_T0 ))
echo "measure_stage: etapa '$LABEL' en $((total / 60))m$(printf '%02d' $((total % 60)))s reales · logs en $LOGS"
if [ "$FAILED" -ne 0 ] || [ "$LEFT" -ne 0 ]; then
  exit 1
fi
