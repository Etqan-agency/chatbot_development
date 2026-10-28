#!/usr/bin/env bash
# Production deploy. Run ON the server, from ${DEPLOY_PATH}:
#   bash scripts/deploy.sh <image_tag> [--skip-backup] [--dry-run] [--skip-pull] < /dev/null
#
# This exists as a transferred script rather than an inline SSH heredoc because
# a heredoc is read from stdin: any command that also reads stdin swallows the
# rest of the script, and the deploy stops silently while reporting success.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=SCRIPTDIR/lib/rollout.sh
source scripts/lib/rollout.sh
# shellcheck source=SCRIPTDIR/lib/services.sh
source scripts/lib/services.sh

IMAGE_TAG="${1:?usage: deploy.sh <image_tag> [--skip-backup] [--dry-run] [--skip-pull]}"
shift || true
SKIP_BACKUP=false; DRY_RUN=false; SKIP_PULL=false
for arg in "$@"; do
  case "$arg" in
    --skip-backup) SKIP_BACKUP=true ;;
    --dry-run)     DRY_RUN=true ;;
    # For rehearsals against locally-built images, and for re-running a deploy
    # whose images are already on the host after a mid-deploy abort. CD never
    # passes it: a production deploy must prove the tag exists in the registry.
    --skip-pull)   SKIP_PULL=true ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
export IMAGE_TAG
STATE_FILE=.release-state

# The smoke checks need the deployed hostnames, which live in the server's .env
# (hand-written at provisioning, never in Git). envval and smoke_probes come
# from services.sh, so a rollback reads the same values through the same code.
#
# Two independent keys, not a base domain: this host's names share a parent by
# coincidence, and `etqanbackend.tech` belongs to several other servers.
API_HOST="$(envval API_HOST)"
APP_HOST="$(envval APP_HOST)"
[ -n "$API_HOST" ] || { echo "API_HOST is not set in .env" >&2; exit 1; }
[ -n "$APP_HOST" ] || { echo "APP_HOST is not set in .env" >&2; exit 1; }
MEDIA_PROBE_PATH="$(envval MEDIA_PROBE_PATH)"
MEDIA_PROBE_PATH="${MEDIA_PROBE_PATH:-probe/health.txt}"
# Set during a local rehearsal to e.g. "-k --resolve api.chatbot.local:443:127.0.0.1".
# Empty in production, where the hostnames resolve and the certificate is real.
SMOKE_CURL_EXTRA="${SMOKE_CURL_EXTRA:-}"

echo "=========================================="
echo "Deploy ${IMAGE_TAG}  skip_backup=${SKIP_BACKUP}  dry_run=${DRY_RUN}  skip_pull=${SKIP_PULL}"
echo "=========================================="

echo ">>> preflight"
[ -f "$COMPOSE_FILE" ] || { echo "missing $COMPOSE_FILE" >&2; exit 1; }
[ -f .env ] || { echo "missing .env" >&2; exit 1; }
[ -f media/nginx.conf ] || { echo "missing media/nginx.conf (bind-mounted by the media service)" >&2; exit 1; }
[ -f traefik/traefik.yml ] || { echo "missing traefik/traefik.yml" >&2; exit 1; }
avail_mb=$(free -m | awk '/Mem:/ {print $7}')
[ "$avail_mb" -ge 1200 ] || { echo "only ${avail_mb}MiB available; refusing" >&2; exit 1; }
echo "available memory: ${avail_mb}MiB"
assert_edge_publication || exit 1
echo "traefik publishes 80 and 443 to the world"

# Before the API check below, deliberately: a stale traefik.yml is a common
# CAUSE of that check failing, and "your gateway is running last week's config"
# is a far more useful thing to be told than "the API is unreachable".
assert_gateway_config_applied traefik/traefik.yml || exit 1
echo "traefik is running its current static configuration"

# There is no host-vhost drift check here any more, and nothing is missing.
#
# It existed because the host nginx's vhosts lived outside DEPLOY_PATH, were
# root-owned, and so could not be deployed by CD -- they were kept in step with
# docs/nginx/ by hand, and drifted silently when they were not. Traefik owns
# the edge now: its entire configuration is traefik/ and the compose labels,
# both of which CD syncs and both of which drift loudly. There is no
# hand-maintained copy left to disagree with.
#
# The rolling swap health-gates on Traefik's API. That API is enabled by a
# traefik.yml change that does NOT hot-reload -- it needs a manual container
# restart. Without this check the deploy would get all the way past migrate and
# the worker roll before wait_backends_up timed out 120s per service, leaving
# web mid-rollout. Fail here, before anything has changed.
if [ -z "$(traefik_backends_up web)" ]; then
  echo "ERROR: Traefik's API reported no backends for web." >&2
  echo "       Most likely traefik/traefik.yml's API change has not been applied:" >&2
  echo "       it is static config and does NOT hot-reload. On the server run:" >&2
  echo "         docker compose -f ${COMPOSE_FILE} up -d --no-deps --force-recreate traefik" >&2
  echo "       (container ${TRAEFIK_CONTAINER}, API ${TRAEFIK_API})" >&2
  exit 1
