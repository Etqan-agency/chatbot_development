#!/usr/bin/env bash
# Tests for rollout.sh. Stubs `docker` on PATH so nothing touches a daemon.
#
# Some fixture service names (frontend, dashboard) do not correspond to services
# in docker-compose.production.yml. That is deliberate: rollout.sh is
# application-agnostic, so its tests use arbitrary names to prove it stays that
# way. The real service table lives in services.sh and is tested by deploying.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

STUB_DIR=$(mktemp -d)
export STUB_DIR
trap 'rm -rf "$STUB_DIR"' EXIT
export PATH="$STUB_DIR:$PATH"
PASS=0; FAIL=0

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected [$2] got [$3]"; fi
}

# The stub models just enough Docker to exercise roll_service:
#   $STUB_DIR/ps           running container names, one per line
#   $STUB_DIR/health       "<container> <health-status>" overrides
#   $STUB_DIR/health_default  status for containers with no override
#   $STUB_DIR/api.json     what Traefik's API returns
#   $STUB_DIR/stop_noop    if present, `docker stop` does not remove from ps
write_docker_stub() {
  cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
# record every call so tests can assert on ordering
echo "$*" >> "$STUB_DIR/calls.log"
# and record the IMAGE_TAG the caller had exported, so a test can prove that a
# script pinned the tag rather than letting compose read it from .env
echo "IMAGE_TAG=${IMAGE_TAG:-<unset>} $*" >> "$STUB_DIR/env.log"
case "$1" in
  ps)
    cat "$STUB_DIR/ps" 2>/dev/null
    ;;
  image)
    # `docker image inspect <ref>`: present iff the test staged it.
    if [ "${2:-}" = inspect ]; then
      grep -qxF "${*: -1}" "$STUB_DIR/local_images" 2>/dev/null; exit $?
    fi
    ;;
  inspect)
    c="${*: -1}"
    # A Labels-format inspect asks for container labels, not health.
    case "$*" in
      *State.StartedAt*)
        cat "$STUB_DIR/started_at" 2>/dev/null
        exit 0 ;;
      *Config.Labels*)
        grep "^${c} " "$STUB_DIR/labels" 2>/dev/null | cut -d' ' -f2-
        exit 0 ;;
    esac
    s=$(grep "^${c} " "$STUB_DIR/health" 2>/dev/null | head -1 | cut -d' ' -f2-)
    [ -n "$s" ] || s=$(cat "$STUB_DIR/health_default" 2>/dev/null || echo healthy)
    echo "$s"
    ;;
  exec)
    case "$*" in
      *"127.0.0.1:8080/api/http/services"*) cat "$STUB_DIR/api.json" 2>/dev/null ;;
    esac
    ;;
  port)
    # `docker port <container>`: one "80/tcp -> <addr>:<port>" line per
    # published mapping. $STUB_DIR/port holds whatever the test staged;
    # reset_stub seeds it with the correct loopback publication.
    cat "$STUB_DIR/port" 2>/dev/null
    ;;
  stop)
    [ -e "$STUB_DIR/stop_noop" ] && exit 0
    c="${*: -1}"
    grep -vx "$c" "$STUB_DIR/ps" > "$STUB_DIR/ps.tmp" 2>/dev/null
    mv "$STUB_DIR/ps.tmp" "$STUB_DIR/ps"
    ;;
  rm)
    [ -e "$STUB_DIR/stop_noop" ] && exit 0
    c="${*: -1}"
    grep -vx "$c" "$STUB_DIR/ps" > "$STUB_DIR/ps.tmp" 2>/dev/null
    mv "$STUB_DIR/ps.tmp" "$STUB_DIR/ps"
    ;;
  compose)
    # `config --format json` returns whatever the test staged as desired state.
    case "$*" in
      *"config --format json"*) cat "$STUB_DIR/compose_json" 2>/dev/null; exit 0 ;;
      # `compose exec -T db bash -c "...pg_dump..."`. The stub cannot run the
      # pipeline, so it returns the status deploy.sh must BRANCH on; whether
      # the real pipeline reports that status truthfully is what the separate
      # `set -o pipefail` assertion below covers.
      *pg_dump*) exit "$(cat "$STUB_DIR/pg_dump_rc" 2>/dev/null || echo 0)" ;;
      # `compose pull`: status controlled by the test, so the registry can be
      # made unreachable without one existing.
      *" pull "*|*" pull") exit "$(cat "$STUB_DIR/pull_rc" 2>/dev/null || echo 0)" ;;
    esac
    # Model `up -d --scale <svc>=<n>`: create containers until there are n.
    prev=""; spec=""
    for a in "$@"; do [ "$prev" = "--scale" ] && spec="$a"; prev="$a"; done
    # A plain `up` (no --scale) creates whatever $STUB_DIR/up_creates names.
    if [ -z "$spec" ] && [ -s "$STUB_DIR/up_creates" ]; then
      cat "$STUB_DIR/up_creates" >> "$STUB_DIR/ps"
    fi
    if [ -n "$spec" ]; then
      svc="${spec%%=*}"; want="${spec##*=}"
      pfx="chatbot-${svc}-"
      have=$(grep -c "^${pfx}" "$STUB_DIR/ps" 2>/dev/null || true)
      max=$(sed -n "s/^${pfx}//p" "$STUB_DIR/ps" 2>/dev/null | sort -n | tail -1)
      max=${max:-0}
      while [ "${have:-0}" -lt "$want" ]; do
        max=$((max + 1)); have=$((have + 1))
        echo "${pfx}${max}" >> "$STUB_DIR/ps"
      done
      # Scaling down removes the HIGHEST-numbered containers, as compose does.
      # Gated on stop_noop for the same reason `docker stop` is: compose
      # implements a scale-down by stopping and removing containers.
      while [ "${have:-0}" -gt "$want" ] && [ ! -e "$STUB_DIR/stop_noop" ]; do
        grep -vx "${pfx}${max}" "$STUB_DIR/ps" > "$STUB_DIR/ps.tmp" 2>/dev/null
        mv "$STUB_DIR/ps.tmp" "$STUB_DIR/ps"
        max=$((max - 1)); have=$((have - 1))
      done
    fi
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/docker"
}

reset_stub() { # reset_stub <api-json> [ps-lines...]
  local api="$1"; shift
  printf '%s\n' "$api" > "$STUB_DIR/api.json"
  : > "$STUB_DIR/health"
  echo healthy > "$STUB_DIR/health_default"
  rm -f "$STUB_DIR/stop_noop"
  printf '80/tcp -> 0.0.0.0:80\n443/tcp -> 0.0.0.0:443\n' > "$STUB_DIR/port"
  echo 0 > "$STUB_DIR/pg_dump_rc"
  echo 0 > "$STUB_DIR/pull_rc"
  # Far future by default, so the gateway looks freshly started and the
  # static-config guard stays out of every other test's way.
  echo "2099-01-01T00:00:00Z" > "$STUB_DIR/started_at"
  printf '%s\n' ghcr.io/etqan-agency/chatbot-zaychain/api:rbtag \
                ghcr.io/etqan-agency/chatbot-zaychain/dashboard:rbtag > "$STUB_DIR/local_images"
  : > "$STUB_DIR/up_creates"
  : > "$STUB_DIR/ps"
  [ "$#" -gt 0 ] && printf '%s\n' "$@" > "$STUB_DIR/ps"
  : > "$STUB_DIR/calls.log"
  : > "$STUB_DIR/env.log"
}

# Back-compat helper for the parsing tests: API only, no containers.
make_docker_stub() { reset_stub "$1"; }

# 4 backends UP, which is what a 2 -> 4 scale-up should produce.
FOUR_UP='{"serverStatus":{"http://a:5000":"UP","http://b:5000":"UP","http://c:5000":"UP","http://d:5000":"UP"}}'

