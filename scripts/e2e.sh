#!/usr/bin/env bash
# End-to-end deploy/rollback rehearsal against a real local stack.
#
#   bash scripts/e2e.sh [--keep] [--fast] [--purge]
#
# WHAT IS REAL HERE, and why that is the point:
#
#   real: docker-compose.production.yml, traefik/traefik.yml,
#         traefik/dynamic/middlewares.yml, media/nginx.conf, docs/nginx/*.conf,
#         scripts/deploy.sh, scripts/rollback.sh, scripts/lib/*, postgres,
#         redis, traefik, the socket proxy, and a host-network nginx standing
#         in for the server's edge.
#   stand-in: ONLY the two application images (scripts/e2e/*-standin). They are
#         built and tagged as ghcr.io/etqan-agency/chatbot/{api,dashboard} so
#         the compose file runs BYTE-FOR-BYTE UNMODIFIED against them, and they
#         implement the contract the compose file and services.sh demand -- a
#         drain-aware /health/, a manage.py, a warm-shutdown celery.
#
# scripts/lib/rollout.test.sh stubs `docker` and proves the primitives in
# isolation. This proves the things a stub cannot: that Traefik really
# host-routes to these labels, that the drain gate really removes a backend,
# that a roll really serves continuously, that `pg_dump | gzip` really reports
# its failures, and that the vhosts we ship really parse.
#
# COST AND BLAST RADIUS -- read before running locally:
#   * The compose project name is pinned to `chatbot` and cannot be changed for
#     this run: rollout.sh matches containers by the `chatbot-` prefix and execs
#     into `chatbot-traefik-1`, and traefik.yml names the `chatbot_default`
#     network. So this uses the SAME project as a local stack, and it refuses to
#     start while any container of that project exists.
#   * It binds host ports 80, 443 and 127.0.0.1:8081.
#   * Teardown removes the containers but KEEPS the named volumes. It therefore
#     runs against whatever `chatbot_pgdata` already holds, and its backups land
#     in the existing `chatbot_pgbackups` -- where deploy.sh's own 14-file
#     retention sweep can rotate older archives out. Pass --purge for a `down
#     -v` instead, which is hermetic but DESTROYS those volumes.
#   * deploy.sh ends with `docker image prune -f`, which removes dangling
#     images belonging to anything else on this machine.
#   * Never point any of this at a server.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"

KEEP=false; FAST=false; PURGE=false
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=true ;;
    # Destroy the named volumes on teardown as well. Off by default: the
    # project name is shared with whatever local stack already exists, so the
    # volumes this would delete are not necessarily this run's.
    --purge) PURGE=true ;;
    # Shortens the drain settle window. Kept honest: still longer than
    # Traefik's 5s healthcheck interval, so the drain is genuinely observed
    # rather than skipped. Below that the roll would stop proving anything.
    --fast) FAST=true ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL - %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; fi
}
note() { printf '\n=== %s\n' "$1"; }

IMAGE_API=ghcr.io/etqan-agency/chatbot/api
IMAGE_DASH=ghcr.io/etqan-agency/chatbot/dashboard
COMPOSE=docker-compose.production.yml
EDGE=chatbot-e2e-edge
WORK=""

# --- teardown ---------------------------------------------------------------
cleanup() {
  local rc=$?
  if [ "$KEEP" = true ]; then
    echo; echo "--keep: leaving the stack up. Work dir: ${WORK}"
    echo "  tear down with: docker rm -f ${EDGE}; (cd ${WORK} && docker compose -f ${COMPOSE} down)"
    return $rc
  fi
  echo; echo ">>> tearing down"
  docker rm -f "$EDGE" >/dev/null 2>&1 || true
  if [ -n "$WORK" ] && [ -f "$WORK/$COMPOSE" ]; then
    local down_args=(down --remove-orphans)
    [ "$PURGE" = true ] && down_args=(down -v --remove-orphans)
    ( cd "$WORK" && IMAGE_TAG=e2e-v1 docker compose -f "$COMPOSE" "${down_args[@]}" >/dev/null 2>&1 ) || true
  fi
  # Remove the stand-in images. They are tagged as the PRODUCTION repository
  # (that is what lets the compose file run unmodified), so leaving them on a
  # developer's machine leaves images that look like real releases and could be
  # pushed by accident. The layer cache survives, so a re-run rebuilds them in
  # seconds.
  for rel in e2e-v1 e2e-v2 e2e-v3; do
    docker rmi "${IMAGE_API}:${rel}" "${IMAGE_DASH}:${rel}" >/dev/null 2>&1 || true
  done
  [ -n "$WORK" ] && rm -rf "$WORK"
  return $rc
}
trap cleanup EXIT

