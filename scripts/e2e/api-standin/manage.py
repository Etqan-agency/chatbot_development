#!/usr/bin/env python3
"""Enough of Django's manage.py for deploy.sh to drive.

deploy.sh runs `manage.py collectstatic --noinput` and `manage.py migrate
--noinput` as one-off `compose run` containers before it rolls anything. Both
must exist and both must exit 0, or the rehearsal never reaches the roll.

collectstatic writes a real file into /app/staticfiles so the rehearsal proves
the static_volume is actually mounted and writable, rather than proving only
that a no-op exits 0.
"""
import os
import sys

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "collectstatic":
    os.makedirs("/app/staticfiles", exist_ok=True)
    with open("/app/staticfiles/e2e.txt", "w") as fh:
        fh.write(os.environ.get("RELEASE", "unknown") + "\n")
    print("collectstatic: 1 static file copied")
elif cmd == "migrate":
    print("migrate: no migrations to apply")
else:
    print(f"manage.py: unknown command {cmd!r}", file=sys.stderr)
    sys.exit(2)