write_docker_stub
# shellcheck source=SCRIPTDIR/rollout.sh
source ./rollout.sh
export DRAIN_SETTLE_SECS=0
# Keep the suite fast: the production defaults are 180s/120s.
export BACKEND_TIMEOUT_SECS=2
# The stub's api.json is a fixed 4-UP fixture, so the post-roll settle wait can
# never observe the pool shrinking to `steady` and would burn its whole timeout
# on every roll_service call. Its semantics get a dedicated test below instead.
export SETTLE_TIMEOUT_SECS=0

# --- traefik_backends_up parses serverStatus ---
make_docker_stub '{"serverStatus":{"http://172.19.0.7:5000":"UP","http://172.19.0.9:5000":"DOWN"}}'
out=$(traefik_backends_up web | sort | tr '\n' ';')
check "parses both backends" "http://172.19.0.7:5000 UP;http://172.19.0.9:5000 DOWN;" "$out"

# --- wait_backends_up succeeds when enough are UP ---
make_docker_stub '{"serverStatus":{"http://a:5000":"UP","http://b:5000":"UP"}}'
wait_backends_up web 2 5; check "two UP satisfies a wait for 2" "0" "$?"

# --- wait_backends_up times out when too few are UP ---
make_docker_stub '{"serverStatus":{"http://a:5000":"UP","http://b:5000":"DOWN"}}'
wait_backends_up web 2 2; check "one UP does NOT satisfy a wait for 2" "1" "$?"

# --- wait_backends_up times out on an empty service ---
make_docker_stub '{"serverStatus":{}}'
wait_backends_up web 1 2; check "no backends times out" "1" "$?"

# --- wait_containers_healthy ---
reset_stub '{}' chatbot-web-1
echo "chatbot-web-1 healthy" > "$STUB_DIR/health"
wait_containers_healthy 4 chatbot-web-1
check "healthy container satisfies the health gate" "0" "$?"

reset_stub '{}' chatbot-web-1
echo "chatbot-web-1 starting" > "$STUB_DIR/health"
wait_containers_healthy 2 chatbot-web-1 2>/dev/null
check "a starting container does NOT satisfy the health gate" "1" "$?"

reset_stub '{}' chatbot-web-1
echo "chatbot-web-1 none:running" > "$STUB_DIR/health"
wait_containers_healthy 2 chatbot-web-1
check "container without a healthcheck passes if running" "0" "$?"

# --- retire_container: drainable flips the marker BEFORE stopping ---
reset_stub '{}' chatbot-web-1
retire_container chatbot-web-1 40 true >/dev/null
order=$(grep -oE "touch /tmp/drain|stop -t" "$STUB_DIR/calls.log" | tr '\n' ',')
check "drain marker precedes stop when drainable" "touch /tmp/drain,stop -t," "$order"

# --- retire_container: non-drainable must NOT write a marker nothing reads ---
reset_stub '{}' chatbot-frontend-1
retire_container chatbot-frontend-1 30 false >/dev/null
check "non-drainable writes no drain marker" "0" \
  "$(grep -c 'touch /tmp/drain' "$STUB_DIR/calls.log" || true)"
check "non-drainable still stops the container" "1" \
  "$(grep -c 'stop -t 30' "$STUB_DIR/calls.log" || true)"

# --- roll_service: happy path ---
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2
roll_service web 2 40 true >/dev/null 2>&1
check "roll_service returns 0 on a clean roll" "0" "$?"
check "roll_service converges back to steady" "2" "$(grep -c . "$STUB_DIR/ps")"
check "roll_service retired both old replicas" "2" \
  "$(grep -cE 'stop -t 40 chatbot-web-[12]$' "$STUB_DIR/calls.log" || true)"

# --- CRITICAL 3: roll_service refuses a dirty pre-state ---
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-web-3 chatbot-web-4
err=$(roll_service web 2 40 true 2>&1 >/dev/null); rc=$?
check "roll_service refuses 4 replicas when steady is 2" "1" "$rc"
check "refusal names the actual count" "1" \
  "$(grep -c 'has 4 running replicas, expected 2' <<<"$err" || true)"
check "refusal mentions the interrupted rollout" "1" \
  "$(grep -c 'interrupted' <<<"$err" || true)"
check "refusal stops before any container is touched" "0" \
  "$(grep -cE '^(compose|stop|exec)' "$STUB_DIR/calls.log" || true)"

reset_stub "$FOUR_UP" chatbot-web-1
roll_service web 2 40 true >/dev/null 2>&1
check "roll_service refuses 1 replica when steady is 2" "1" "$?"

# --- CRITICAL 1: roll_service health-gates BEFORE draining ---
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2
# The new generation (-3, -4) is still booting; the old two are healthy.
echo starting > "$STUB_DIR/health_default"
{ echo "chatbot-web-1 healthy"; echo "chatbot-web-2 healthy"; } \
  > "$STUB_DIR/health"
HEALTH_TIMEOUT_SECS=2 roll_service web 2 40 true >/dev/null 2>&1
check "roll_service fails when the new containers are not healthy" "1" "$?"
check "roll_service did NOT stop an old replica while new ones were booting" "0" \
  "$(grep -c '^stop ' "$STUB_DIR/calls.log" || true)"
check "old replicas are still running" "2" \
  "$(grep -c '^chatbot-web-[12]$' "$STUB_DIR/ps")"

# Traefik claiming 4 UP is not enough on its own: serverStatus reports a freshly
# registered server as UP optimistically, which is exactly the false signal that
# made the old code drain a still-booting generation.
check "the health gate ran before the Traefik gate" "inspect" \
  "$(grep -oE '^(inspect|exec)' "$STUB_DIR/calls.log" | head -1)"

# --- CRITICAL 1b: with healthy new containers but no Traefik pickup, still no drain ---
reset_stub '{"serverStatus":{"http://a:5000":"UP","http://b:5000":"UP"}}' \
  chatbot-web-1 chatbot-web-2
roll_service web 2 40 true >/dev/null 2>&1
check "healthy but unrouted new replicas do not trigger a drain" "1" "$?"
check "no old replica stopped when Traefik has not picked the new ones up" "0" \
  "$(grep -c '^stop ' "$STUB_DIR/calls.log" || true)"

# --- CRITICAL 3: roll_service asserts its post-state ---
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2
touch "$STUB_DIR/stop_noop"   # stops silently do nothing -> 4 replicas remain
roll_service web 2 40 true >/dev/null 2>&1
check "roll_service fails if it converges to the wrong replica count" "1" "$?"

# --- roll_service validates the drainable argument ---
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2
roll_service web 2 40 maybe >/dev/null 2>&1
check "roll_service rejects a bad drainable argument" "2" "$?"

# An omitted drainable argument must fail, not default to a silent behaviour.
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2
roll_service web 2 40 >/dev/null 2>&1
check "roll_service rejects a missing drainable argument" "2" "$?"

# --- roll_service with drainable=false writes no marker ---
reset_stub "$FOUR_UP" chatbot-frontend-1 chatbot-frontend-2
roll_service frontend 2 30 false >/dev/null 2>&1
check "non-drainable roll succeeds" "0" "$?"
check "non-drainable roll writes no drain marker" "0" \
  "$(grep -c 'touch /tmp/drain' "$STUB_DIR/calls.log" || true)"

# --- IMPORTANT 7: roll_worker fails loudly if nothing is running afterwards ---
reset_stub '{}' chatbot-worker-1
echo chatbot-worker-2 > "$STUB_DIR/up_creates"
roll_worker worker 360 >/dev/null 2>&1
check "roll_worker succeeds when a worker is running after the restart" "0" "$?"

reset_stub '{}' chatbot-worker-1
# `up` brings nothing back -- the state a manual `docker stop` plus an
# interruption leaves behind. Zero consumers must not report success.
roll_worker worker 360 >/dev/null 2>&1
check "roll_worker fails when no worker is running after the restart" "1" "$?"