# --- 0. preflight -----------------------------------------------------------
note "0. preflight"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose v2 is required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required (self-signed edge certificate)" >&2; exit 1; }

existing=$(docker ps -aq --filter "label=com.docker.compose.project=chatbot" | wc -l)
if [ "$existing" -ne 0 ]; then
  echo "ERROR: ${existing} container(s) of the \`chatbot\` compose project already exist." >&2
  echo "       This rehearsal must use that same project name -- rollout.sh matches" >&2
  echo "       containers by the \`chatbot-\` prefix and execs into chatbot-traefik-1 --" >&2
  echo "       so it would adopt and then replace them. Clear them first." >&2
  echo "       Containers only, volumes preserved:" >&2
  echo "         docker rm -f \$(docker ps -aq --filter label=com.docker.compose.project=chatbot)" >&2
  echo "       Or containers AND volumes (destroys chatbot_pgdata and friends):" >&2
  echo "         docker compose -f ${COMPOSE} down -v" >&2
  exit 1
fi
port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/${1}") 2>/dev/null; }

# The edge wants 80/443 -- those are the ports the shipped vhosts declare and
# the ones a server uses. A developer machine often has something else on them
# already, so fall back to a high pair rather than refusing: every URL and Host
# header stays identical either way, because the probes reach the fallback with
# `curl --connect-to` rather than by putting a port in the URL. Only the two
# `listen` lines differ from the shipped file, and only in the fallback case.
EDGE_HTTP=""; EDGE_HTTPS=""
for pair in "80 443" "8080 8443" "9080 9443" "18080 18443"; do
  # shellcheck disable=SC2086  # the pair is a deliberate word-split argument list
  set -- $pair
  if port_free "$1" && port_free "$2"; then EDGE_HTTP="$1"; EDGE_HTTPS="$2"; break; fi
done
if [ -z "$EDGE_HTTP" ]; then
  echo "ERROR: no candidate port pair is free for the edge nginx." >&2
  echo "       Tried 80/443, 8080/8443, 9080/9443, 18080/18443." >&2
  exit 1
fi
if [ "$EDGE_HTTP" = 80 ]; then
  echo "docker, openssl, ports 80/443 free, no competing chatbot project"
else
  echo "NOTE: 80/443 are in use, so the edge binds ${EDGE_HTTP}/${EDGE_HTTPS} instead."
  echo "      The vhosts' listen lines are rewritten to match; nothing else changes,"
  echo "      and every request still carries the production URL and Host header,"
  echo "      because the probes remap the transport with curl --connect-to."
fi

if docker volume inspect chatbot_pgdata >/dev/null 2>&1; then
  echo "NOTE: chatbot_pgdata already exists and will be REUSED -- this run is not"
  echo "      hermetic. Postgres ignores POSTGRES_PASSWORD on an initialised"
  echo "      volume, and deploy.sh's backup retention may rotate out archives"
  echo "      left by an earlier run. Pass --purge for a clean volume."
fi

# Hostnames come from the SHIPPED vhosts, not from a constant here: if
# .env.example and docs/nginx/ ever name different hosts, the deploy smoke
# checks would probe a name the edge does not serve. Assert they agree.
API_HOST=$(sed -n 's/^    server_name \(.*\);/\1/p' docs/nginx/api-chatbot-demo.conf | head -1)
APP_HOST=$(sed -n 's/^    server_name \(.*\);/\1/p' docs/nginx/app-chatbot-demo.conf | head -1)
env_api=$(sed -n 's/^API_HOST=//p' .env.example | head -1)
env_app=$(sed -n 's/^APP_HOST=//p' .env.example | head -1)
check "the api vhost and .env.example name the same host" "$env_api" "$API_HOST"
check "the app vhost and .env.example name the same host" "$env_app" "$APP_HOST"
[ -n "$API_HOST" ] && [ -n "$APP_HOST" ] || { echo "could not read server_name from the vhosts" >&2; exit 1; }

