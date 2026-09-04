#!/usr/bin/env bash
# Bring a service's RUNNING replicas up to the traefik.http.services.* labels
# that docker-compose.production.yml currently renders.
#
#   bash scripts/sync-service-labels.sh <service> < /dev/null
#
# This is the escape hatch assert_service_labels points at. It is NOT
# zero-downtime: --force-recreate replaces every replica of the service at once,
# so that host is briefly unavailable. That is the correct trade. The
# alternative -- rolling while the two generations disagree -- makes Traefik
# discard the service outright and 404 the host for the WHOLE rollout, which is
# longer and harder to diagnose. Once this has run, rolling deploys are
# zero-downtime again.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=SCRIPTDIR/lib/rollout.sh
source scripts/lib/rollout.sh

SERVICE="${1:?usage: sync-service-labels.sh <service>}"

echo ">>> current desired labels for ${SERVICE}:"
desired_service_labels "$SERVICE" | sed 's/^/    /'
echo ">>> recreating ${SERVICE} (brief outage on its host)"
docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$SERVICE"

if service_labels_match "$SERVICE"; then
  echo ">>> ${SERVICE}: labels now match"
else
  echo "ERROR: ${SERVICE} still does not match after a force-recreate." >&2
  echo "       The compose file and the running containers disagree for a" >&2
  echo "       reason a recreate cannot fix -- check IMAGE_TAG and .env are" >&2
  echo "       what you expect, then inspect the container labels by hand." >&2
  exit 1
fi