# --- assert_steady_replicas: the deploy preflight gate ---
reset_stub '{}' chatbot-web-1 chatbot-web-2 \
  chatbot-frontend-1 chatbot-frontend-2 \
  chatbot-dashboard-1 chatbot-dashboard-2
assert_steady_replicas "web 2 40 true" "frontend 2 30 false" "dashboard 2 30 false" >/dev/null
check "assert_steady_replicas passes when every service is at steady" "0" "$?"

# The whole point of RESIDUAL 1: web being right must not excuse frontend.
reset_stub '{}' chatbot-web-1 chatbot-web-2 \
  chatbot-frontend-1 chatbot-frontend-2 chatbot-frontend-3 \
  chatbot-dashboard-1 chatbot-dashboard-2
err=$(assert_steady_replicas "web 2 40 true" "frontend 2 30 false" "dashboard 2 30 false" \
  2>&1 >/dev/null); rc=$?
check "assert_steady_replicas rejects a wrong count on a NON-web service" "1" "$rc"
check "the rejection names the offending service and its actual count" "1" \
  "$(grep -c 'frontend has 3 running replicas, expected 2' <<<"$err" || true)"
check "the rejection prints frontend's reconcile command" "1" \
  "$(grep -cF -- '--scale frontend=2 frontend' <<<"$err" || true)"
check "the rejection does not blame the services that are fine" "0" \
  "$(grep -cE '^ERROR: (web|dashboard) has' <<<"$err" || true)"
check "assert_steady_replicas touches nothing" "0" \
  "$(grep -cE '^(compose|stop|exec|rm)' "$STUB_DIR/calls.log" || true)"

# A service that is DOWN (zero replicas) is just as wrong as a doubled one.
reset_stub '{}' chatbot-web-1 chatbot-web-2 \
  chatbot-frontend-1 chatbot-frontend-2
err=$(assert_steady_replicas "web 2 40 true" "dashboard 2 30 false" 2>&1 >/dev/null)
check "a service with zero replicas is rejected" "1" \
  "$(grep -c 'dashboard has 0 running replicas, expected 2' <<<"$err" || true)"

# Every offending service is reported in one go, not just the first.
reset_stub '{}' chatbot-web-1 \
  chatbot-frontend-1 chatbot-frontend-2 chatbot-frontend-3
err=$(assert_steady_replicas "web 2 40 true" "frontend 2 30 false" 2>&1 >/dev/null)
check "all offending services are reported, not just the first" "2" \
  "$(grep -cE '^ERROR: (web|frontend) has' <<<"$err" || true)"

# --- reconcile_service: the rollback-only repair ---
reset_stub '{}' chatbot-frontend-1 chatbot-frontend-2
out=$(reconcile_service frontend 2); rc=$?
check "reconcile_service is a no-op at steady" "0" "$rc"
check "a no-op reconcile scales nothing" "0" \
  "$(grep -c '^compose' "$STUB_DIR/calls.log" || true)"
check "a no-op reconcile still says so" "1" \
  "$(grep -c 'already at 2 replicas' <<<"$out" || true)"

reset_stub '{}' chatbot-frontend-1 chatbot-frontend-2 \
  chatbot-frontend-3 chatbot-frontend-4
out=$(reconcile_service frontend 2); rc=$?
check "reconcile_service returns 0 from a doubled pre-state" "0" "$rc"
check "reconcile_service logs what it found" "1" \
  "$(grep -c 'RECONCILE frontend: found 4 replicas, expected 2' <<<"$out" || true)"
check "reconcile_service logs what it did" "1" \
  "$(grep -c 'reconcile frontend: 4 -> 2 replicas' <<<"$out" || true)"
check "reconcile_service scales with --no-recreate" "1" \
  "$(grep -cF -- 'up -d --no-deps --no-recreate --scale frontend=2 frontend' \
     "$STUB_DIR/calls.log" || true)"

# If the scale does not take, say so rather than handing roll_service a state it
# will refuse anyway.
reset_stub '{}' chatbot-frontend-1 chatbot-frontend-2 \
  chatbot-frontend-3 chatbot-frontend-4
touch "$STUB_DIR/stop_noop"   # also makes the stub's scale-down a no-op
reconcile_service frontend 2 >/dev/null 2>&1
check "reconcile_service fails when the scale does not take" "1" "$?"

# The reconcile leaves a state roll_service accepts -- the pair is the contract.
reset_stub "$FOUR_UP" chatbot-frontend-1 chatbot-frontend-2 \
  chatbot-frontend-3 chatbot-frontend-4
reconcile_service frontend 2 >/dev/null 2>&1 && roll_service frontend 2 30 false >/dev/null 2>&1
check "reconcile then roll succeeds from a doubled pre-state" "0" "$?"
check "reconcile+roll converges to steady" "2" "$(grep -c . "$STUB_DIR/ps")"

# ---------------------------------------------------------------------------
# End-to-end: deploy.sh and rollback.sh against the same stubbed docker.
#
# The unit tests above prove the primitives. These prove the two call sites use
# them, which is the whole of RESIDUAL 1 and RESIDUAL 2: where the check runs
# matters as much as what it checks.
# ---------------------------------------------------------------------------
PROJ="$STUB_DIR/proj"

# `free` and `curl` are the only other host commands the scripts shell out to.
cat > "$STUB_DIR/free" <<'STUB'
#!/usr/bin/env bash
echo "Mem: 1 2 3 4 5 4000"
STUB
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# The probe set is not uniform any more: smoke_probes wants 200 from the three
# public https routes and 301 from the two cleartext :80 redirect probes. A
# stub that answered 200 to everything would fail the deploy on its own
# redirect check -- and, worse, would pass a build that had broken the
# redirect.
for a in "$@"; do
  case "$a" in
    http://*) echo 301; exit 0 ;;
  esac
done
echo 200
STUB
chmod +x "$STUB_DIR/free" "$STUB_DIR/curl"

setup_proj() { # a throwaway deploy directory holding a copy of scripts/
  rm -rf "$PROJ"
  mkdir -p "$PROJ/media" "$PROJ/traefik"
  cp -R .. "$PROJ/scripts"
  : > "$PROJ/docker-compose.production.yml"
  : > "$PROJ/media/nginx.conf"
  : > "$PROJ/traefik/traefik.yml"
  printf 'API_HOST=api.example.test\nAPP_HOST=app.example.test\n' > "$PROJ/.env"
}

# --- RESIDUAL 1: the preflight must catch a NON-web service, before any
#     mutation. Before this, the run reached `roll_service dashboard` only after
#     the backup, collectstatic, migrate, the worker roll and the web roll.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-dashboard-3 \
  chatbot-worker-1
err=$(bash "$PROJ/scripts/deploy.sh" testtag 2>&1 >/dev/null); rc=$?
check "deploy.sh aborts when dashboard is at the wrong replica count" "1" "$rc"
check "the abort names dashboard and its actual count" "1" \
  "$(grep -c 'dashboard has 3 running replicas, expected 2' <<<"$err" || true)"
check "the abort prints the reconcile command" "1" \
  "$(grep -cF -- '--scale dashboard=2 dashboard' <<<"$err" || true)"
check "deploy.sh aborted BEFORE pulling images" "0" \
  "$(grep -c '^compose -f .* pull' "$STUB_DIR/calls.log" || true)"
check "deploy.sh aborted BEFORE migrate" "0" \
  "$(grep -c 'migrate' "$STUB_DIR/calls.log" || true)"
check "deploy.sh aborted BEFORE the backup" "0" \
  "$(grep -c 'backup' "$STUB_DIR/calls.log" || true)"
check "deploy.sh aborted BEFORE rolling web" "0" \
  "$(grep -cF -- '--scale web=4 web' "$STUB_DIR/calls.log" || true)"
check "deploy.sh stopped no container" "0" \
  "$(grep -c '^stop ' "$STUB_DIR/calls.log" || true)"