# The two vhosts must stay identical apart from the hostname and the one-line
# description. Their headers say "keep the two copies in sync by hand" and
# nothing else checks it -- so the copy that was NOT edited silently keeps the
# old, wrong reasoning. That is exactly how the IPv6 sorting argument came to
# name the wrong file in one of them.
# Substitute the short prefix, not the FQDN: the header abbreviates the
# hostname as `api-chatbot-demo...` in prose, which an FQDN substitution leaves
# untouched -- so the check would report drift on the exact sentence it exists
# to police. `1d` drops the one line that is legitimately different, each
# file's "chatbot API"/"chatbot dashboard" description.
drift=$(diff <(sed -e "s/api-chatbot-demo/HOST/g" -e '1d' docs/nginx/api-chatbot-demo.conf) \
             <(sed -e "s/app-chatbot-demo/HOST/g" -e '1d' docs/nginx/app-chatbot-demo.conf) | wc -l)
check "the two vhosts are in sync modulo the hostname" "0" "$drift"

# --- 1. build the stand-ins -------------------------------------------------
note "1. building stand-in images"
for rel in e2e-v1 e2e-v2 e2e-v3; do
  docker build -q --build-arg "RELEASE=${rel}" \
    -t "${IMAGE_API}:${rel}" scripts/e2e/api-standin >/dev/null
  docker build -q --build-arg "RELEASE=${rel}" \
    -t "${IMAGE_DASH}:${rel}" scripts/e2e/dashboard-standin >/dev/null
  echo "built ${rel}"
done

# --- 2. the deploy directory ------------------------------------------------
# A throwaway copy, never the working tree: deploy.sh writes .release-state and
# reads .env, and the real .env holds this project's actual secrets.
note "2. staging a deploy directory"
WORK=$(mktemp -d)
cp "$COMPOSE" "$WORK/"
cp -R traefik media scripts "$WORK/"
sed -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=e2e-not-a-secret/" \
    -e "s/^SECRET_KEY=.*/SECRET_KEY=e2e-not-a-secret/" \
    .env.example > "$WORK/.env"
printf 'CURRENT=e2e-v1\nPREVIOUS=\n' > "$WORK/.release-state"
MEDIA_PROBE_PATH=$(sed -n 's/^MEDIA_PROBE_PATH=//p' "$WORK/.env" | head -1)
MEDIA_PROBE_PATH="${MEDIA_PROBE_PATH:-probe/health.txt}"
echo "work dir: ${WORK}"

# --- 3. the edge: the REAL vhosts, uncommented, against a self-signed cert ---
note "3. edge nginx, from the shipped vhosts"
mkdir -p "$WORK/edge/conf.d" "$WORK/edge/letsencrypt" "$WORK/edge/www"
for host in "$API_HOST" "$APP_HOST"; do
  mkdir -p "$WORK/edge/letsencrypt/live/${host}"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$WORK/edge/letsencrypt/live/${host}/privkey.pem" \
    -out    "$WORK/edge/letsencrypt/live/${host}/fullchain.pem" \
    -subj "/CN=${host}" -addext "subjectAltName=DNS:${host}" >/dev/null 2>&1
done
for pair in "api-chatbot-demo api" "app-chatbot-demo app"; do
  # shellcheck disable=SC2086  # the pair is a deliberate word-split argument list
  set -- $pair
  bash scripts/e2e/uncomment-tls.sh "docs/nginx/${1}.conf" \
    | sed -e "s/^\( *\)listen 80;/\1listen ${EDGE_HTTP};/" \
          -e "s/^\( *\)listen 443 ssl http2;/\1listen ${EDGE_HTTPS} ssl http2;/" \
    > "$WORK/edge/conf.d/${2}.conf"
