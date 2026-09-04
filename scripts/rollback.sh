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

# Traefik service-label parity: WARN, never refuse.
#
# deploy.sh asserts this and aborts, because no later gate can catch it: Traefik
# discards a service whose containers declare different traefik.http.services.*
# definitions, and the damage is done the moment roll_service CREATES the second
# generation -- before anything can be health-probed. That cost three minutes of
# API downtime on 2026-08-19.
#
# A rollback is where drift is MOST likely, not least: cd.yml rsyncs the new
# docker-compose.production.yml to the server BEFORE deploy.sh runs, so a deploy
# that failed after the sync leaves new compose beside old containers -- exactly
# the disagreement this detects.
#
# It still must not refuse. Refusing would block the recovery path with a
# condition rollback exists to recover from, mid-incident -- the same reasoning
# that makes this script reconcile replica counts instead of asserting them.
# Rolling into a discarded service is bad; having no way back at all is worse.
# So: say it loudly, name the remedy, and continue.
echo ">>> checking service-label parity (advisory; a rollback never refuses)"
label_drift=false
for spec in "${APP_SERVICES[@]}"; do
  read -r svc _ <<<"$spec"
  if service_labels_match "$svc"; then
    echo "  ${svc}: service labels match"
  else
    label_drift=true
    echo "WARNING: ${svc}'s running replicas carry different" >&2
    echo "         traefik.http.services.* labels than ${COMPOSE_FILE} renders." >&2
  fi
done
if [ "$label_drift" = true ]; then
  echo "WARNING: ==================================================" >&2
  echo "WARNING: rolling with this drift makes Traefik discard the" >&2
  echo "WARNING: affected service, which 404s its host for the WHOLE" >&2
  echo "WARNING: rollback. Continuing anyway -- a rollback must never" >&2
  echo "WARNING: refuse -- but if the verification below fails with" >&2
  echo "WARNING: 404s, this is why. The fix (brief outage on that host):" >&2
  echo "WARNING:   bash scripts/sync-service-labels.sh <service>" >&2
  echo "WARNING: ==================================================" >&2
fi

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
  # `|| true`, not `|| echo 000`: curl already prints 000 on a connection
  # failure AND exits non-zero, so `|| echo 000` yields the string "000000".
  # It still fails the comparison, but it reads as a bug in the probe.
  got=$(curl -s -o /dev/null -m 15 -w '%{http_code}' $SMOKE_CURL_EXTRA "$url" || true)
  echo "  ${url} -> ${got} (want ${want})"
  [ "$got" = "$want" ] || { echo "ERROR: rollback verification failed" >&2; exit 1; }
done < <(smoke_probes "$DOMAIN" "$MEDIA_PROBE_PATH")

current=$(grep '^CURRENT=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)

# Do NOT set PREVIOUS to the old CURRENT when the old CURRENT *is* the target.
#
# This is the NORMAL path, not an edge case: deploy.sh's auto-rollback picks
# CURRENT as its target precisely because .release-state has not been advanced
# yet, so every automatic rollback arrives here with TARGET == CURRENT. Writing
# PREVIOUS=CURRENT there would collapse both fields onto the same tag and make
# the release before it unreachable:
#
#   CURRENT=v2 PREVIOUS=v1, a v3 deploy fails smoke, rollback target is v2
#     -> naive write: CURRENT=v2 PREVIOUS=v2, and v1 is gone from the file.
#
# The operator, still in the incident, then opens Actions -> Rollback with a
# blank tag, which resolves to PREVIOUS=v2 -- the release already serving. The
# run rolls to what is already there, the verification passes, and they get a
# green run that changed nothing while the site is still broken.
#
# Preserving the existing PREVIOUS keeps the history honest: after rolling to
# v2 the state is CURRENT=v2 PREVIOUS=v1, so a blank-tag manual rollback goes
# one further back, which is what "roll back again" has to mean.
if [ "$TARGET" = "$current" ]; then
  previous=$(grep '^PREVIOUS=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
else
  previous="$current"
fi
{ echo "CURRENT=${TARGET}"; echo "PREVIOUS=${previous}"; } > "$STATE_FILE"
echo ">>> rollback complete; CURRENT=${TARGET} PREVIOUS=${previous}"