check "dashboard is untouched at 3 replicas" "3" \
  "$(grep -c '^chatbot-dashboard-' "$STUB_DIR/ps")"

# --- the edge-publication guard. Traefik owns 80/443 directly here, so the
#     preflight is the only thing that can see three separate faults: a port
#     confined to loopback (unreachable site, or -- for :80 -- certificate
#     renewal that dies silently 60 days later), a missing port, and a stray
#     publication of the API entrypoint. Both directions are asserted: the
#     correct publication must NOT be refused, or the guard is a tripwire
#     nobody can deploy past.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
out=$(bash "$PROJ/scripts/deploy.sh" testtag --skip-backup 2>&1); rc=$?
check "an edge-published traefik passes the preflight" "0" "$rc"
check "the preflight says so" "1" \
  "$(grep -c 'traefik publishes 80 and 443 to the world' <<<"$out" || true)"

# IPv6 is a legitimate public binding, not a fault. Docker renders it as
# "[::]:443", which the address parser must not mistake for loopback.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
printf '80/tcp -> 0.0.0.0:80\n443/tcp -> [::]:443\n' > "$STUB_DIR/port"
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
out=$(bash "$PROJ/scripts/deploy.sh" testtag --skip-backup 2>&1); rc=$?
check "an IPv6-published port is accepted as public" "0" "$rc"

# A port confined to loopback. This is precisely the nginx topology's ports
# entry, which an upstream merge can reinstate, so it is asserted for BOTH
# ports rather than only the obvious one.
for port in 80 443; do
  addr=127.0.0.1
  setup_proj
  reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
    chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
  if [ "$port" = 80 ]; then
    printf '80/tcp -> 127.0.0.1:80\n443/tcp -> 0.0.0.0:443\n' > "$STUB_DIR/port"
  else
    printf '80/tcp -> 0.0.0.0:80\n443/tcp -> 127.0.0.1:443\n' > "$STUB_DIR/port"
  fi
  # Same fixture as the passing case above, so the only difference between a
  # rc=0 and this rc=1 is the publication -- otherwise a refusal assertion
  # could be satisfied by an unrelated late failure.
  echo chatbot-worker-9 > "$STUB_DIR/up_creates"
  err=$(bash "$PROJ/scripts/deploy.sh" testtag --skip-backup 2>&1 >/dev/null); rc=$?
  check "deploy.sh refuses port ${port} bound to ${addr}" "1" "$rc"
  check "the refusal quotes the offending mapping (${port})" "1" \
    "$(grep -cF -- "${port}/tcp -> ${addr}:${port}" <<<"$err" || true)"
  check "the refusal names the compose ports lines (${port})" "1" \
    "$(grep -cF -- '- "443:443"' <<<"$err" || true)"
  check "it refused BEFORE pulling images (${port})" "0" \
    "$(grep -c '^compose -f .* pull' "$STUB_DIR/calls.log" || true)"
  check "it refused BEFORE any mutation (${port})" "0" \
    "$(grep -cE '^(stop|rm) |--scale' "$STUB_DIR/calls.log" || true)"
done

# A MISSING port, as distinct from a loopback-bound one. :443 missing is
# obvious; :80 missing is the dangerous one, because nothing user-facing
# breaks and only certificate renewal dies.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
printf '443/tcp -> 0.0.0.0:443\n' > "$STUB_DIR/port"
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
err=$(bash "$PROJ/scripts/deploy.sh" testtag --skip-backup 2>&1 >/dev/null); rc=$?
check "deploy.sh refuses when port 80 is not published" "1" "$rc"
check "the refusal explains that renewal, not serving, is what breaks" "1" \
  "$(grep -c 'RENEWING' <<<"$err" || true)"

setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
printf '80/tcp -> 0.0.0.0:80\n' > "$STUB_DIR/port"
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
err=$(bash "$PROJ/scripts/deploy.sh" testtag --skip-backup 2>&1 >/dev/null); rc=$?
check "deploy.sh refuses when port 443 is not published" "1" "$rc"
check "the refusal says nothing is serving https" "1" \
  "$(grep -c 'nothing serving https' <<<"$err" || true)"

# A stray publication alongside two correct ones. A check that only verified
# the two required ports were present would let this through.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
printf '80/tcp -> 0.0.0.0:80\n443/tcp -> 0.0.0.0:443\n8080/tcp -> 0.0.0.0:8080\n' \
  > "$STUB_DIR/port"
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
err=$(bash "$PROJ/scripts/deploy.sh" testtag --skip-backup 2>&1 >/dev/null); rc=$?
check "deploy.sh refuses a stray publication beside the two public ports" "1" "$rc"
check "the refusal names the stray mapping, not the correct ones" "1" \
  "$(grep -cF -- '8080/tcp -> 0.0.0.0:8080' <<<"$err" || true)"

# No published ports at all is also a refusal: it means the ports: entry was
# deleted, and Traefik would then be serving nobody.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
: > "$STUB_DIR/port"
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
err=$(bash "$PROJ/scripts/deploy.sh" testtag --skip-backup 2>&1 >/dev/null); rc=$?
check "deploy.sh refuses when traefik publishes nothing" "1" "$rc"
check "the refusal says so" "1" \
  "$(grep -c 'publishes no ports at all' <<<"$err" || true)"

# --- RESIDUAL 2: rollback.sh must PROCEED from the dirty state a deploy refuses.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-web-3 chatbot-web-4 \
  chatbot-dashboard-1 chatbot-dashboard-2 \
  chatbot-worker-1
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
out=$(bash "$PROJ/scripts/rollback.sh" oldtag 2>&1); rc=$?
check "rollback.sh succeeds from a doubled web pre-state" "0" "$rc"
check "rollback.sh logged what it found" "1" \
  "$(grep -c 'RECONCILE web: found 4 replicas, expected 2' <<<"$out" || true)"
check "rollback.sh logged what it did" "1" \
  "$(grep -c 'reconcile web: 4 -> 2 replicas' <<<"$out" || true)"
check "rollback.sh said nothing to do for the clean service" "1" \
  "$(grep -cE 'reconcile dashboard: already at 2 replicas' <<<"$out" || true)"
check "rollback.sh reconciled BEFORE rolling web" "reconcile" \
  "$(grep -oE -- '--no-recreate --scale web=(2|4)' "$STUB_DIR/calls.log" \
     | head -1 | sed 's/.*web=2/reconcile/;s/.*web=4/roll/')"
check "rollback.sh still rolled web to the target tag" "1" \
  "$(grep -cF -- '--scale web=4 web' "$STUB_DIR/calls.log" || true)"
check "web converged to 2 replicas" "2" \
  "$(grep -c '^chatbot-web-' "$STUB_DIR/ps")"
check "dashboard converged to 2 replicas" "2" \
  "$(grep -c '^chatbot-dashboard-' "$STUB_DIR/ps")"
check "rollback.sh recorded the target as CURRENT" "CURRENT=oldtag" \
  "$(grep '^CURRENT=' "$PROJ/.release-state" || true)"

# The OTHER branch of the same write: a manual rollback to a tag that is NOT
# the recorded CURRENT is a genuine step back, so the tag being left behind
# becomes PREVIOUS. Only the TARGET == CURRENT case preserves the old PREVIOUS.
setup_proj
printf 'CURRENT=badtag\nPREVIOUS=oldtag\n' > "$PROJ/.release-state"
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
bash "$PROJ/scripts/rollback.sh" oldtag >/dev/null 2>&1
check "a rollback to a DIFFERENT tag shifts CURRENT down" "CURRENT=oldtag" \
  "$(grep '^CURRENT=' "$PROJ/.release-state" || true)"
check "a rollback to a DIFFERENT tag records the tag left behind" "PREVIOUS=badtag" \
  "$(grep '^PREVIOUS=' "$PROJ/.release-state" || true)"

