#!/usr/bin/env bash
# Rolling-replacement primitives. Sourced by deploy.sh and rollback.sh.
#
# Everything here talks to Docker and to Traefik's container-local API; nothing
# here knows this application's service list. Keep it that way so the logic
# stays testable with stubs.

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.production.yml}"
TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-chatbot-traefik-1}"
TRAEFIK_API="${TRAEFIK_API:-http://127.0.0.1:8080/api}"
# Traefik's healthcheck interval is 5s; three intervals is the settle window
# after which a drained backend is certainly out of rotation.
DRAIN_SETTLE_SECS="${DRAIN_SETTLE_SECS:-15}"
# The api image's HEALTHCHECK declares start_period 60s and interval 10s
# (chatbot_api/Dockerfile), so a cold web container needs ~70s before its first
# passing probe is recorded. Re-derive this from the Dockerfile, not from
# memory: an earlier version of this comment said 40s/30s, which happens to sum
# to the same 70s and so hid the drift.
HEALTH_TIMEOUT_SECS="${HEALTH_TIMEOUT_SECS:-180}"
# How long to wait for Traefik to register the new backends once they are
# already healthy. Registration is event-driven, so this is generous.
BACKEND_TIMEOUT_SECS="${BACKEND_TIMEOUT_SECS:-120}"
# How long to wait for Traefik to RETIRE the old backends after a roll. Same
# event stream, so the same order of magnitude; separate knob because exceeding
# it is a warning rather than a failure (see wait_backends_settled).
SETTLE_TIMEOUT_SECS="${SETTLE_TIMEOUT_SECS:-60}"

# Names of the running REPLICAS of a compose service, sorted.
#
# The `-[0-9]+$` anchor is load-bearing, not tidiness. `docker compose run`
# names its one-off containers `chatbot-<service>-run-<hash>`, and deploy.sh
# runs three of them against `web` (collectstatic, migrate, the media probe).
# A bare `^chatbot-web-` prefix match counts those as replicas. They are --rm
# and sequential on the deploy path, so that path is safe today, but any
# one-off still running when a roll starts -- a hung migrate, an operator in a
# `manage.py shell` -- makes assert_steady_replicas report 3 and refuse, and
# makes roll_service's before/new set arithmetic wrong in a way no later gate
# sees. A replica is always `<service>-<n>`; nothing else is.
#
# LC_ALL=C so the ordering is byte order, not locale collation: `comm` in
# roll_service and service_labels_match demands its two inputs be sorted the
# same way, and one of those inputs is sorted by python.
service_containers() {
  docker ps --format '{{.Names}}' | grep -E "^chatbot-${1}-[0-9]+$" | LC_ALL=C sort || true
}

# Count the non-empty lines of a newline-separated container list. `grep -c .`
# rather than `wc -l` because the empty list is one empty line, not zero lines.
count_names() {
  printf '%s' "$1" | grep -c . || true
}

# Running replicas of a compose service.
service_replica_count() {
  count_names "$(service_containers "$1")"
}

# Health of one container: the healthcheck verdict when it has one, otherwise
# "none:<state>" so a service without a healthcheck is still observable.
container_health() {
  docker inspect \
    -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none:{{.State.Status}}{{end}}' \
    "$1" 2>/dev/null || echo missing
}

# Block until every named container is healthy. Return 1 on timeout.
#
# This is the gate Traefik cannot give us. Traefik's serverStatus is UP/DOWN
# only, and a newly registered server joins the pool as UP optimistically and
# stays UP until its FIRST healthcheck actually fails -- so wait_backends_up
# alone is satisfied within seconds of `compose up` returning, which is when
# containers have STARTED, not when they can serve. Draining the old generation
# at that point 502s every request until the new containers finish booting.
wait_containers_healthy() {
  local timeout="$1"; shift
  local waited=0 c status pending
  [ "$#" -gt 0 ] || { echo "ERROR: no containers to health-check" >&2; return 1; }
  while :; do
    pending=""
    for c in "$@"; do
      status=$(container_health "$c")
      case "$status" in
        healthy|none:running) ;;
        *) pending="${pending}${c}=${status} " ;;
      esac
    done
    [ -z "$pending" ] && return 0
    [ "$waited" -ge "$timeout" ] && {
      echo "TIMEOUT: containers not healthy after ${timeout}s: ${pending}" >&2
      return 1
    }
    sleep 2; waited=$((waited + 2))
  done
}