done
# Two listen lines per file, two files: the :80 block and the :443 block of
# each vhost must both have landed on the edge's ports, or the probes below
# would be reaching something other than what was rendered.
check "the rendered vhosts declare the edge's ports" "4" \
  "$(cat "$WORK"/edge/conf.d/*.conf | grep -cE "^ *listen (${EDGE_HTTP};|${EDGE_HTTPS} ssl)" || true)"

# NOTE what is deliberately ABSENT from $WORK/edge/letsencrypt: certbot's
# options-ssl-nginx.conf and ssl-dhparams.pem. Those are written by certbot's
# nginx INSTALLER, and the runbook issues certificates with `certonly
# --webroot`, which runs no installer -- so on a real host following that
# runbook they do not exist either. A vhost that `include`s them fails
# `nginx -t` here exactly as it would there. That is the regression this
# directory's emptiness encodes; do not "fix" it by adding the files.
installer_files=0
for f in "$WORK/edge/letsencrypt/options-ssl-nginx.conf" \
         "$WORK/edge/letsencrypt/ssl-dhparams.pem"; do
  [ -e "$f" ] && installer_files=$((installer_files + 1))
done
check "certbot's installer-only files are absent, as on a --webroot host" "0" "$installer_files"

docker run --rm -v "$WORK/edge/conf.d:/etc/nginx/conf.d:ro" \
  -v "$WORK/edge/letsencrypt:/etc/letsencrypt:ro" \
  nginx:alpine nginx -t >"$WORK/nginx-t.log" 2>&1
nginx_t_rc=$?
check "the shipped vhosts pass nginx -t with the :443 block enabled" "0" "$nginx_t_rc"
# Gated on THIS check, not the suite-wide counter: keyed off $FAIL it printed
# the log whenever anything earlier had failed, burying the real diagnostic.
[ "$nginx_t_rc" -eq 0 ] || { echo "--- nginx -t said:"; cat "$WORK/nginx-t.log"; }

docker run -d --name "$EDGE" --network host \
  -v "$WORK/edge/conf.d:/etc/nginx/conf.d:ro" \
  -v "$WORK/edge/letsencrypt:/etc/letsencrypt:ro" \
  -v "$WORK/edge/www:/var/www/html:ro" \
  nginx:alpine >/dev/null
echo "edge nginx up on :80/:443 (host network, so the vhosts' 127.0.0.1:8081 reaches Traefik)"

# --- helpers ----------------------------------------------------------------
# rollout.sh's own primitives, used here to OBSERVE the system rather than to
# drive it: traefik_backends_up is how the probe records what Traefik's pool
# looked like at the instant a request failed.
# shellcheck source=SCRIPTDIR/lib/rollout.sh
source "$WORK/scripts/lib/rollout.sh"

# `--connect-to`, not `--resolve`. --resolve can only remap the address for the
# port already in the URL, so it cannot reach an edge on 8443 without putting
# `:8443` into every URL -- which would change the Host header, the redirect
# target and the smoke probes' own URLs. --connect-to remaps address AND port
# while leaving the request exactly as production issues it.
CONNECT=(--connect-to "${API_HOST}:443:127.0.0.1:${EDGE_HTTPS}"
         --connect-to "${APP_HOST}:443:127.0.0.1:${EDGE_HTTPS}"
         --connect-to "${API_HOST}:80:127.0.0.1:${EDGE_HTTP}"
         --connect-to "${APP_HOST}:80:127.0.0.1:${EDGE_HTTP}")

# Status code and the serving generation, in one request. The release marker is
# what makes "the roll actually swapped generations" an observation instead of
# an inference from timing.
probe() { # probe <url> -> "<code> <release>"
  local out code rel
  out=$(curl -sk -m 10 -D - -o /dev/null "${CONNECT[@]}" "$1" 2>/dev/null)
  code=$(printf '%s' "$out" | sed -n 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | tail -1)
  rel=$(printf '%s' "$out" | sed -n 's/^[Xx]-[Ee]2[Ee]-[Rr]elease: *//p' | tr -d '\r' | tail -1)
  printf '%s %s' "${code:-000}" "${rel:-none}"
}