# The repair is opt-in: a deploy from the same dirty state must still refuse.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-web-3 chatbot-web-4 \
  chatbot-dashboard-1 chatbot-dashboard-2
bash "$PROJ/scripts/deploy.sh" testtag >/dev/null 2>&1
check "deploy.sh does NOT reconcile the state rollback.sh repairs" "1" "$?"
check "deploy.sh scaled nothing" "0" \
  "$(grep -c -- '--scale' "$STUB_DIR/calls.log" || true)"

# --- the auto-rollback branch: a failed smoke check must roll back to the tag
#     that was serving BEFORE this deploy, which .release-state records as
#     CURRENT (the file is not rewritten until smoke passes).
setup_proj
printf 'CURRENT=goodtag\nPREVIOUS=oldertag\n' > "$PROJ/.release-state"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
echo 503
STUB
chmod +x "$STUB_DIR/curl"
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
out=$(bash "$PROJ/scripts/deploy.sh" newtag --skip-backup 2>&1); rc=$?
check "a failed smoke check fails the deploy" "1" "$rc"
check "the rollback targets CURRENT, not PREVIOUS" "1" \
  "$(grep -c 'rolling back to goodtag' <<<"$out" || true)"
check "it does NOT target PREVIOUS" "0" \
  "$(grep -c 'rolling back to oldertag' <<<"$out" || true)"
check "release state is NOT advanced past a failed deploy" "0" \
  "$(grep -c 'CURRENT=newtag' "$PROJ/.release-state" || true)"

# NOTE: no .release-state assertion here beyond the one above. The curl stub in
# this fixture returns 503, so the rollback this deploy triggers fails its own
# verification and exits BEFORE the state write. Anything asserted about
# PREVIOUS at this point is reading the untouched fixture file and would pass
# whether or not rollback.sh preserves it. The real guard is the dedicated
# case below, once the 200-returning stub is back.

# The first-ever deploy leaves PREVIOUS empty. A failing second deploy must
# still find CURRENT and roll back, not give up.
setup_proj
printf 'CURRENT=goodtag\nPREVIOUS=\n' > "$PROJ/.release-state"
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
out=$(bash "$PROJ/scripts/deploy.sh" newtag --skip-backup 2>&1) || true
check "an empty PREVIOUS does not defeat the auto-rollback" "1" \
  "$(grep -c 'rolling back to goodtag' <<<"$out" || true)"

# Restore the 200-returning curl stub for anything that follows.
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# The probe set is not uniform any more: smoke_probes wants 200 from the three
# public https routes and 301 from the two cleartext :80 redirect probes. A
# stub that answered 200 to everything would fail the deploy on its own
# redirect check -- and, worse, would pass a build that had broken the
# redirect.
for a in "$@"; do
  case "$a" in
    http://*) echo 301; exit 0 ;;
  esac
done
echo 200
STUB
chmod +x "$STUB_DIR/curl"

# --- I2: a rollback whose TARGET IS the recorded CURRENT must PRESERVE the
#     existing PREVIOUS, not overwrite it with the target.
#
# This is the auto-rollback's NORMAL path: deploy.sh picks CURRENT precisely
# because .release-state has not been advanced, so TARGET == CURRENT every
# time. Setting PREVIOUS to the old CURRENT there writes
# `CURRENT=goodtag PREVIOUS=goodtag` and makes oldertag unreachable -- after
# which the operator's blank-tag manual rollback resolves to the release
# already serving, verifies fine, and reports green having changed nothing.
#
# Driven directly rather than through a failing deploy, and with the
# 200-returning curl stub, so rollback.sh actually REACHES its state write.
# Asserted from the fixture's own distinct values (goodtag/oldertag), so the
# check fails if the write collapses them onto one tag.
setup_proj
printf 'CURRENT=goodtag\nPREVIOUS=oldertag\n' > "$PROJ/.release-state"
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
bash "$PROJ/scripts/rollback.sh" goodtag >/dev/null 2>&1
check "a rollback to CURRENT reached its state write" "0" "$?"
check "a rollback to CURRENT leaves CURRENT at the target" "CURRENT=goodtag" \
  "$(grep '^CURRENT=' "$PROJ/.release-state" || true)"
check "a rollback to CURRENT PRESERVES the older PREVIOUS" "PREVIOUS=oldertag" \
  "$(grep '^PREVIOUS=' "$PROJ/.release-state" || true)"

# --- smoke_probes emits both public https and :80 redirect probes ---------
# smoke_probes lives in services.sh, which rollout.test.sh deliberately does
# NOT source at top level (see the reconcile_command comment above: sourcing
# it would give release_current a definition and change that test's result).
# Sourced inside each command substitution instead, so the function exists
# only for that subshell and never leaks into the rest of the suite.
# shellcheck source=SCRIPTDIR/services.sh
out=$(source ./services.sh && smoke_probes api.example.test app.example.test probe/t.txt)
check "smoke_probes emits five probes" "5" "$(grep -c . <<<"$out")"
check "three probes are public https" "3" \
  "$(grep -c '^https://' <<<"$out" || true)"
check "two probes exercise the :80 redirect" "2" \
  "$(grep -c '^http://127.0.0.1/' <<<"$out" || true)"
# 301 is the PASS for these, not 200. Asserted explicitly: a copy-paste that
# left them at 200 would make the deploy auto-roll-back a perfectly good
# release every time, and the suite must not agree that that is correct.
check "the redirect probes want 301 and carry a Host header field" "2" \
  "$(grep -cE '^http://127\.0\.0\.1/[^|]*\|301\|[a-z.]+$' <<<"$out" || true)"
check "no probe expects a 200 from cleartext :80" "0" \
  "$(grep -cE '^http://[^|]*\|200' <<<"$out" || true)"
# Both redirect lines carry the overridden gateway URL, hence 2, not 1.
# shellcheck source=SCRIPTDIR/services.sh
check "the gateway URL is overridable" "2" \
  "$( { source ./services.sh; smoke_probes a.test b.test t.txt http://127.0.0.1:9999; } | grep -c '9999' || true)"

# ---------------------------------------------------------------------------
# service_labels_match: the guard for Traefik's "one service, one definition"
# rule. Traefik discards a service outright when its containers disagree, so a
# roll that creates a container with different service labels 404s the host for
# the whole rollout. Detecting drift BEFORE creating anything is the only gate
# that can prevent it -- by the time a health check runs, the damage is done.
# ---------------------------------------------------------------------------

stage_labels() { # stage_labels <compose-json> <container>=<labels>...
  : > "$STUB_DIR/labels"
  printf '%s' "$1" > "$STUB_DIR/compose_json"; shift
  for pair in "$@"; do
    c="${pair%%=*}"
    # every line must carry the container prefix; the stub looks up by line
    printf '%s\n' "${pair#*=}" | while IFS= read -r l; do
      [ -n "$l" ] && printf '%s %s\n' "$c" "$l" >> "$STUB_DIR/labels"
    done
  done
}

DESIRED_JSON='{"services":{"web":{"labels":["traefik.enable=true","traefik.http.services.web.loadbalancer.server.port=5000","traefik.http.services.web.loadbalancer.healthcheck.status=200"]}}}'
MATCHING='traefik.http.services.web.loadbalancer.server.port=5000
traefik.http.services.web.loadbalancer.healthcheck.status=200'
DRIFTED='traefik.http.services.web.loadbalancer.server.port=5000'

write_docker_stub
printf 'chatbot-web-1\nchatbot-web-2\n' > "$STUB_DIR/ps"

stage_labels "$DESIRED_JSON" "chatbot-web-1=$MATCHING" "chatbot-web-2=$MATCHING"
service_labels_match web >/dev/null 2>&1
check "identical labels on every replica match" "0" "$?"

stage_labels "$DESIRED_JSON" "chatbot-web-1=$DRIFTED" "chatbot-web-2=$DRIFTED"
service_labels_match web >/dev/null 2>&1
check "a label missing on ALL replicas is drift" "1" "$?"