# Print "URL STATUS" per backend of a docker-provider service.
traefik_backends_up() {
  local service="$1"
  docker exec -i "$TRAEFIK_CONTAINER" \
    wget -qO- "${TRAEFIK_API}/http/services/${service}@docker" 2>/dev/null </dev/null \
  | tr ',' '\n' \
  | sed -n 's/.*"\(http:\/\/[^"]*\)":"\(UP\|DOWN\)".*/\1 \2/p'
}

# Assert every port the Traefik container publishes is bound to 127.0.0.1.
#
# The whole security model of this topology rests on that one binding: Traefik
# terminates no TLS and writes no request log of its own, because both are the
# host nginx's job in front of it (docs/DEPLOY.md §1). Publish it on 0.0.0.0
# instead and the entire stack is served in cleartext to the internet.
#
# Nothing else catches that. ufw cannot -- Docker inserts its own iptables
# rules ahead of ufw's, so a 0.0.0.0-published container port is reachable
# whether or not ufw has a matching rule. Nor can the smoke probes: all five
# request 127.0.0.1:8081, which answers identically either way, so a wrongly
# published gateway passes every check the deploy makes. Hence an explicit
# assertion, in the preflight, before anything is mutated.
assert_loopback_publication() {
  local out rc line addr bad=0
  out=$(docker port "$TRAEFIK_CONTAINER" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: could not read ${TRAEFIK_CONTAINER}'s published ports:" >&2
    echo "       ${out}" >&2
    return 1
  fi
  if [ -z "$out" ]; then
    echo "ERROR: ${TRAEFIK_CONTAINER} publishes no ports at all." >&2
    echo "       Expected the traefik service's \`ports:\` entry in" >&2
    echo "       ${COMPOSE_FILE} to read \"127.0.0.1:8081:80\"." >&2
    return 1
  fi
  while read -r line; do
    [ -n "$line" ] || continue
    # A `docker port` line is "80/tcp -> 127.0.0.1:8081". Drop the mapping
    # arrow, then the trailing :port, leaving the bind address.
    addr="${line##* -> }"
    addr="${addr%:*}"
    [ "$addr" = "127.0.0.1" ] && continue
    echo "ERROR: ${TRAEFIK_CONTAINER} publishes ${line}" >&2
    echo "       -- bound to ${addr}, not 127.0.0.1." >&2
    bad=1
  done <<<"$out"
  if [ "$bad" -ne 0 ]; then
    echo "       The gateway is reachable over plain http from off-host," >&2
    echo "       bypassing nginx's TLS and access log. Fix the traefik" >&2
    echo "       service's \`ports:\` entry in ${COMPOSE_FILE} back to" >&2
    echo "         - \"127.0.0.1:8081:80\"" >&2
    echo "       then re-create the container:" >&2
    echo "         docker compose -f ${COMPOSE_FILE} up -d --no-deps traefik" >&2
    return 1
  fi
  return 0
}

# Refuse when the running gateway predates its own static configuration.
#
# traefik.yml is STATIC: Traefik reads it once at process start. Only
# traefik/dynamic/ hot-reloads (providers.file, watch: true). cd.yml rsyncs
# traefik/ to the server, but NOTHING in a deploy recreates the Traefik
# container -- it touches db, redis, socket-proxy and media, and rolls worker,
# web and dashboard. So a changed traefik.yml lands on disk, is never read, and
# the deploy reports success while the committed configuration and the one
# actually serving traffic disagree -- silently, and for as long as nobody
# recreates the container by hand.
#
# That is not hypothetical. deploy.sh's own preflight documents the trap for
# the API setting, and the providers.docker constraint that stops Traefik
# discovering a co-tenant project's containers arrived exactly this way: correct
# in Git, inert in production. This generalises that one-off warning into a
# check that covers every static change.
#
# mtime vs StartedAt is the signal, and it only means anything because cd.yml
# syncs traefik/ with BOTH --checksum and --no-times. --checksum stops rsync
# retransmitting a file a fresh checkout merely re-timestamped; --no-times stops
# it copying the source mtime across anyway, which `-a` (which implies `-t`)
# otherwise does even for files --checksum skipped. Measured: with --checksum
# alone the server-side mtime still advanced on every run and this refused a
# deploy it should have passed. Get either flag wrong and the check cries wolf
# on every deploy, which is worse than not checking at all.
#
# Deliberately NOT fixed automatically: recreating Traefik drops every
# in-flight connection, which is the exact property the rest of this file
# exists to preserve. Applying static config is an operator's decision about
# when to take that hit, not a rollout's to make silently.
assert_gateway_config_applied() {
  local config="${1:-traefik/traefik.yml}"
  local started started_epoch file_mtime

  if [ ! -f "$config" ]; then
    echo "ERROR: ${config} does not exist, so whether the running gateway" >&2
    echo "       matches it cannot be determined." >&2
    return 1
  fi

  started=$(docker inspect -f '{{.State.StartedAt}}' "$TRAEFIK_CONTAINER" 2>/dev/null)
  started_epoch=$(date -d "$started" +%s 2>/dev/null)
  if [ -z "$started_epoch" ]; then
    # Do not block a deploy on an inability to check. A gateway that is absent
    # or unreadable is already refused, loudly, by assert_loopback_publication.
    echo "WARNING: could not read ${TRAEFIK_CONTAINER}'s start time; skipping the" >&2
    echo "         static-configuration check." >&2
    return 0
  fi

  file_mtime=$(stat -c %Y "$config" 2>/dev/null) || return 0

  # Strictly greater: a container started in the same second the file was
  # written did read it, and refusing on that coincidence would fail a
  # legitimate deploy.
  if [ "$file_mtime" -gt "$started_epoch" ]; then
    echo "ERROR: ${config} is newer than the running ${TRAEFIK_CONTAINER}." >&2
    echo "       Traefik reads that file ONCE, at process start; it does not" >&2
    echo "       hot-reload, unlike traefik/dynamic/. The configuration in Git and" >&2
    echo "       the configuration serving traffic therefore disagree, and rolling" >&2
    echo "       now would report success without applying the change." >&2
    echo "       Apply it, then re-run this deploy:" >&2
    echo "         docker compose -f ${COMPOSE_FILE} up -d --no-deps --force-recreate traefik" >&2
    echo "       That briefly drops in-flight connections, which is why a" >&2
    echo "       zero-downtime rollout will not do it for you." >&2
    return 1
  fi
  return 0
}

# Return 0 once >= expected backends report UP, 1 on timeout.
wait_backends_up() {
  local service="$1" expected="$2" timeout="$3"
  local waited=0 up
  while :; do
    up=$(traefik_backends_up "$service" | grep -c " UP$" || true)
    [ "${up:-0}" -ge "$expected" ] && return 0
    [ "$waited" -ge "$timeout" ] && {
      echo "TIMEOUT: ${service} had ${up:-0} UP backends, wanted ${expected}" >&2
      return 1
    }
    sleep 2; waited=$((waited + 2))
  done
}

# Block until Traefik's pool for a service holds EXACTLY `expected` backends.
#
# wait_backends_up answers "are there enough new ones yet"; this answers "are
# the old ones gone yet", and they are different questions. Retiring a
# container removes its IP from the bridge, and packets to a vanished IP are
# silently DROPPED -- no RST, nothing to fail fast on. So a request Traefik
# dispatches to a backend it has not yet learned is gone does not 502, it
# HANGS until the client's own timeout.
#
# That is not theoretical: it made a good release fail its own smoke check.
# deploy.sh smokes immediately after the last roll, the `dashboard` probe hit a
# just-removed backend, curl sat there until -m 15 and reported 000, and the
# deploy auto-rolled-back a release that was fine. `web` is drained so its
# backends leave the pool BEFORE they stop; `dashboard` is not drainable, so
# for it the only thing that closes this window is waiting for Traefik to
# converge.
#
# Warns rather than fails on timeout: this exists to remove a race, and a
# service that genuinely never converges is caught by the smoke checks
# immediately afterwards. Turning it into a hard failure would add a new way
# for a completed roll to abort a deploy.
wait_backends_settled() {
  local service="$1" expected="$2" timeout="${3:-$SETTLE_TIMEOUT_SECS}"
  local waited=0 up
  while :; do
    up=$(traefik_backends_up "$service" | grep -c " UP$" || true)
    [ "${up:-0}" -eq "$expected" ] && return 0
    if [ "$waited" -ge "$timeout" ]; then
      echo "WARNING: ${service} still shows ${up:-0} UP backends, expected exactly ${expected}." >&2
      echo "         Traefik has not finished retiring the old generation. Continuing;" >&2
      echo "         the smoke checks will catch it if this is more than a delay." >&2
      return 1
    fi
    sleep 2; waited=$((waited + 2))
  done
}

# Retire one old container.
#
# `docker stop` alone is NOT a drain: Traefik learns the container is gone from
# the event stream, but requests dispatched in that same instant die with it.
# A real drain needs the application to fail its own health probe first, and
# only web has that -- chatbot_api/Conf/views.py returns 503 while
# settings.DRAIN_FILE exists. Hence the explicit `drainable` argument: this
# function must never claim to drain a service that cannot be drained.
#
#   retire_container <container> <stop_timeout> <drainable:true|false>
retire_container() {
  local container="$1" stop_timeout="$2" drainable="$3"
  if [ "$drainable" = true ]; then
    echo ">>> draining ${container}"
    docker exec -i "$container" touch /tmp/drain </dev/null || true
    sleep "$DRAIN_SETTLE_SECS"
  else
    # NOT a drain, and deliberately not pretending to be one. `dashboard` is a
    # static nginx: its Traefik healthcheck probes `/`, which nginx answers 200
    # until the process dies, so a marker file would change nothing and touching
    # one would only make this code look safer than it is. We stop the container
    # and rely on Traefik removing it from the pool via the Docker event stream.
    # A small number of requests already dispatched to this replica in that
    # instant ARE dropped. Accepted residual; see docs/DEPLOY.md.
    echo ">>> stopping ${container} (no drain endpoint; in-flight requests to this replica may be dropped)"
  fi
  docker stop -t "$stop_timeout" "$container" >/dev/null
  docker rm -f "$container" >/dev/null 2>&1 || true
}

# The command that brings a service back to its steady replica count by hand.
# Single definition so every message that prints it -- roll_service's refusal,
# the deploy preflight, docs/DEPLOY.md -- says the same thing.
#
# --no-recreate matters: without it compose recreates the surviving replicas
# because IMAGE_TAG has moved, which is a non-rolling restart of the service.
#
# The leading IMAGE_TAG= matters just as much, and for the mirror-image reason.
# --no-recreate protects the containers that already exist; the explicit tag
# decides what the SCALE-UP creates. Without it compose interpolates IMAGE_TAG
# from the server's .env, which is `latest` per .env.example, and ci.yml pushes
# `latest` on every build of main -- so an operator copy-pasting this line to
# repair a replica count would bring the new replica up on the newest
# unreleased main build while its siblings stay on the deployed release.
#
# `declare -F` rather than calling release_current unconditionally: rollout.sh
# is application-agnostic and is sourced (and unit-tested) without services.sh.
# When the tag cannot be resolved the command still prints, with an obvious
# placeholder the operator must replace -- never a silent `latest`.
reconcile_command() {
  local tag=""
  if declare -F release_current >/dev/null 2>&1; then
    tag=$(release_current)
  fi
  echo "IMAGE_TAG=${tag:-<the currently deployed tag, see .release-state>} docker compose -f ${COMPOSE_FILE} up -d --no-deps --no-recreate --scale ${1}=${2} ${1}"
}

# Assert that every service is at its steady replica count, or return 1.
#
# Arguments are "<service> <steady> ..." specs -- extra fields are ignored so
# callers can pass the very table they roll with, which is the point: this must
# prove the precondition of EVERY roll_service call the run will make, before
# the run mutates anything. roll_service enforces the same precondition, but it
# enforces it at its own call site, which on a deploy is after the backup,
# collectstatic, migrate and any earlier rolls.
#
# Reports every offending service, not just the first: an operator recovering
# from an interrupted rollout wants the whole list in one go.
# --- Traefik service-label parity ------------------------------------------
#
# Traefik requires EVERY container of a service to declare an IDENTICAL service
# definition. A roll runs two generations at once by design, so if the new
# containers carry different `traefik.http.services.*` labels than the running
# ones, Traefik discards the service outright -- the router has no backend and
# the host 404s for the entire rollout. That happened on 2026-08-19: a
# healthcheck.status label added in an earlier phase met containers created
# before it, and the API was down for three minutes.
#
# No health gate can catch this. The damage is done when the container is
# CREATED, before anything can be probed. Detecting drift first is the only
# guard that works.

container_service_labels() {
  docker inspect \
    --format '{{range $k,$v := .Config.Labels}}{{println $k "=" $v}}{{end}}' "$1" 2>/dev/null \
    | tr -d ' ' | grep '^traefik\.http\.services\.' | LC_ALL=C sort
}

# Desired labels come from the rendered compose file. JSON + python3 stdlib
# rather than grepping the YAML: a line-based grep silently truncates and
# reports drift that is not there, which is how this check was first got wrong.
desired_service_labels() {
  docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    svc = json.load(sys.stdin)["services"][sys.argv[1]]
except Exception:
    sys.exit(0)
labs = svc.get("labels") or []
if isinstance(labs, dict):
    labs = [f"{k}={v}" for k, v in labs.items()]
for l in sorted(x.replace(" ", "") for x in labs if x.startswith("traefik.http.services.")):
    print(l)
' "$1"
}

# 0 when every running replica matches the compose file, 1 otherwise.
service_labels_match() {
  local service="$1" want got c drift=0
  want=$(desired_service_labels "$service")
  for c in $(service_containers "$service"); do
    got=$(container_service_labels "$c")
    if [ "$got" != "$want" ]; then
      drift=1
      echo "  ${c}:" >&2
      comm -13 <(printf '%s\n' "$got") <(printf '%s\n' "$want") \
        | sed 's/^/      missing on container: /' >&2
      comm -23 <(printf '%s\n' "$got") <(printf '%s\n' "$want") \
        | sed 's/^/      extra on container:   /' >&2
    fi
  done
  return "$drift"
}

# Preflight over every rolled service. Takes the same specs as
# assert_steady_replicas so the two cannot drift apart.
assert_service_labels() {
  local spec svc bad=0
  for spec in "$@"; do
    read -r svc _ <<<"$spec"
    if service_labels_match "$svc"; then
      echo "  ${svc}: service labels match"
    else
      echo "ERROR: ${svc}'s running replicas carry different traefik.http.services.*" >&2
      echo "       labels than docker-compose.production.yml renders." >&2
      bad=1
    fi
  done
  if [ "$bad" -ne 0 ]; then
    echo "ERROR: refusing to roll. Traefik discards a service whose containers" >&2
    echo "       disagree, so rolling now would 404 that host until it finished." >&2
    echo "       Bring the running replicas up to date first (brief outage on" >&2
    echo "       that host, then rolling deploys are zero-downtime again):" >&2
    echo "         bash scripts/sync-service-labels.sh <service>" >&2
    return 1
  fi
}

assert_steady_replicas() {
  local specs=("$@")
  local spec svc steady count bad=0
  for spec in "${specs[@]}"; do
    read -r svc steady _ <<<"$spec"
    count=$(service_replica_count "$svc")
    if [ "$count" -ne "$steady" ]; then
      echo "ERROR: ${svc} has ${count} running replicas, expected ${steady}." >&2
      echo "       Reconcile it, then re-run:" >&2
      echo "         $(reconcile_command "$svc" "$steady")" >&2
      bad=1
    else
      echo "  ${svc}: ${count} replicas"
    fi
  done
  if [ "$bad" -ne 0 ]; then
    echo "ERROR: refusing to start: a previous rollout was interrupted, or a" >&2
    echo "       service is not up. Nothing has been changed." >&2
    return 1
  fi
}

# Bring one service back to its steady replica count.
#
# OPT-IN, and only the rollback path may use it. A deploy that silently repaired
# a dirty pre-state would hide the interrupted rollout it should surface; a
# rollback that refused to run because the system is in a bad state would be
# blocked by exactly the condition it exists to recover from. So the strictness
# lives in roll_service (unchanged) and the repair lives here, in a separate
# function with a separate, obvious name.
#
# Scaling DOWN removes the highest-numbered containers, i.e. the newest -- after
# an interrupted rollout those are the half-finished new generation, so what
# survives is the generation that was already serving before the interruption.
# Scaling UP creates replicas at the current IMAGE_TAG. Either way the caller
# rolls immediately afterwards and replaces every surviving container with the
# target tag, so this only decides what serves during the roll, and "whatever
# was serving before" is the right answer to that.
reconcile_service() {
  local service="$1" steady="$2"
  local count after
  count=$(service_replica_count "$service")
  if [ "$count" -eq "$steady" ]; then
    echo ">>> reconcile ${service}: already at ${steady} replicas, nothing to do"
    return 0
  fi

  echo ">>> RECONCILE ${service}: found ${count} replicas, expected ${steady}." \
       "A previous rollout was interrupted. Scaling back to ${steady} before rolling."
  docker compose -f "$COMPOSE_FILE" up -d --no-deps --no-recreate \
    --scale "${service}=${steady}" "$service"

  after=$(service_replica_count "$service")
  echo ">>> reconcile ${service}: ${count} -> ${after} replicas"
  if [ "$after" -ne "$steady" ]; then
    echo "ERROR: could not reconcile ${service} to ${steady} replicas (still ${after})." >&2
    echo "       Fix by hand, then re-run:" >&2
    echo "         $(reconcile_command "$service" "$steady")" >&2
    return 1
  fi
}

# Roll a Traefik-fronted service: add a generation at the new tag, wait for the
# new containers to be healthy AND routable, then retire the old generation.
#
#   roll_service <service> <steady> <stop_timeout> <drainable:true|false>
roll_service() {
  local service="$1" steady="$2" stop_timeout="$3" drainable="${4:-}"
  local before scaled new after doubled=$((steady * 2))
  local before_count after_count

  case "$drainable" in
    true|false) ;;
    *) echo "ERROR: roll_service ${service}: drainable must be true or false, got '${drainable}'" >&2
       return 2 ;;
  esac

  before=$(service_containers "$service")
  before_count=$(count_names "$before")

  # Reconcile before touching anything. `doubled` is only meaningful if the
  # service really is at `steady` now: an interrupted previous rollout leaves
  # 2*steady mixed-version replicas, `--scale ${doubled}` under --no-recreate
  # then creates nothing new, and the retire loop would take every replica
  # down and reach zero backends before creating any.
  if [ "$before_count" -ne "$steady" ]; then
    echo "ERROR: ${service} has ${before_count} running replicas, expected ${steady}." >&2
    echo "       A previous rollout was interrupted, or the service is not up." >&2
    echo "       Refusing to roll. Reconcile first, then re-run:" >&2
    echo "         $(reconcile_command "$service" "$steady")" >&2
    return 1
  fi

  echo ">>> rolling ${service}: ${steady} -> ${doubled} -> ${steady} (drainable=${drainable})"

  # --no-recreate leaves the running generation untouched and creates the new
  # containers at the current IMAGE_TAG.
  #
  # NOTE: these services also declare `deploy.replicas: 2`. Compose accepts an
  # explicit --scale alongside it and the --scale value wins -- verified
  # locally against this compose version (4 containers created, warning only,
  # no refusal). `deploy.replicas` stays: it is what brings the service up at
  # the right count outside this script.
  docker compose -f "$COMPOSE_FILE" up -d --no-deps --no-recreate \
    --scale "${service}=${doubled}" "$service"

  # The new generation is whatever appeared that was not there before.
  scaled=$(service_containers "$service")
  new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$scaled") | grep . || true)
  if [ -z "$new" ]; then
    echo "ERROR: scaling ${service} to ${doubled} created no new containers" >&2
    return 1
  fi

  # (a) the containers themselves must be healthy -- compose up returns when
  # they START -- and only then (b) Traefik must have picked them up. Both, in
  # that order: (b) still catches a container that is healthy but that Traefik
  # has not registered.
  # shellcheck disable=SC2086
  if ! wait_containers_healthy "$HEALTH_TIMEOUT_SECS" $new; then
    echo "ERROR: new ${service} containers never became healthy; leaving the old ones serving" >&2
    return 1
  fi
  if ! wait_backends_up "$service" "$doubled" "$BACKEND_TIMEOUT_SECS"; then
    echo "ERROR: new ${service} replicas never came UP in Traefik; leaving the old ones serving" >&2
    return 1
  fi

  for c in $before; do retire_container "$c" "$stop_timeout" "$drainable"; done

  docker compose -f "$COMPOSE_FILE" up -d --no-deps --no-recreate \
    --scale "${service}=${steady}" "$service"

  after=$(service_containers "$service")
  after_count=$(count_names "$after")
  echo ">>> ${service} now at ${after_count} replicas"
  if [ "$after_count" -ne "$steady" ]; then
    echo "ERROR: ${service} converged to ${after_count} replicas, expected ${steady}" >&2
    return 1
  fi

  # Docker agrees the old generation is gone; Traefik may not know yet. Return
  # only once its pool matches, so a caller that probes immediately -- which
  # deploy.sh and rollback.sh both do -- cannot be routed to a backend that no
  # longer exists. See wait_backends_settled for why that hangs rather than
  # failing fast.
  wait_backends_settled "$service" "$steady" || true
}

# Roll a service with no Traefik backend (celery). SIGTERM is a warm shutdown:
# the worker finishes its current task and stops prefetching, so the timeout
# must exceed the task time limit.
roll_worker() {
  local service="$1" stop_timeout="$2"
  echo ">>> rolling ${service} (warm shutdown, ${stop_timeout}s)"
  for c in $(service_containers "$service"); do
    docker stop -t "$stop_timeout" "$c" >/dev/null
  done
  docker compose -f "$COMPOSE_FILE" up -d --no-deps "$service"

  # A manual `docker stop` clears the restart trigger, so an interruption
  # between the loop above and the `up` leaves ZERO consumers permanently and
  # nothing else notices -- Celery is not in the smoke checks. Assert instead.
  local running
  running=$(service_replica_count "$service")
  echo ">>> ${service} now at ${running} container(s)"
  if [ "$running" -lt 1 ]; then
    echo "ERROR: no ${service} container is running after the restart; Celery has no consumers" >&2
    return 1
  fi
}