wait_for_200() { # wait_for_200 <url> <timeout>
  local waited=0
  while [ "$waited" -lt "$2" ]; do
    [ "$(probe "$1" | cut -d' ' -f1)" = "200" ] && return 0
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# A continuous availability probe, run in the background across a roll.
#
# It requests `/`, NOT `/health/`. During a drain the health route returns 503
# BY DESIGN -- that is how Traefik is told to remove the backend -- while the
# container keeps serving real traffic until it is stopped. Probing /health/
# would therefore measure the drain gate and report it as downtime.
# Sets PROBE_PID rather than echoing it. `pid=$(start_probe ...)` would hang
# forever: the backgrounded subshell inherits the write end of the command
# substitution's pipe, so `$( )` never sees EOF no matter where the loop sends
# its own output. Redirecting the job to /dev/null as well, so it holds no
# inherited descriptor at all.
start_probe() { # start_probe <name> <url>  -- sets PROBE_PID
  : > "$WORK/probe-$1.log"
  : > "$WORK/probe-$1-diag.log"
  ( while :; do
      line=$(probe "$2")
      printf '%s\n' "$line" >> "$WORK/probe-$1.log"
      # On a failure, snapshot what Traefik thought its pool was AT THAT
      # MOMENT. A count of dropped requests says a roll was not seamless; this
      # says whether the pool was empty (a gap in the rollout's own logic) or
      # populated (the request was routed to a backend that had already gone).
      # Sampled only on failure, so the probe's own rate is undisturbed while
      # things are healthy.
      case "$line" in
        200\ *) ;;
        *) printf '%s %s | web=[%s] dashboard=[%s]\n' "${EPOCHREALTIME:-?}" "$line" \
             "$(traefik_backends_up web  | tr '\n' ' ')" \
             "$(traefik_backends_up dashboard | tr '\n' ' ')" \
             >> "$WORK/probe-$1-diag.log" ;;
      esac
      sleep 0.1
    done ) >/dev/null 2>&1 &
  PROBE_PID=$!
}

# The drain settle window. The production default is 15s (three of Traefik's
# 5s healthcheck intervals); --fast halves it but stays above one interval, so
# the drain is still genuinely observed rather than skipped. Anything shorter
# would turn the zero-downtime assertion below into a coin flip and the roll
# into the abrupt stop the drain exists to replace.
if [ "$FAST" = true ]; then export DRAIN_SETTLE_SECS=7; else export DRAIN_SETTLE_SECS=15; fi
export HEALTH_TIMEOUT_SECS=90 BACKEND_TIMEOUT_SECS=60
export SMOKE_CURL_EXTRA="-k --connect-to ${API_HOST}:443:127.0.0.1:${EDGE_HTTPS} --connect-to ${APP_HOST}:443:127.0.0.1:${EDGE_HTTPS}"

# --- 4. first bring-up, by hand (DEPLOY.md step 8) --------------------------
note "4. bringing the stack up at e2e-v1"
cd "$WORK" || exit 1
IMAGE_TAG=e2e-v1 docker compose -f "$COMPOSE" up -d --wait --wait-timeout 180 >/dev/null 2>&1
check "the stack comes up at e2e-v1" "0" "$?"
IMAGE_TAG=e2e-v1 docker compose -f "$COMPOSE" run --rm --no-deps -l traefik.enable=false -T \
  web sh -c "mkdir -p \"\$(dirname /app/media/${MEDIA_PROBE_PATH})\" && printf ok > /app/media/${MEDIA_PROBE_PATH}" \
  </dev/null >/dev/null 2>&1

wait_for_200 "https://${API_HOST}/" 90
wait_for_200 "https://${APP_HOST}/" 90
check "the api host serves through the edge" "200 e2e-v1" "$(probe "https://${API_HOST}/")"
check "the app host serves through the edge" "200 e2e-v1" "$(probe "https://${APP_HOST}/")"
check "the api health route is 200 when not draining" "200" \
  "$(probe "https://${API_HOST}/health/" | cut -d' ' -f1)"

# The media router carries priority=100 so PathPrefix beats the api catch-all
# on the same host. Nothing else in the pipeline exercises it, and /media/ is
# the route that silently regressed when the all-in-one nginx was replaced.
check "the media router wins on the api host" "200" \
  "$(probe "https://${API_HOST}/media/${MEDIA_PROBE_PATH}" | cut -d' ' -f1)"
