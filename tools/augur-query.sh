#!/usr/bin/env bash
# =============================================================================
# augur-query.sh — lectura de Augur con el usuario viewer de Claude, salida JSON
# =============================================================================
# Uso:
#   tools/augur-query.sh <acción> ['<json con los campos extra>']
#   tools/augur-query.sh board.list
#   tools/augur-query.sh session.list '{"limit": 20}'
#   tools/augur-query.sh chart.query '{"definition": {...ChartDefinition v1...}, "filters": {"from": "2026-10-01", "to": "2026-10-03"}}'
#
# Hace `auth.login` con las credenciales de ~/.config/augur/claude-viewer.env (fuera del repo, 600:
# AUGUR_ENDPOINT, AUGUR_VIEWER_EMAIL, AUGUR_VIEWER_PASSWORD), resuelve el id del proyecto
# (`biosphera`, o AUGUR_PROJECT) y envía {action, project_id, …extra}. Imprime la respuesta JSON tal
# cual y sale ≠ 0 si el HTTP no es 200. El usuario es **viewer**: solo acciones de lectura
# (`board.*` de lectura, `chart.query`, `session.list/get/facets`, `catalog.list`…); cualquier
# escritura devuelve 403. La cookie va a un temporal que se borra al salir.
# Necesita curl y jq.
# =============================================================================

set -euo pipefail

CRED="${AUGUR_VIEWER_CRED:-$HOME/.config/augur/claude-viewer.env}"
SLUG="${AUGUR_PROJECT:-biosphera}"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
ACTION="$1"
EXTRA="${2:-{\}}"
jq -e 'type == "object"' <<<"$EXTRA" >/dev/null 2>&1 || { echo "El segundo argumento no es un objeto JSON" >&2; exit 2; }
[ -r "$CRED" ] || { echo "Faltan las credenciales en $CRED" >&2; exit 1; }

# shellcheck disable=SC1090
. "$CRED"
API="${AUGUR_ENDPOINT%/}/index.php"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
JAR="$WORK/cookies"

call () {
  local body="$WORK/body" rc=0
  cat > "$body"
  curl -sS -o "$WORK/resp" -w '%{http_code}' -b "$JAR" -c "$JAR" \
    --connect-timeout 10 --retry 4 --retry-delay 1 --retry-all-errors \
    -H 'Content-Type: application/json' --data-binary @"$body" "$API" || rc=$?
  rm -f "$body"
  return "$rc"
}

CODE="$(jq -n --arg e "$AUGUR_VIEWER_EMAIL" --arg p "$AUGUR_VIEWER_PASSWORD" \
  '{action: "auth.login", email: $e, password: $p}' | call)"
unset AUGUR_VIEWER_PASSWORD
[ "$CODE" = "200" ] || { echo "Login fallido (HTTP $CODE): $(cat "$WORK/resp")" >&2; exit 1; }
trap 'echo "{\"action\":\"auth.logout\"}" | call >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

CODE="$(echo '{"action":"project.list"}' | call)"
[ "$CODE" = "200" ] || { echo "project.list falló (HTTP $CODE): $(cat "$WORK/resp")" >&2; exit 1; }
PID="$(jq -r --arg s "$SLUG" '.projects[] | select(.slug == $s) | .id' "$WORK/resp")"
[ -n "$PID" ] || { echo "El viewer no ve el proyecto '$SLUG'" >&2; exit 1; }

CODE="$(jq -c --arg a "$ACTION" --argjson pid "$PID" '{action: $a, project_id: $pid} + .' <<<"$EXTRA" | call)"
cat "$WORK/resp"
echo
[ "$CODE" = "200" ] || { echo "$ACTION: HTTP $CODE" >&2; exit 1; }
