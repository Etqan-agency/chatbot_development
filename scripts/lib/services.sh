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
#                 chabot_dev_api/Conf/views.py's `health`. A service marked true
#                 here MUST have that route in the image being deployed, or
#                 retire_container waits out the settle window against a probe
#                 that never fails and the stop is as abrupt as before.
#
# ORDER: web before dashboard, because dashboard is downstream of web. The
# dashboard's nginx proxies /api/ straight to `web:8000` over Docker DNS,
# bypassing Traefik, so rolling web first means the new dashboard generation
# comes up against an API already on the new release.
#
# It is NOT the roll order that bounds the stale-DNS residual, and this comment
# used to claim otherwise. What bounds it is nginx's `resolver ... valid=10s`:
# a cached entry expires 10s after it was taken, in a long-lived container as
# much as a fresh one, so a dashboard replica proxying to a retired web
# replica's dead IP does so for at most 10s and then re-resolves. Rolling
# dashboard next does not shorten that window -- the OLD dashboard replicas,
# stale caches and all, keep serving right through the new generation's
# warm-up, which is longer than 10s. The 10s bound is real; the roll order is
# not what produces it. See docs/DEPLOY.md §8.
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
# pipeline's exit status even though `head`/`cut`/`sed` all succeed on the empty
# input. Without it, `pg_user="$(envval POSTGRES_USER)"` and the like would
# abort the script on a merely-missing optional key, before the `:-default`
# fallback the caller writes ever runs.
#
# The sed strips only a MATCHED surrounding pair of quotes. `tr -d "\"'"` --
# what this used to do -- deletes every quote character anywhere in the value,
# so a password of `a'b"c` silently becomes `abc` and the caller authenticates
# with a credential nobody ever configured.
envval() {
  grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" || true
}

# The tag that is CURRENTLY DEPLOYED, from .release-state. Prints nothing when
# the file is missing, unwritten (before the first successful deploy) or has no
# CURRENT line -- callers must treat empty as "unknown" and refuse, never as a
# reason to fall back to a default.
#
# This exists because `.env`'s IMAGE_TAG is NOT the deployed tag. .env.example
# ships `IMAGE_TAG=latest`, and ci.yml pushes `type=raw,value=latest` on every
# build of main, so any compose command that does not export IMAGE_TAG creates
# containers at the newest unreleased main build -- possibly one whose
# migrations have not run. deploy.sh and rollback.sh both export IMAGE_TAG for
# exactly this reason; every other path that runs `compose up` needs a tag too,
# and this is where it comes from.
#
# `|| true` for the same pipefail reason as envval above.
release_current() {
  grep '^CURRENT=' "${STATE_FILE:-.release-state}" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# The probes that gate a deploy and verify a rollback, as "<url>|<want>".
# ONE definition, so a rollback can never verify less than the deploy gated on.
#
# Two independent hostnames, not a base domain with derived prefixes. They share
# a parent today, but nothing here may depend on that: `etqanbackend.tech` is used
# by several unrelated servers, and this host owns exactly these two names.
#
# The media probe is not optional: it is the only check that exercises the
# priority router and the shared volume mount, and /media/ is the one route that
# silently regressed when the all-in-one nginx was replaced.
smoke_probes() {
  local api_host="$1" app_host="$2" media_path="$3"
  local gateway="${4:-http://127.0.0.1}"
  printf '%s\n' \
    "https://${api_host}/health/|200" \
    "https://${app_host}/|200" \
    "https://${api_host}/media/${media_path}|200"
  # The http->https redirect, probed on the host's own :80 with an explicit
  # Host header. 301 is the PASS here, not a failure.
  #
  # These replace the old "bypass nginx and hit Traefik directly" probes, which
  # existed to tell an nginx fault apart from a broken release. There is no
  # second layer to bypass any more -- Traefik is the edge, so if it is broken
  # the application is unreachable regardless and there is nothing to
  # discriminate.
  #
  # What these catch instead is the failure that is now the silent one: :80
  # not answering. Nothing user-facing breaks when it stops, because every real
  # client is already on https -- but the ACME http-01 challenge is answered
  # there, so certificate renewal dies and the site fails everywhere at once up
  # to 60 days later. A deploy that checked only https would report success
  # every time right up to the expiry.
  printf '%s\n' \
    "${gateway}/health/|301|${api_host}" \
    "${gateway}/|301|${app_host}"
}

# `media` is deliberately absent. It is a single replica serving a read-only
# volume mount with no in-flight application state, and its image and config
# change only when the deployment config does. It is brought up alongside the
# data tier with --no-deps, not rolled. Adding it here would demand a second
# replica and a drain route for a static file server that has neither reason
# for one.