check "media is served by the media container, not web" "none" \
  "$(probe "https://${API_HOST}/media/${MEDIA_PROBE_PATH}" | cut -d' ' -f2)"

# The :80 block's redirect lives in `location /`, not at server level, so that
# it cannot swallow the ACME challenge. Both halves are asserted: a plain path
# must redirect, and the challenge path must NOT -- a server-level `return 301`
# passes the first and fails the second, and every renewal would then fail.
check "http redirects to https" "301" \
  "$(curl -s -o /dev/null -w '%{http_code}' "${CONNECT[@]}" "http://${API_HOST}/some/path")"
check "the ACME challenge path is NOT redirected" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' "${CONNECT[@]}" \
     "http://${API_HOST}/.well-known/acme-challenge/probe")"

# Traefik must be reachable on loopback only. assert_loopback_publication
# proves the binding; this proves the binding does what it claims.
check "the gateway answers on loopback with a Host header" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${API_HOST}" http://127.0.0.1:8081/)"

# --- 5. the drain gate ------------------------------------------------------
# services.sh marks `web` drainable=true, and retire_container's settle window
# is worthless unless a drained replica really leaves the pool. Asserted
# directly rather than inferred from a roll.
note "5. drain gate"
victim=$(docker ps --format '{{.Names}}' | grep -E '^chatbot-web-[0-9]+$' | head -1)
check "a web replica was found to drain" "1" "$([ -n "$victim" ] && echo 1 || echo 0)"
docker exec -i "$victim" sh -c 'touch /tmp/drain' </dev/null
check "a draining replica fails its own health route" "503" \
  "$(docker exec -i "$victim" wget -qS -O /dev/null http://127.0.0.1:8000/health/ 2>&1 </dev/null \
     | sed -n 's/.*HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | head -1)"

# The assertion is that the drained replica leaves the UP SET -- not that it
# appears as DOWN. Those are different claims: Traefik may represent a failed
# server either way, and wait_backends_up (the thing roll_service actually
# gates on) counts UP entries, so the UP set is the property that matters.
# Asserting on a DOWN entry made this fail against a healthy system.
waited=0; up_now=2
while [ "$waited" -lt 40 ]; do
  up_now=$(traefik_backends_up web | grep -c ' UP$' || true)
  [ "$up_now" -le 1 ] && break
  sleep 2; waited=$((waited + 2))
done
check "the drained replica leaves the UP set" "1" "$up_now"
check "the host still serves while a replica is drained" "200" \
  "$(probe "https://${API_HOST}/" | cut -d' ' -f1)"

docker exec -i "$victim" sh -c 'rm -f /tmp/drain' </dev/null
waited=0; up=0
while [ "$waited" -lt 30 ]; do
  up=$(traefik_backends_up web | grep -c ' UP$' || true)
  [ "$up" -ge 2 ] && break
  sleep 2; waited=$((waited + 2))
done
check "the replica returns to the pool once undrained" "2" "$up"

# --- 6. the rolling deploy --------------------------------------------------
note "6. rolling deploy e2e-v1 -> e2e-v2, under continuous load"
start_probe api "https://${API_HOST}/"; api_pid=$PROBE_PID
start_probe app "https://${APP_HOST}/"; app_pid=$PROBE_PID
deploy_log="$WORK/deploy-v2.log"
bash scripts/deploy.sh e2e-v2 --skip-pull </dev/null >"$deploy_log" 2>&1
deploy_rc=$?
kill "$api_pid" "$app_pid" 2>/dev/null; wait "$api_pid" "$app_pid" 2>/dev/null
check "the deploy succeeds" "0" "$deploy_rc"
[ "$deploy_rc" -eq 0 ] || tail -40 "$deploy_log"

