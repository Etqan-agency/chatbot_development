#!/usr/bin/env bash
# Roll production back to a previous tag, using the same primitive as a deploy.
#   bash scripts/rollback.sh [image_tag] < /dev/null
# With no argument, rolls back to PREVIOUS from .release-state.
#
# Never touches db or redis. Schema is deliberately NOT reverted: under the
# expand/contract rule, release N's schema is compatible with release N-1's
# code, so reverting the images alone is correct.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=SCRIPTDIR/lib/rollout.sh
source scripts/lib/rollout.sh
# shellcheck source=SCRIPTDIR/lib/services.sh
source scripts/lib/services.sh

STATE_FILE=.release-state
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  TARGET=$(grep '^PREVIOUS=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
  [ -n "$TARGET" ] || { echo "no tag given and no PREVIOUS in ${STATE_FILE}" >&2; exit 2; }
  echo ">>> no tag given; using PREVIOUS=${TARGET}"
fi
export IMAGE_TAG="$TARGET"

# envval and smoke_probes come from services.sh.
DOMAIN="$(envval DOMAIN)"
[ -n "$DOMAIN" ] || { echo "DOMAIN is not set in .env" >&2; exit 1; }
MEDIA_PROBE_PATH="$(envval MEDIA_PROBE_PATH)"; MEDIA_PROBE_PATH="${MEDIA_PROBE_PATH:-probe/health.txt}"
SMOKE_CURL_EXTRA="${SMOKE_CURL_EXTRA:-}"

echo ">>> rolling back to ${TARGET}"
# Name the services explicitly. Only web, worker and dashboard interpolate
# IMAGE_TAG; a bare `pull` would also re-pull the pinned third-party images,
# which is slower and gives a rollback more ways to fail during an incident.
docker compose -f "$COMPOSE_FILE" pull web worker dashboard

# Unlike the deploy, rollback RECONCILES instead of refusing.
#
# roll_service will not touch a service that is not at its steady replica count,
# and the state that most often needs a rollback is precisely an interrupted
# roll that left a service at double replicas. Refusing here would block the
# recovery path with the condition it exists to recover from, mid-incident. So
# bring each service back to steady first -- loudly, never silently -- and then
# roll. The deploy path keeps the strict assertion: only rollback repairs.
#
# Both first, so a service that cannot be reconciled aborts before any rolling
# starts. After the pull, so a scale-up has the target image locally.
echo ">>> reconciling replica counts before rolling"
for spec in "${APP_SERVICES[@]}"; do
  read -r svc steady _ <<<"$spec"
  reconcile_service "$svc" "$steady"
done

# Consumers before producers, same as the deploy: a still-new web may dispatch
# messages the older worker must tolerate.
roll_worker worker 360

# Same table and roll order as the deploy; see scripts/lib/services.sh.
for spec in "${APP_SERVICES[@]}"; do
  # shellcheck disable=SC2086  # the spec is a deliberate word-split argument list
  roll_service $spec
done

echo ">>> verifying"
while IFS= read -r probe; do
  url=${probe%%|*}; want=${probe##*|}
  # shellcheck disable=SC2086  # SMOKE_CURL_EXTRA is a deliberate argument list
  got=$(curl -s -o /dev/null -m 15 -w '%{http_code}' $SMOKE_CURL_EXTRA "$url" || echo 000)
  echo "  ${url} -> ${got} (want ${want})"
  [ "$got" = "$want" ] || { echo "ERROR: rollback verification failed" >&2; exit 1; }
done < <(smoke_probes "$DOMAIN" "$MEDIA_PROBE_PATH")

current=$(grep '^CURRENT=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
{ echo "CURRENT=${TARGET}"; echo "PREVIOUS=${current}"; } > "$STATE_FILE"
echo ">>> rollback complete; CURRENT=${TARGET}"