stage_labels "$DESIRED_JSON" "chatbot-web-1=$MATCHING" "chatbot-web-2=$DRIFTED"
service_labels_match web >/dev/null 2>&1
check "a label missing on ONE replica is drift" "1" "$?"

stage_labels "$DESIRED_JSON" "chatbot-web-1=$DRIFTED" "chatbot-web-2=$DRIFTED"
out=$(service_labels_match web 2>&1)
case "$out" in
  *healthcheck.status=200*) got=named ;;
  *) got="$out" ;;
esac
check "drift message names the differing label" "named" "$got"

# assert_service_labels: the preflight wrapper over every rolled service
stage_labels "$DESIRED_JSON" "chatbot-web-1=$MATCHING" "chatbot-web-2=$MATCHING"
assert_service_labels web >/dev/null 2>&1
check "assert passes when labels match" "0" "$?"

stage_labels "$DESIRED_JSON" "chatbot-web-1=$DRIFTED" "chatbot-web-2=$DRIFTED"
: > "$STUB_DIR/calls.log"
assert_service_labels web >/dev/null 2>&1
check "assert fails on drift" "1" "$?"
mutating=$(grep -cE "compose .* (up|stop|rm) |^stop |^rm " "$STUB_DIR/calls.log" 2>/dev/null || true)
check "assert mutates nothing when it refuses" "0" "$mutating"

# reconcile_command must name the tag, or an operator copy-pasting it scales up
# a replica at whatever .env says -- `latest` per .env.example, which CI pushes
# on every build of main. The `--scale <svc>=<n> <svc>` substring is matched
# verbatim elsewhere in this suite and must survive intact.
reconciled=$(reconcile_command web 2)
check "reconcile_command keeps the --scale substring" "1" \
  "$(grep -cF -- '--scale web=2 web' <<<"$reconciled" || true)"
check "reconcile_command names an explicit IMAGE_TAG" "1" \
  "$(grep -c '^IMAGE_TAG=' <<<"$reconciled" || true)"
# rollout.sh is sourced here WITHOUT services.sh, so release_current does not
# exist: the command must still print, with a placeholder rather than a silent
# `latest`.
check "reconcile_command never emits a bare latest" "0" \
  "$(grep -c 'IMAGE_TAG=latest' <<<"$reconciled" || true)"

# ---------------------------------------------------------------------------
# sync-service-labels.sh must pin IMAGE_TAG to the DEPLOYED release.
#
# It runs `compose up --force-recreate`, which replaces every replica. With no
# IMAGE_TAG exported, compose interpolates it from the server's .env -- `latest`
# -- so the documented remedy for label drift would silently replace the running
# release with the newest unreleased build of main.
# ---------------------------------------------------------------------------
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2
# Labels already agree, so the script's own post-check passes and the exit
# status under test is the tag resolution, not the drift verdict.
stage_labels "$DESIRED_JSON" "chatbot-web-1=$MATCHING" "chatbot-web-2=$MATCHING"
printf 'CURRENT=deployedtag\nPREVIOUS=oldertag\n' > "$PROJ/.release-state"
out=$(env -u IMAGE_TAG bash "$PROJ/scripts/sync-service-labels.sh" web 2>&1); rc=$?
check "sync-service-labels.sh succeeds with a resolvable CURRENT" "0" "$rc"
check "it announces the tag it pinned" "1" \
  "$(grep -c 'IMAGE_TAG=deployedtag' <<<"$out" || true)"
check "every compose call saw the deployed tag exported" "0" \
  "$(grep -c 'IMAGE_TAG=<unset>' "$STUB_DIR/env.log" || true)"
check "the force-recreate itself ran at the deployed tag" "1" \
  "$(grep -cF -- 'IMAGE_TAG=deployedtag compose -f docker-compose.production.yml up -d --no-deps --force-recreate web' \
     "$STUB_DIR/env.log" || true)"

# ...and with no resolvable CURRENT it must REFUSE, before running anything.
# There is no safe default: `latest` is the specific wrong answer.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2
rm -f "$PROJ/.release-state"
err=$(env -u IMAGE_TAG bash "$PROJ/scripts/sync-service-labels.sh" web 2>&1 >/dev/null); rc=$?
check "sync-service-labels.sh refuses with no resolvable CURRENT" "1" "$rc"
check "the refusal says why" "1" \
  "$(grep -c 'cannot determine the deployed release tag' <<<"$err" || true)"
check "the refusal ran NO compose command" "0" \
  "$(grep -c '^compose ' "$STUB_DIR/calls.log" || true)"
check "the refusal touched no container at all" "0" \
  "$(grep -c . "$STUB_DIR/calls.log" || true)"

# ---------------------------------------------------------------------------
# A failed pg_dump must not be recorded as a successful backup.
#
# The old form was `sh -c "pg_dump ... | gzip > f" || echo WARNING`. A pipeline
# takes its LAST command's status, and gzip succeeds on empty input -- so a
# pg_dump that failed outright still exited 0 and left a valid, restorable-
# looking 20-byte archive. The warning was unreachable, and the 14-file
# retention sweep two lines down would then rotate a REAL backup out to make
# room for the empty one.
# ---------------------------------------------------------------------------

# The premise, proved against this machine's shells rather than asserted: a
# bare pipeline hides the failure, and `set -o pipefail` exposes it. If this
# first check ever fails, the fix in deploy.sh is unnecessary; if the second
# does, it is broken.
sh -c 'false | gzip > /dev/null' 2>/dev/null
check "a bare pipeline reports gzip's success, hiding a failed dump" "0" "$?"
bash -c 'set -o pipefail; false | gzip > /dev/null' 2>/dev/null
check "set -o pipefail surfaces the failed dump" "1" "$?"

# deploy.sh must send that option, under a shell that HAS it. `sh` in the
# postgres image is dash, which only gained pipefail in 0.5.12 -- on anything
# older the option is itself an error and every backup would report failure.
backup_cmd=$(grep -A2 'backup_file=' ../deploy.sh | grep -F 'pg_dump')
check "the dump runs under bash, not sh" "1" \
  "$(grep -c 'bash -c' <<<"$backup_cmd" || true)"
check "the dump command sets pipefail" "1" \
  "$(grep -c 'set -o pipefail' <<<"$backup_cmd" || true)"

# ...and deploy.sh must actually branch on the status it now gets.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
echo 1 > "$STUB_DIR/pg_dump_rc"
out=$(bash "$PROJ/scripts/deploy.sh" testtag 2>&1); rc=$?
check "a failed backup is reported, not swallowed" "1" \
  "$(grep -c 'WARNING: backup failed' <<<"$out" || true)"
check "the partial archive is removed" "1" \
  "$(grep -c 'rm -f .*/backups/.*\.sql\.gz' "$STUB_DIR/calls.log" || true)"
check "a failed backup does not claim the backup was written" "0" \
  "$(grep -c 'backup written to' <<<"$out" || true)"
# Non-fatal by design, as it always was: a deploy must not be blocked by the
# backup, only honest about it.
check "a failed backup does not abort the deploy" "0" "$rc"

setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
out=$(bash "$PROJ/scripts/deploy.sh" testtag 2>&1) || true
check "a successful backup says so" "1" \
  "$(grep -c 'backup written to' <<<"$out" || true)"
check "a successful backup removes nothing" "0" \
  "$(grep -c 'rm -f .*/backups/' "$STUB_DIR/calls.log" || true)"

# ---------------------------------------------------------------------------
# service_containers counts REPLICAS, never `compose run` one-offs.
#
# Compose names a one-off `chatbot-<service>-run-<hash>`, and deploy.sh runs
# three against `web` (collectstatic, migrate, the media probe). Under the old
# `^chatbot-web-` prefix match a one-off still running when a roll starts made
# assert_steady_replicas report 3 and refuse, and made roll_service's
# before/new set arithmetic wrong.
# ---------------------------------------------------------------------------
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 chatbot-web-run-a1b2c3
check "a compose one-off is not counted as a replica" "2" \
  "$(service_replica_count web)"