api_total=$(grep -c . "$WORK/probe-api.log" || true)
api_bad=$(grep -cv '^200 ' "$WORK/probe-api.log" || true)
app_total=$(grep -c . "$WORK/probe-app.log" || true)
app_bad=$(grep -cv '^200 ' "$WORK/probe-app.log" || true)
echo "  api: ${api_bad}/${api_total} non-200   app: ${app_bad}/${app_total} non-200"
# A bare count says a roll dropped requests; the histogram says HOW, and the
# difference decides where to look. 000 is a client-side timeout (a request
# routed to a backend whose IP has already gone), 502/503 is Traefik answering
# with no healthy backend -- entirely different faults.
for probe_name in api app; do
  if [ -s "$WORK/probe-${probe_name}.log" ] && grep -qv '^200 ' "$WORK/probe-${probe_name}.log"; then
    echo "  ${probe_name} non-200 breakdown:"
    grep -v '^200 ' "$WORK/probe-${probe_name}.log" | awk '{print $1}' \
      | sort | uniq -c | sed 's/^/    /'
    echo "  ${probe_name} pool state at each failure (first 8):"
    head -8 "$WORK/probe-${probe_name}-diag.log" | sed 's/^/    /'
  fi
done
check "the load probe actually ran" "1" "$([ "$api_total" -gt 50 ] && echo 1 || echo 0)"

# `web` is drainable, so its roll must be strictly zero-downtime. This is the
# guarantee the drain gate exists to provide and the one worth failing CI over.
check "rolling web drops NO request" "0" "$api_bad"

# `dashboard` is NOT drainable -- it is a static nginx whose Traefik probe
# answers 200 until the process dies, so requests already dispatched to a
# replica at the instant it stops ARE lost. services.sh and DEPLOY.md both say
# so. Asserting zero here would be asserting a property the design explicitly
# does not claim; asserting a small bound catches a REGRESSION (a roll that
# stops taking the old generation out gracefully at all) without pretending.
check "rolling the dashboard stays within its accepted residual" "1" \
  "$([ "$app_bad" -le 3 ] && echo 1 || echo 0)"

check "the api host now serves the new generation" "200 e2e-v2" "$(probe "https://${API_HOST}/")"
check "the app host now serves the new generation" "200 e2e-v2" "$(probe "https://${APP_HOST}/")"
check "release state advanced" "CURRENT=e2e-v2" "$(grep '^CURRENT=' .release-state)"
check "release state records the tag that was serving" "PREVIOUS=e2e-v1" \
  "$(grep '^PREVIOUS=' .release-state)"
running=$(docker ps --format '{{.Names}}')
check "web is back at its steady replica count" "2" \
  "$(grep -cE '^chatbot-web-[0-9]+$' <<<"$running" || true)"
check "dashboard is back at its steady replica count" "2" \
  "$(grep -cE '^chatbot-dashboard-[0-9]+$' <<<"$running" || true)"
# The roll leaves no half-retired generation behind, and no `compose run`
# one-off is miscounted as a replica.
check "no stray web container survived the roll" "2" \
  "$(grep -cE '^chatbot-web-' <<<"$running" || true)"

# --- 7. the backup is a real, restorable archive ----------------------------
# deploy.sh's backup used to be `sh -c "pg_dump ... | gzip > f" || WARN`. A
# pipeline takes its LAST command's status and gzip succeeds on empty input, so
# a failed dump exited 0 and left a valid 20-byte archive that the retention
# sweep then counted as one of the 14 kept backups. rollout.test.sh proves
# deploy.sh branches on the status; only this proves the status is truthful,
# against the real postgres image and the real gzip.
note "7. the backup written by the deploy above"
backup=$(docker compose -f "$COMPOSE" exec -T db \
  sh -c 'ls -1 /backups/*.sql.gz 2>/dev/null | tail -1' </dev/null | tr -d '\r')
check "the deploy wrote a backup" "1" "$([ -n "$backup" ] && echo 1 || echo 0)"
check "the backup is a valid gzip stream" "0" \
  "$(docker compose -f "$COMPOSE" exec -T db gzip -t "$backup" </dev/null >/dev/null 2>&1; echo $?)"
check "the backup contains a real pg_dump, not an empty stream" "1" \
  "$(docker compose -f "$COMPOSE" exec -T db \
     sh -c "gzip -dc '${backup}' | grep -c 'PostgreSQL database dump' || true" </dev/null \
     | tr -d '\r' | head -1 | awk '$1>0{print 1; exit} {print 0; exit}')"

