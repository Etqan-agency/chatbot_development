#!/usr/bin/env bash
# Print a shipped vhost from docs/nginx/ with its :443 block uncommented --
# step 3 of the install procedure in that file's header, done mechanically.
#
#   bash scripts/e2e/uncomment-tls.sh docs/nginx/api-chatbot-demo.conf
#
# scripts/e2e.sh uses this to stand the real vhosts up against a self-signed
# certificate, which is what makes the rehearsal test the FILE THAT SHIPS
# rather than a paraphrase of it. It caught the reason this script exists: the
# block used to `include /etc/letsencrypt/options-ssl-nginx.conf`, a file that
# only certbot's nginx INSTALLER writes and that `certonly --webroot`
# therefore never creates, so step 3 failed `nginx -t` on any host that had
# never run `certbot --nginx`.
#
# Everything from the first `#server {` to end of file loses exactly one
# leading `#`. One, not all: the block contains its own commented-out lines
# (`#    # Matches the dashboard's internal nginx.`) and stripping greedily
# would uncomment prose into the configuration.
set -euo pipefail

SRC="${1:?usage: uncomment-tls.sh <vhost.conf>}"
[ -f "$SRC" ] || { echo "no such file: ${SRC}" >&2; exit 1; }

if ! grep -q '^#server {' "$SRC"; then
  echo "ERROR: ${SRC} has no commented-out '#server {' block." >&2
  echo "       Either it was already uncommented, or the file's shape changed" >&2
  echo "       and this script needs updating alongside it." >&2
  exit 1
fi

awk '
  /^#server \{/ { in_block = 1 }
  in_block      { sub(/^#/, ""); print; next }
                { print }
' "$SRC"