check "a compose one-off is not listed as a replica" "0" \
  "$(service_containers web | grep -c -- '-run-' || true)"
# The neighbouring service must still be matched exactly, not by prefix.
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 chatbot-worker-1
check "replicas of the named service are still counted" "2" \
  "$(service_replica_count web)"
check "a different service is not counted" "1" "$(service_replica_count worker)"

# The whole point: with a one-off running, the deploy preflight must still see
# a clean steady state rather than refusing.
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 chatbot-web-run-a1b2c3 \
  chatbot-dashboard-1 chatbot-dashboard-2
assert_steady_replicas "web 2 40 true" "dashboard 2 30 false" >/dev/null 2>&1
check "the preflight is not tripped by a running one-off" "0" "$?"

# ---------------------------------------------------------------------------
# envval strips only a MATCHED surrounding quote pair.
#
# It used to be `tr -d "\"'"`, which deletes every quote character anywhere in
# the value -- so a password of a'b"c silently became abc and the caller
# authenticated with a credential nobody had configured.
# ---------------------------------------------------------------------------
ENVDIR="$STUB_DIR/envval"; mkdir -p "$ENVDIR"
cat > "$ENVDIR/.env" <<'ENVFILE'
PLAIN=hello
DQUOTED="hello world"
SQUOTED='hello world'
INNERQUOTE=ab'cd"ef
URLISH=postgres://u:p@db:5432/name?sslmode=require
EMPTY=
ENVFILE
# Subshell so services.sh's APP_SERVICES cannot leak into the suite's state.
# The path is resolved before the cd, so the `source=` directive below has a
# literal for shellcheck to follow -- `$OLDPWD/services.sh` does not.
SERVICES_SH="$PWD/services.sh"
envval_at() (
  cd "$ENVDIR" || return 1
  # shellcheck source=SCRIPTDIR/services.sh
  . "$SERVICES_SH"
  envval "$1"
)
check "an unquoted value is unchanged"      "hello"       "$(envval_at PLAIN)"
check "a double-quoted value is unwrapped"  "hello world" "$(envval_at DQUOTED)"
check "a single-quoted value is unwrapped"  "hello world" "$(envval_at SQUOTED)"
check "an INNER quote survives"             "ab'cd\"ef"   "$(envval_at INNERQUOTE)"
check "a value containing = is not split"   "postgres://u:p@db:5432/name?sslmode=require" \
  "$(envval_at URLISH)"
check "a missing key yields empty"          ""            "$(envval_at NOSUCHKEY)"
check "an empty value yields empty"         ""            "$(envval_at EMPTY)"

# ---------------------------------------------------------------------------
# A rollback must survive an unreachable registry.
#
# `docker compose pull` under `set -e` used to end rollback.sh outright, so a
# ghcr.io outage, an expired credential or a DNS failure removed the recovery
# path at exactly the moment it was needed -- for a step that is usually
# unnecessary, since rolling BACK targets a release that was recently running
# on this host and whose images are therefore already in the local store.
#
# Both directions matter. Continuing when the images are present is the fix;
# still refusing when they are NOT is what keeps it safe, because compose would
# otherwise create containers that cannot start.
# ---------------------------------------------------------------------------
RB_JSON='{"services":{"web":{"image":"ghcr.io/etqan-agency/chatbot-zaychain/api:rbtag"},"worker":{"image":"ghcr.io/etqan-agency/chatbot-zaychain/api:rbtag"},"dashboard":{"image":"ghcr.io/etqan-agency/chatbot-zaychain/dashboard:rbtag"}}}'

# Baseline: a working registry still takes the ordinary path.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
printf '%s' "$RB_JSON" > "$STUB_DIR/compose_json"
printf 'CURRENT=rbtag\nPREVIOUS=older\n' > "$PROJ/.release-state"
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
out=$(bash "$PROJ/scripts/rollback.sh" rbtag 2>&1); rc=$?
check "a rollback with a reachable registry succeeds" "0" "$rc"
check "it does not warn about the registry when the pull worked" "0" \
  "$(grep -c 'could not pull' <<<"$out" || true)"

# The registry is unreachable but both images are on the host: proceed, loudly.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
printf '%s' "$RB_JSON" > "$STUB_DIR/compose_json"
printf 'CURRENT=rbtag\nPREVIOUS=older\n' > "$PROJ/.release-state"
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
echo 1 > "$STUB_DIR/pull_rc"
out=$(bash "$PROJ/scripts/rollback.sh" rbtag 2>&1); rc=$?
check "an unreachable registry does NOT abort the rollback" "0" "$rc"
check "it says the pull failed" "1" "$(grep -c 'could not pull' <<<"$out" || true)"
check "it says it is using the local images" "1" \
  "$(grep -c 'images already on this host' <<<"$out" || true)"
check "it still rolled web" "1" \
  "$(grep -cF -- '--scale web=4 web' "$STUB_DIR/calls.log" || true)"
check "it still reached its own verification" "1" \
  "$(grep -c '>>> verifying' <<<"$out" || true)"

# The registry is unreachable AND an image is missing locally: refuse, before
# creating anything, and name the image that is missing.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
printf '%s' "$RB_JSON" > "$STUB_DIR/compose_json"
printf 'CURRENT=rbtag\nPREVIOUS=older\n' > "$PROJ/.release-state"
echo 1 > "$STUB_DIR/pull_rc"
# Only the api image is present; the dashboard image is not.
printf '%s\n' ghcr.io/etqan-agency/chatbot-zaychain/api:rbtag > "$STUB_DIR/local_images"
: > "$STUB_DIR/calls.log"
err=$(bash "$PROJ/scripts/rollback.sh" rbtag 2>&1 >/dev/null); rc=$?
check "a missing image with no registry refuses" "1" "$rc"
check "the refusal names the missing image" "1" \
  "$(grep -c 'MISSING: ghcr.io/etqan-agency/chatbot-zaychain/dashboard:rbtag' <<<"$err" || true)"
check "the refusal creates no container" "0" \
  "$(grep -cF -- '--scale' "$STUB_DIR/calls.log" || true)"
check "the refusal stops no container" "0" \
  "$(grep -c '^stop ' "$STUB_DIR/calls.log" || true)"

# The registry is unreachable AND the image list cannot be determined.
#
# The list is derived from `compose config --format json`, whose failures were
# swallowed: an unrenderable compose file yielded an EMPTY list, the
# present/missing loop then ran zero times, `missing` stayed empty, and the
# script announced "proceeding with the images already on this host" -- having
# verified nothing at all. A guard that reports success when it could not run
# is worse than no guard, because it is the pull failure path, so it only ever
# executes when something is already wrong.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
: > "$STUB_DIR/compose_json"   # config renders nothing
printf 'CURRENT=rbtag\nPREVIOUS=older\n' > "$PROJ/.release-state"
echo 1 > "$STUB_DIR/pull_rc"
: > "$STUB_DIR/calls.log"
err=$(bash "$PROJ/scripts/rollback.sh" rbtag 2>&1 >/dev/null); rc=$?
check "an undeterminable image list with no registry refuses" "1" "$rc"
check "it does not claim the local images are fine" "0" \
  "$(grep -c 'images already on this host' <<<"$err" || true)"
check "the refusal says the image list could not be determined" "1" \
  "$(grep -c 'could not determine which images' <<<"$err" || true)"
check "the undeterminable list creates no container" "0" \
  "$(grep -cF -- '--scale' "$STUB_DIR/calls.log" || true)"