# The premise, proved in the image the deploy actually uses rather than
# asserted from memory: without pipefail a failed dump reports success, and
# with it the failure surfaces. If the first of these ever starts failing, the
# fix in deploy.sh is unnecessary; if the second does, it is broken.
check "bash exists in the db image (deploy.sh's backup needs it, sh is dash)" "0" \
  "$(docker compose -f "$COMPOSE" exec -T db bash -c 'exit 0' </dev/null >/dev/null 2>&1; echo $?)"
check "without pipefail a failed dump reports SUCCESS" "0" \
  "$(docker compose -f "$COMPOSE" exec -T db \
     bash -c 'pg_dump -U nosuchuser -d nosuchdb 2>/dev/null | gzip > /tmp/bad.gz' \
     </dev/null >/dev/null 2>&1; echo $?)"
check "with pipefail the same failure surfaces" "1" \
  "$(docker compose -f "$COMPOSE" exec -T db \
     bash -c 'set -o pipefail; pg_dump -U nosuchuser -d nosuchdb 2>/dev/null | gzip > /tmp/bad.gz' \
     </dev/null >/dev/null 2>&1; echo $?)"

# --- 8. a failed smoke check must auto-roll-back ----------------------------
# The lever is the edge, not the application: stopping it makes the three
# public probes fail while the two loopback probes still pass. That is both the
# easiest failure to induce and the exact scenario the loopback probes were
# added for -- "public fails, loopback passes" means the gateway is broken, not
# the release. deploy.sh rolls back on any smoke failure either way, which is
# the behaviour under test here.
note "8. auto-rollback on a failed smoke check"
current_before=$(sed -n 's/^CURRENT=//p' .release-state | head -1)
check "phase 8 starts from the release phase 6 recorded" "e2e-v2" "$current_before"
docker stop "$EDGE" >/dev/null
rollback_log="$WORK/deploy-v3.log"
bash scripts/deploy.sh e2e-v3 --skip-pull --skip-backup </dev/null >"$rollback_log" 2>&1
check "a failed smoke check fails the deploy" "1" "$?"
check "it rolls back to CURRENT, the tag that was serving" "1" \
  "$(grep -c 'rolling back to e2e-v2' "$rollback_log" || true)"
check "it does NOT roll back to PREVIOUS" "0" \
  "$(grep -c 'rolling back to e2e-v1' "$rollback_log" || true)"
check "release state is NOT advanced past a failed deploy" "0" \
  "$(grep -c 'CURRENT=e2e-v3' .release-state || true)"

docker start "$EDGE" >/dev/null
wait_for_200 "https://${API_HOST}/" 60
# The rollback ran to completion even though its own verification could not
# pass while the edge was down: the images reverted, which is what matters.
check "the reverted generation is serving once the edge is back" "200 e2e-v2" \
  "$(probe "https://${API_HOST}/")"
check "no e2e-v3 container survived the rollback" "0" \
  "$(docker ps --format '{{.Image}}' | grep -c 'e2e-v3' || true)"

# --- 9. an operator-initiated rollback --------------------------------------
note "9. explicit rollback e2e-v2 -> e2e-v1"
# .release-state was left describing e2e-v2 by the failed deploy above, so a
# blank-tag rollback would resolve PREVIOUS. Name the tag, which is what
# DEPLOY.md tells an operator to do.
back_log="$WORK/rollback.log"
bash scripts/rollback.sh e2e-v1 </dev/null >"$back_log" 2>&1
check "the rollback succeeds and verifies" "0" "$?"
[ "$FAIL" -eq 0 ] || tail -30 "$back_log"
check "the api host serves the rolled-back generation" "200 e2e-v1" "$(probe "https://${API_HOST}/")"
check "the app host serves the rolled-back generation" "200 e2e-v1" "$(probe "https://${APP_HOST}/")"
check "the rollback records its target as CURRENT" "CURRENT=e2e-v1" "$(grep '^CURRENT=' .release-state)"
check "the rollback records what it displaced as PREVIOUS" "PREVIOUS=e2e-v2" \
  "$(grep '^PREVIOUS=' .release-state)"

# --- summary ----------------------------------------------------------------
cd "$REPO" || exit 1
echo
echo "---"
echo "passed: ${PASS}  failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
