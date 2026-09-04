#!/usr/bin/env bash
# The application's Traefik-fronted service table. Sourced by deploy.sh and
# rollback.sh; deliberately NOT part of rollout.sh, which stays app-agnostic.
#
# ONE definition, used for both the preflight replica assertion and the rolls
# themselves, so the count the preflight proves and the count roll_service
# demands cannot drift apart.
#
# Each entry is "<service> <steady> <stop_timeout> <drainable>", in roll order:
#
#   steady        replicas the service runs at outside a rollout. Must match
#                 `deploy.replicas` in docker-compose.production.yml.
#   stop_timeout  seconds given to SIGTERM before SIGKILL. web is 40, not 30:
#                 gunicorn's --graceful-timeout is 30, so -t 30 lands SIGKILL at
#                 the exact instant gunicorn would have finished draining.
#   drainable     whether the app has a drain-aware health route -- one that
#                 returns 503 while DRAIN_FILE exists, so Traefik pulls the
#                 replica from rotation before it is stopped. Only web does:
#                 chatbot_api/Conf/views.py's `health`. A service marked true
#                 here MUST have that route in the image being deployed, or
#                 retire_container waits out the settle window against a probe
#                 that never fails and the stop is as abrupt as before.
#
# ORDER MATTERS, and not only for the usual reason. The dashboard's nginx
# proxies /api/ straight to `web:8000` over Docker DNS, bypassing Traefik, and
# caches that resolution for 10s. Retiring a web replica therefore leaves up to
# 10s of dead IPs in each running dashboard container's resolver cache. Rolling
# `dashboard` immediately afterwards replaces those containers with ones that
# have empty caches, which bounds the exposure to the gap between the two rolls
# rather than to the DNS TTL of long-lived containers. See docs/DEPLOY.md.
# `export` here is for shellcheck's benefit, not bash's: this file is always
# sourced into the caller's shell, never exec'd, so the array is already in
# scope without it. Without the marker, `shellcheck -x` on services.sh in
# isolation flags APP_SERVICES as SC2034 unused -- it cannot see that
# deploy.sh and rollback.sh consume it after sourcing this file.
export APP_SERVICES
APP_SERVICES=(
  "web 2 40 true"
  "dashboard 2 30 false"
)

# Read one key from the server's .env. Deliberately not `source .env`: that file
# is compose syntax, not bash, and a value containing a space or an unbalanced
# quote would abort a deploy on the source line, before the preflight can say
# anything useful.
#
# The trailing `|| true` matters under the callers' `set -o pipefail`: a key
# absent from .env makes `grep` exit 1, and pipefail promotes that to the whole
# pipeline's exit status even though `head`/`cut`/`tr` all succeed on the empty
# input. Without it, `pg_user="$(envval POSTGRES_USER)"` and the like would
# abort the script on a merely-missing optional key, before the `:-default`
# fallback the caller writes ever runs.
envval() { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'" || true; }

# The probes that gate a deploy and verify a rollback, as "<url>|<want>".
# ONE definition, so a rollback can never verify less than the deploy gated on.
#
# The media probe is not optional: it is the only check that exercises the
# priority router and the shared volume mount, and /media/ is the one route that
# silently regressed when the all-in-one nginx was replaced.
smoke_probes() {
  local domain="$1" media_path="$2"
  printf '%s\n' \
    "https://api.${domain}/health/|200" \
    "https://app.${domain}/|200" \
    "https://api.${domain}/media/${media_path}|200"
}

# `media` is deliberately absent. It is a single replica serving a read-only
# volume mount with no in-flight application state, and its image and config
# change only when the deployment config does. It is brought up alongside the
# data tier with --no-deps, not rolled. Adding it here would demand a second
# replica and a drain route for a static file server that has neither reason
# for one.