# ---------------------------------------------------------------------------
# The check-vhost-drift.sh suite lived here. It is gone with the script: the
# host nginx it policed no longer exists, and Traefik's configuration is all
# under traefik/ where CD syncs it and drift is impossible.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# wait_backends_settled: EXACTLY `expected`, not "at least".
#
# The distinction is the whole point. wait_backends_up returns as soon as there
# are enough NEW backends; this must not return while an OLD one is still in
# the pool, because a request dispatched to a container whose IP has already
# been removed from the bridge is silently dropped -- no RST -- and hangs until
# the client times out. That is what made a good release fail its own smoke
# check and auto-roll-back.
# ---------------------------------------------------------------------------
TWO_UP='{"serverStatus":{"http://a:5000":"UP","http://b:5000":"UP"}}'
MIXED='{"serverStatus":{"http://a:5000":"UP","http://b:5000":"UP","http://c:5000":"DOWN"}}'

make_docker_stub "$TWO_UP"
SETTLE_TIMEOUT_SECS=0 wait_backends_settled web 2 >/dev/null 2>&1
check "settled returns when the pool is exactly the expected size" "0" "$?"

make_docker_stub "$FOUR_UP"
SETTLE_TIMEOUT_SECS=0 wait_backends_settled web 2 >/dev/null 2>&1
check "settled does NOT return while an old backend is still UP" "1" "$?"

# The counterpart it must not be confused with: wait_backends_up is satisfied
# by a pool that is too LARGE, which is exactly the state that hangs a probe.
make_docker_stub "$FOUR_UP"
wait_backends_up web 2 2 >/dev/null 2>&1
check "wait_backends_up is satisfied by an oversized pool" "0" "$?"

# A DOWN backend is not in the pool, so it must not count towards the total.
make_docker_stub "$MIXED"
SETTLE_TIMEOUT_SECS=0 wait_backends_settled web 2 >/dev/null 2>&1
check "settled counts only UP backends" "0" "$?"

# On timeout it WARNS and returns 1 -- roll_service ignores that status on
# purpose, so this must never become a hard failure that aborts a completed
# roll.
make_docker_stub "$FOUR_UP"
warn=$(SETTLE_TIMEOUT_SECS=0 wait_backends_settled web 2 2>&1 >/dev/null)
check "the timeout explains itself" "1" \
  "$(grep -c 'has not finished retiring the old generation' <<<"$warn" || true)"

# ---------------------------------------------------------------------------
# A running gateway must not predate its own static configuration.
#
# traefik.yml is STATIC config: Traefik reads it once at process start. Only
# traefik/dynamic/ hot-reloads. cd.yml rsyncs traefik/ to the server, but
# nothing in a deploy recreates the Traefik container -- so a changed
# traefik.yml sits on disk, unread, while the deploy reports success and the
# committed configuration and the running one quietly disagree.
#
# That is not hypothetical: the providers.docker constraint that stops Traefik
# discovering a co-tenant project's containers landed exactly this way, and
# would have been inert until someone happened to recreate the container.
#
# The signal is mtime vs the container's StartedAt. It only means anything
# because cd.yml rsyncs traefik/ with --checksum: without it rsync retransmits
# on every run (a fresh checkout has fresh mtimes), the file always looks newer
# than the container, and the guard cries wolf on every deploy.
# ---------------------------------------------------------------------------

stage_gateway() { # stage_gateway <config-mtime> <container-started>
  mkdir -p "$STUB_DIR/gw"
  : > "$STUB_DIR/gw/traefik.yml"
  touch -d "$1" "$STUB_DIR/gw/traefik.yml"
  printf '%s\n' "$2" > "$STUB_DIR/started_at"
}

reset_stub "$FOUR_UP" chatbot-web-1

stage_gateway "2026-01-01T00:00:00Z" "2026-06-01T00:00:00Z"
assert_gateway_config_applied "$STUB_DIR/gw/traefik.yml" >/dev/null 2>&1
check "a gateway started AFTER its config is accepted" "0" "$?"

stage_gateway "2026-06-01T00:00:00Z" "2026-01-01T00:00:00Z"
assert_gateway_config_applied "$STUB_DIR/gw/traefik.yml" >/dev/null 2>&1
check "a gateway older than its static config is refused" "1" "$?"

err=$(assert_gateway_config_applied "$STUB_DIR/gw/traefik.yml" 2>&1 >/dev/null)
check "the refusal names the recreate command" "1" \
  "$(grep -cF -- '--force-recreate traefik' <<<"$err" || true)"
check "the refusal explains that static config does not hot-reload" "1" \
  "$(grep -ci 'hot-reload\|does not reload' <<<"$err" || true)"

# Equal timestamps are the boundary: a container started in the same second as
# the file was written did read it. Refusing there would fail a legitimate
# deploy on a coincidence.
stage_gateway "2026-06-01T00:00:00Z" "2026-06-01T00:00:00Z"
assert_gateway_config_applied "$STUB_DIR/gw/traefik.yml" >/dev/null 2>&1
check "an equal timestamp is not treated as drift" "0" "$?"

# Inability to check must not block a deploy. The gateway being absent is
# already caught, loudly, by assert_edge_publication just above it.
stage_gateway "2026-06-01T00:00:00Z" ""
: > "$STUB_DIR/started_at"
assert_gateway_config_applied "$STUB_DIR/gw/traefik.yml" >/dev/null 2>&1
check "an unreadable start time does not block the deploy" "0" "$?"

stage_gateway "2026-01-01T00:00:00Z" "2026-06-01T00:00:00Z"
assert_gateway_config_applied "$STUB_DIR/gw/does-not-exist.yml" >/dev/null 2>&1
check "a missing config file is refused" "1" "$?"

# deploy.sh must enforce it, and enforce it in the PREFLIGHT. A stale gateway
# config discovered after the backup, collectstatic, migrate and the worker
# roll would leave the operator with a half-applied deploy to reason about, on
# top of a gateway that is not running the configuration they think it is.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
# The gateway started long before setup_proj wrote traefik/traefik.yml.
printf '2020-01-01T00:00:00Z\n' > "$STUB_DIR/started_at"
err=$(bash "$PROJ/scripts/deploy.sh" testtag 2>&1 >/dev/null); rc=$?
check "deploy.sh refuses a gateway running stale static config" "1" "$rc"
check "the refusal names traefik.yml" "1" \
  "$(grep -c 'traefik/traefik.yml is newer' <<<"$err" || true)"
check "the refusal prints the recreate command" "1" \
  "$(grep -cF -- '--force-recreate traefik' <<<"$err" || true)"
check "it refused BEFORE pulling images" "0" \
  "$(grep -c '^compose -f .* pull' "$STUB_DIR/calls.log" || true)"
check "it refused BEFORE the backup" "0" \
  "$(grep -c 'pg_dump' "$STUB_DIR/calls.log" || true)"
check "it refused BEFORE migrate" "0" \
  "$(grep -c 'migrate' "$STUB_DIR/calls.log" || true)"
check "it stopped no container" "0" \
  "$(grep -c '^stop ' "$STUB_DIR/calls.log" || true)"

# ...and a gateway newer than its config deploys normally, or the guard is a
# tripwire nobody can deploy past.
setup_proj
reset_stub "$FOUR_UP" chatbot-web-1 chatbot-web-2 \
  chatbot-dashboard-1 chatbot-dashboard-2 chatbot-worker-1
# The label fixtures are global and the tests above leave them mismatched, so
# without this the deploy aborts at the service-label parity gate and this case
# would pass or fail for a reason that has nothing to do with the gateway.
stage_labels '{"services":{}}'
echo chatbot-worker-9 > "$STUB_DIR/up_creates"
out=$(bash "$PROJ/scripts/deploy.sh" testtag --skip-backup 2>&1); rc=$?
check "a current gateway config does not block the deploy" "0" "$rc"
check "the preflight says so" "1" \
  "$(grep -c 'running its current static configuration' <<<"$out" || true)"

echo "---"; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
