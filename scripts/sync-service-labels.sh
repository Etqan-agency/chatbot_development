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
# shellcheck source=SCRIPTDIR/lib/services.sh
source scripts/lib/services.sh

SERVICE="${1:?usage: sync-service-labels.sh <service>}"

# Pin the tag BEFORE running any compose command.
#
# --force-recreate replaces every replica of the service. Without an exported
# IMAGE_TAG, compose interpolates it from the server's .env, where it is
# `latest` per .env.example -- and ci.yml pushes `type=raw,value=latest` on
# every build of main. So this script, the documented remedy for label drift,
# would silently replace the running RELEASE with the newest unreleased main
# build, possibly one whose migrations have not been applied. deploy.sh and
# rollback.sh both export IMAGE_TAG; so must this.
#
# Refuse rather than default. There is no safe fallback here: `latest` is the
# specific wrong answer, and guessing any other tag would be worse than making
# the operator name one. This check runs first so a refusal touches nothing.
# An explicit IMAGE_TAG in the environment wins, so an operator whose
# .release-state is missing or wrong can still run this by naming the tag.
IMAGE_TAG="${IMAGE_TAG:-$(release_current)}"
if [ -z "$IMAGE_TAG" ]; then
  echo "ERROR: cannot determine the deployed release tag." >&2
  echo "       ${STATE_FILE:-.release-state} is missing, empty, or has no CURRENT= line." >&2
  echo "       Refusing to recreate ${SERVICE}: without an explicit tag, compose" >&2
  echo "       would read IMAGE_TAG from .env (\`latest\`) and replace the running" >&2
  echo "       release with the newest build of main." >&2
  echo "       Re-run with the deployed tag named explicitly:" >&2
  echo "         IMAGE_TAG=<deployed-tag> bash scripts/sync-service-labels.sh ${SERVICE}" >&2
  exit 1
fi
export IMAGE_TAG
echo ">>> recreating at the deployed release tag IMAGE_TAG=${IMAGE_TAG}"

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