fi
echo "traefik API reachable; web backends registered"

# Every roll_service call below refuses unless the service is at exactly its
# steady replica count. Prove that for ALL of them here, while the system is
# still untouched -- otherwise a dashboard left at the wrong count by an
# interrupted run aborts the deploy only after the backup, collectstatic,
# migrate, the worker roll and the whole web roll, leaving the new schema and a
# new web live against an old dashboard with no automatic remedy.
#
# The deploy deliberately does NOT repair this itself: a silent repair would
# hide the interruption. Reconciling is the rollback path's job (and the
# operator's -- the command is in the message and in docs/DEPLOY.md).
echo ">>> checking replica counts"
assert_steady_replicas "${APP_SERVICES[@]}" || exit 1

# Traefik discards a service whose containers declare different service
# definitions, and a roll runs two generations at once -- so a deploy that
# changes a traefik.http.services.* label would 404 that host for the whole
# rollout. Detected here, before anything is created; no later gate can see it.
echo ">>> checking service-label parity"
assert_service_labels "${APP_SERVICES[@]}" || exit 1

if [ "$SKIP_PULL" != true ]; then
  echo ">>> pulling images"
  docker compose -f "$COMPOSE_FILE" pull
else
  echo ">>> skipping pull (--skip-pull)"
fi

if [ "$DRY_RUN" = true ]; then echo ">>> dry run: images pulled, stopping here"; exit 0; fi

# Data tier: ensure up, NEVER recreate. Recreating postgres drops every
# connection held by the running web and worker containers.
echo ">>> data tier (no recreate)"
docker compose -f "$COMPOSE_FILE" up -d --no-recreate db redis
for i in $(seq 1 30); do
  if docker compose -f "$COMPOSE_FILE" exec -T db pg_isready </dev/null >/dev/null 2>&1; then
    echo "postgres ready"; break
  fi
  [ "$i" -eq 30 ] && { echo "postgres never became ready" >&2; exit 1; }
  sleep 2
done

echo ">>> socket proxy and media"
docker compose -f "$COMPOSE_FILE" up -d --no-deps socket-proxy media

if [ "$SKIP_BACKUP" != true ]; then
  # pgvector/pgvector:pg16 is the stock Postgres image and has no `backup`
  # helper script, so this is a plain pg_dump into the pgbackups volume. Run
  # inside the container: the volume is not mounted anywhere else.
  echo ">>> database backup"
  pg_user="$(envval POSTGRES_USER)"; pg_user="${pg_user:-chatbot}"
  pg_db="$(envval POSTGRES_DB)";     pg_db="${pg_db:-chatbot}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  #
  # `set -o pipefail` is what makes the failure branch below reachable at all.
  # Without it the pipeline's exit status is gzip's, and gzip succeeds on empty
  # input -- so a pg_dump that fails outright still exits 0 and leaves a valid,
  # restorable-looking 20-byte archive. The old `|| echo "WARNING: backup
  # failed"` could therefore never fire, and the retention line underneath
  # would rotate a REAL backup out to make room for the empty one. Two deploys
  # against a broken dump and the newest genuine backup is gone.
  #
  # `bash -c`, not `sh -c`: `sh` in this image is dash, which only gained
  # pipefail in 0.5.12 (2022). On anything older `set -o pipefail` is itself an
  # error and EVERY backup would report failure -- the same silent-wrong-answer
  # bug with the sign flipped. The image is built on postgres:16, which is
  # Debian-based and ships bash, so bash is the one that is actually guaranteed.
  #
  # The partial archive is removed on failure: a truncated .sql.gz that lists
  # fine in the retention loop is worse than no file, because it is what an
  # operator reaches for during a restore.
  backup_file="/backups/${pg_db}-${stamp}.sql.gz"
  if docker compose -f "$COMPOSE_FILE" exec -T db \
       bash -c "set -o pipefail; pg_dump -U '${pg_user}' -d '${pg_db}' | gzip > '${backup_file}'" \
       </dev/null; then
    echo "backup written to ${backup_file}"
  else
    echo "WARNING: backup failed; removing the partial archive ${backup_file}" >&2
    docker compose -f "$COMPOSE_FILE" exec -T db \
      bash -c "rm -f '${backup_file}'" </dev/null || true
  fi
  # Keep the last 14. Deleting oldest-first by name works because the stamp is
  # ISO-8601 basic and therefore lexicographically ordered.
  docker compose -f "$COMPOSE_FILE" exec -T db \
    sh -c 'ls -1 /backups/*.sql.gz 2>/dev/null | head -n -14 | xargs -r rm -f' \
    </dev/null || true
fi

# -l traefik.enable=false: a one-off `compose run` container inherits its
# service's labels, so without this it joins the web backend pool with nothing
# listening on :8000 and Traefik 502s a share of traffic.
echo ">>> collectstatic (before the swap: hashed names let old and new coexist)"
docker compose -f "$COMPOSE_FILE" run --rm --no-deps -l traefik.enable=false -T \
  web python manage.py collectstatic --noinput </dev/null

