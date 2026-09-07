#!/usr/bin/env bash
# Compare the vhosts in docs/nginx/ against the ones nginx is actually serving.
#
#   bash scripts/check-vhost-drift.sh [--live-dir DIR] [--quiet]
#
# Exit 0 in sync, 1 drifted, 2 could not check.
#
# docs/nginx/*.conf are reference copies. The live files are under
# /etc/nginx/sites-available/, outside DEPLOY_PATH and root-owned, so CD cannot
# deploy them and the two are kept in step by hand. Every other file in this
# repository is synced by the pipeline and drifts loudly; these two drift
# silently, which is the only reason this script exists.
#
# It compares BEHAVIOUR, not bytes. A byte diff would be permanently red for
# two reasons that are both correct:
#
#   * The shipped copy keeps its :443 block commented out, because that is
#     step 1 of a two-phase install -- a `listen 443 ssl` block naming a
#     certificate that does not exist yet takes nginx down for every site on
#     the host. This script uncomments it the same way the install does,
#     through scripts/e2e/uncomment-tls.sh.
#
#   * TLS plumbing legitimately differs per host. The shipped copy inlines
#     certbot's TLS settings so it stands up on a host that has only ever run
#     `certonly --webroot`; a host that has previously run `certbot --nginx`
#     has /etc/letsencrypt/options-ssl-nginx.conf and may `include` it instead.
#     Both are correct. Neither changes how a request is routed.
#
# What it does compare is the set of directives whose drift causes incidents:
# where traffic is proxied, which hostnames are answered, which ports are
# listened on, the upload ceiling, the proxy timeouts, and the forwarded
# headers the rate limiters key tenant identity off. Those are the lines that
# are edited on the server at 2am and never make it back into the repository.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

LIVE_DIR="/etc/nginx/sites-available"
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --live-dir) LIVE_DIR="${2:?--live-dir needs a directory}"; shift 2 ;;
    --quiet)    QUIET=true; shift ;;
    -h|--help)  sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = true ] || echo "$@"; }

# The directives that decide what a request does. Anything not listed here --
# TLS ciphers, session caches, comments, ACME locations -- is deliberately out
# of scope; see the header.
BEHAVIOURAL='^(server_name|listen|proxy_pass|proxy_http_version|client_max_body_size|proxy_read_timeout|proxy_send_timeout|proxy_set_header|location|return|root|alias) '

# Reduce a vhost to a sorted set of behavioural directives.
#
# `location / {` keeps its brace so a location's disappearance is visible; the
# trailing `{` is normalised to a single trailing space-brace so indentation
# differences do not register as drift.
normalize() {
  sed -e 's/#.*$//' \
      -e 's/^[[:space:]]*//' \
      -e 's/[[:space:]]*$//' \
      -e 's/[[:space:]][[:space:]]*/ /g' \
      -e 's/;$//' \
    | grep -E "$BEHAVIOURAL" \
    | LC_ALL=C sort -u
}

drift=0
checked=0

for repo_conf in docs/nginx/*.conf; do
  [ -f "$repo_conf" ] || continue

  # Derive the live filename from the vhost's own server_name rather than a
  # hardcoded table: a table is one more thing that can drift, and it would
  # drift silently in exactly the same way.
  host=$(grep -m1 -E '^[[:space:]]*server_name[[:space:]]' "$repo_conf" \
           | sed -e 's/^[[:space:]]*server_name[[:space:]]*//' -e 's/;.*$//' -e 's/[[:space:]].*$//')
  if [ -z "$host" ]; then
    echo "ERROR: ${repo_conf} declares no server_name; cannot find its live counterpart." >&2
    drift=1
    continue
  fi

  live_conf="${LIVE_DIR}/${host}"
  if [ ! -f "$live_conf" ]; then
    echo "ERROR: ${repo_conf} describes ${host}, but ${live_conf} does not exist." >&2
    echo "       Either the vhost was never installed, or it is installed under a" >&2
    echo "       different filename -- in which case nginx is serving something" >&2
    echo "       this repository does not describe." >&2
    drift=1
    continue
  fi

  checked=$((checked + 1))

  # The shipped copy needs its :443 block uncommented first, exactly as the
  # install does. A copy that is ALREADY uncommented is a drift finding in
  # itself: it means the file shipped in a state that cannot be installed on a
  # fresh host, so say so rather than silently skipping the transform.
  if grep -q '^#server {' "$repo_conf"; then
    repo_normalized=$(bash scripts/e2e/uncomment-tls.sh "$repo_conf" | normalize)
  else
    echo "WARNING: ${repo_conf} has no commented-out :443 block." >&2
    echo "         Installing it as-is on a host without the certificate takes" >&2
    echo "         nginx down for every site there. Comparing it as it stands." >&2
    repo_normalized=$(normalize < "$repo_conf")
  fi
  live_normalized=$(normalize < "$live_conf")

  if [ "$repo_normalized" = "$live_normalized" ]; then
    say "  ok       ${host}"
    continue
  fi

  drift=1
  echo "  DRIFTED  ${host}" >&2
  comm -23 <(printf '%s\n' "$repo_normalized") <(printf '%s\n' "$live_normalized") \
    | sed 's/^/      in repo, not on server: /' >&2
  comm -13 <(printf '%s\n' "$repo_normalized") <(printf '%s\n' "$live_normalized") \
    | sed 's/^/      on server, not in repo: /' >&2
done

# Exit 2, not 1, and the distinction is the point: 1 means "compared them and
# they disagree", 2 means "could not compare them at all". Reporting an
# unrunnable check as a finding is how a check that never ran gets mistaken for
# one that passed, or -- as here -- for one that failed on the merits.
if [ "$checked" -eq 0 ] && [ "$drift" -eq 0 ]; then
  echo "ERROR: no vhosts compared -- docs/nginx/*.conf matched nothing under $(pwd)." >&2
  echo "       On the server, CD syncs docs/nginx/ into DEPLOY_PATH for exactly" >&2
  echo "       this check; if it is missing, that sync is broken rather than the" >&2
  echo "       vhosts being in sync." >&2
  exit 2
fi

if [ "$drift" -ne 0 ]; then
  echo "" >&2
  echo "The reference copies in docs/nginx/ and the vhosts nginx is serving" >&2
  echo "disagree. Reconcile them by hand -- CD cannot do it -- and remember the" >&2
  echo "server is what is actually serving traffic, so the repository is not" >&2
  echo "automatically the correct side." >&2
  exit 1
fi

say "vhosts match the reference copies (${checked} checked)"