echo ">>> migrate"
docker compose -f "$COMPOSE_FILE" run --rm --no-deps -l traefik.enable=false -T \
  web python manage.py migrate --noinput </dev/null

# Write the media smoke probe through `web` (which mounts media_volume rw) so
# the smoke check reads it back through `media` (which mounts it ro). That makes
# the probe prove the shared volume, not just that nginx is up -- and /media/ is
# the one route that silently regressed when the all-in-one nginx was replaced.
echo ">>> media probe object"
docker compose -f "$COMPOSE_FILE" run --rm --no-deps -l traefik.enable=false -T \
  web sh -c "mkdir -p \"\$(dirname /app/media/${MEDIA_PROBE_PATH})\" && printf ok > /app/media/${MEDIA_PROBE_PATH}" </dev/null

# Consumers before producers: web dispatches Celery messages, and a new producer
# can send a kwarg an old consumer's signature rejects.
echo ">>> rolling worker"
roll_worker worker 360

# Same table the preflight asserted against, in roll order. Per-service steady
# counts, stop timeouts and drainability are documented in scripts/lib/services.sh.
for spec in "${APP_SERVICES[@]}"; do
  # shellcheck disable=SC2086  # the spec is a deliberate word-split argument list
  roll_service $spec
done

echo ">>> smoke checks"
smoke_failed=false
# Process substitution, not a pipe: a pipe would run the loop in a subshell and
# smoke_failed would never escape it, so every failed deploy would look clean.
while IFS= read -r probe; do
  url=${probe%%|*}; rest=${probe#*|}
  want=${rest%%|*}
  # Third field is the Host header, present only on the :80 redirect probes.
  # When
  # the probe has only two fields, `rest` has no second `|` and `${rest#*|}`
  # returns `rest` unchanged -- hence the equality test rather than a -z test.
  host=${rest#*|}; [ "$host" = "$want" ] && host=""
  host_arg=(); [ -n "$host" ] && host_arg=(-H "Host: ${host}")
  # `|| true`, not `|| echo 000`: curl already prints 000 on a connection
  # failure AND exits non-zero, so `|| echo 000` yields the string "000000".
  # shellcheck disable=SC2086  # SMOKE_CURL_EXTRA is a deliberate argument list
  got=$(curl -s -o /dev/null -m 15 -w '%{http_code}' $SMOKE_CURL_EXTRA "${host_arg[@]}" "$url" || true)
  printf '  %-58s -> %s (want %s)\n' "${url}${host:+  [Host: $host]}" "$got" "$want"
  [ "$got" = "$want" ] || smoke_failed=true
done < <(smoke_probes "$API_HOST" "$APP_HOST" "$MEDIA_PROBE_PATH")

if [ "$smoke_failed" = true ]; then
  # Roll back to CURRENT, not PREVIOUS.
  #
  # .release-state is deliberately not written until the smoke checks pass, so
  # while this deploy is failing the file still describes the PREVIOUS release:
  # its CURRENT is the tag that was serving before this run started, and its
  # PREVIOUS is the one before that. Reading PREVIOUS here is off by one
  # release, and wrong in two distinct ways:
  #
  #   * After the very first deploy the file is `CURRENT=v1 PREVIOUS=`, so a
  #     failing second deploy finds nothing to roll back to and leaves the
  #     broken release serving -- with a known-good tag sitting in the file.
  #   * After `CURRENT=v2 PREVIOUS=v1`, a failing v3 rolls back to v1, skipping
  #     v2 entirely. The expand/contract rule that makes an image-only rollback
  #     safe holds for ONE release, so v1's code would then run against v3's
  #     migrated schema -- the exact hazard rollback.sh says cannot happen.
  #
  # The PREVIOUS fallback stays for the case where a hand-edited or partially
  # written state file has no CURRENT.
  rollback_target=$(grep '^CURRENT=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
  [ -n "$rollback_target" ] || \
    rollback_target=$(grep '^PREVIOUS=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
  echo "ERROR: smoke checks failed." >&2
  if [ -n "$rollback_target" ]; then
    # No announcement here: rollback.sh prints its own ">>> rolling back to
    # ${TARGET}" as its first line, so echoing the same text again would just
    # duplicate it -- and duplicate output on the one path that decides
    # whether a bad release keeps serving is exactly the kind of noise that
    # makes an incident harder to read, not easier.
    bash scripts/rollback.sh "$rollback_target" </dev/null
  else
    echo "No usable tag in ${STATE_FILE}; manual intervention required." >&2
  fi
  exit 1
fi

# Recorded only after smoke checks pass, so PREVIOUS is always a tag that was
# observed serving traffic.
prev_current=$(grep '^CURRENT=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
{ echo "CURRENT=${IMAGE_TAG}"; echo "PREVIOUS=${prev_current}"; } > "$STATE_FILE"
echo ">>> release state: CURRENT=${IMAGE_TAG} PREVIOUS=${prev_current}"

docker image prune -f >/dev/null
echo "=========================================="
echo "Deploy complete"
docker compose -f "$COMPOSE_FILE" ps
