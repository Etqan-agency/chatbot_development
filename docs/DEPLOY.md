# Deployment runbook

This is the document to read at 2am, or six months from now when every
decision below has been forgotten. It assumes no prior context: it names every
file, secret and command it depends on.

The stack is one Docker Compose project (`docker-compose.production.yml`,
pinned `name: chatbot`) fronted by Traefik on a single Ubuntu host. Deploys and
rollbacks are driven from GitHub Actions, but the scripts they call
(`scripts/deploy.sh`, `scripts/rollback.sh`, `scripts/sync-service-labels.sh`)
are ordinary bash and can be run by hand on the server if Actions is
unavailable.

## 1. Topology

Ten containers, five services never rolled and three rolled:

| Service | Replicas | Rolled? | Role |
|---|---|---|---|
| `traefik` | 1 | no | Gateway: TLS termination, routing, ACME |
| `socket-proxy` | 1 | no | Read-only Docker socket proxy for Traefik's docker provider |
| `db` | 1 | no | PostgreSQL (`pgvector/pgvector:pg16`) |
| `redis` | 1 | no | Cache + Celery broker |
| `web` | 2 | **yes** | Django API (gunicorn) |
| `worker` | 1 | **yes** (separately) | Celery worker |
| `media` | 1 | no | nginx serving `/media/` read-only from the shared volume |
| `dashboard` | 2 | **yes** | Static SPA served by nginx |

`web` and `dashboard` are rolled in that order by the same `deploy.sh` run.
`worker` is rolled on its own, before them, with a 360s warm-shutdown window
(Celery treats SIGTERM as "finish the current task, stop prefetching"; a
gunicorn/nginx stop timeout would kill it mid-task). `media`, `db`, `redis`,
`traefik` and `socket-proxy` are never rolled: `media` is a single replica
serving a read-only mount with no in-flight state, and the rest are
infrastructure that isn't safe or meaningful to roll this way.

Two hostnames, both derived from one `DOMAIN` value:

- **`api.${DOMAIN}`** serves the Django API on the `api` router, and `/media/`
  on a separate `media` router with **priority 100** (higher than `api`'s
  default rule-length priority), so a request for `/media/...` on that host
  goes to the `media` service, not to `web`.
- **`app.${DOMAIN}`** serves the React SPA (`dashboard`). The dashboard's own
  nginx proxies `/api/` **same-origin**, straight to `web:8000` over Docker
  DNS — this request never goes through Traefik. See §8 for why that matters.

## 2. Provisioning a host

Spec: `chatbot_api/docs/superpowers/specs/2026-09-03-infrastructure-pipeline-design.md`
§7. Run these once, in order, before the first deploy.

1. **Ubuntu 22.04+, 4 vCPU / 8 GB RAM, plus a swap file at least half of
   RAM** (`sudo fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap
   /swapfile && swapon /swapfile`, then add it to `/etc/fstab`). 8 GB, not 4:
   `deploy.sh`'s preflight refuses to start a deploy below 1200 MiB free, and a
   roll of `web` or `dashboard` briefly runs **two generations at once** (4
   containers of a 2-replica service instead of 2), so peak memory during a
   rollout is roughly double steady state. A 4 GB host boots fine and then
   fails partway through the first real rollout, which is the worst place to
   discover it.

2. **Install Docker Engine and the Compose v2 plugin** (the official
   `get.docker.com` script installs both; `docker compose version` must report
   v2).

3. **Firewall:**
   ```bash
   sudo ufw allow OpenSSH
   sudo ufw allow 80
   sudo ufw allow 443
   sudo ufw enable
   ```

4. **Create the `deploy` user and add it to the `docker` group:**
   ```bash
   sudo adduser --disabled-password deploy
   sudo usermod -aG docker deploy
   ```

5. **Generate a deploy keypair, then wire it into three places:**
   ```bash
   ssh-keygen -t ed25519 -C 'chatbot-deploy' -f ./chatbot_deploy_key
   ```
   - Public half (`chatbot_deploy_key.pub`) → appended to the `deploy` user's
     `~/.ssh/authorized_keys` on the server.
   - Private half (`chatbot_deploy_key`) → the `SSH_PRIVATE_KEY` repository
     secret.
   - `ssh-keyscan <host>` → the `SSH_KNOWN_HOSTS` repository secret. Without
     this, CD's SSH step has nothing to pin the host key against.

6. **Create `DEPLOY_PATH` and get the meta-repo onto the server.** Either
   `git clone` it by hand into `DEPLOY_PATH`, or leave the directory empty and
   let the first CD run `rsync` the compose file, `scripts/`, `traefik/` and
   `media/` into it (CD's "Sync deployment files" step does this on every
   run). Either way, **write `.env` on the server by hand from
   `.env.example`.** `.env` never enters Git — CD does not sync it, and
   `deploy.sh` reads it as the authoritative source for `DOMAIN` and
   everything else.

7. **DNS A records for both `api.${DOMAIN}` and `app.${DOMAIN}`, pointing at
   this host, before the first deploy.** Traefik's certificate resolver uses
   Let's Encrypt HTTP-01, which resolves the hostname over the public internet
   to validate ownership. Without both records in place, ACME fails silently
   and Traefik falls back to serving its self-signed default certificate to
   every visitor — the site looks "up" with a browser warning, which is a
   worse failure mode than not resolving at all.

8. **Bring the stack up once by hand, before any CD run:**
   ```bash
   cd "$DEPLOY_PATH"
   docker compose -f docker-compose.production.yml up -d
   ```
   `deploy.sh` **deploys, it does not bootstrap**: its preflight refuses unless
   `web` is already running at 2 replicas with Traefik backends registered for
   it. The first bring-up is what gets it there.

## 3. Secrets and variables

| Name | Kind | Breaks when wrong |
|---|---|---|
| `SUBMODULE_TOKEN` | secret | Component `sync-to-meta` workflows can't push submodule-pointer bumps or open the release PR; `main` stops tracking new component commits |
| `SSH_PRIVATE_KEY` | secret | CD/rollback can't authenticate to the server; every run fails at "Configure SSH" or the first `ssh`/`scp`/`rsync` call |
| `SSH_KNOWN_HOSTS` | secret | `ssh` refuses the connection (host key not pinned), or — if left empty/wrong — silently accepts a different host, which is why it must come from a real `ssh-keyscan` against the real host |
| `DEPLOY_HOST` | secret | `ssh`/`scp`/`rsync` target the wrong machine, or nothing |
| `DEPLOY_USER` | secret | Login fails, or succeeds as the wrong user without `docker` group membership, so every `docker compose` call fails on the socket |
| `DEPLOY_PATH` | secret | Files sync into the wrong directory, or `cd "${DEPLOY_PATH}"` fails and every remote command after it runs from the wrong `cwd` (or the login shell's home, silently) |
| `GHCR_PAT` | secret | The server-side `docker login ghcr.io` fails, so `docker compose pull` can't fetch the images and the deploy stops at "pulling images" |
| `DOMAIN` | **repository variable**, not a secret | `cd.yml` reads it as `vars.DOMAIN` for the GitHub environment's `url:` field and the deployment summary table. **This is cosmetic only** — `deploy.sh` never reads it from the workflow. The authoritative `DOMAIN` is whatever is written in the server's `.env`, read via `envval DOMAIN`. If the two disagree, the summary link points at the wrong host but the deploy itself still targets the right one (or vice versa if `.env` is stale) — check `.env` on the server, not the repo variable, when in doubt. |

## 4. A normal deploy

The deploy decision is merging the release PR into `main` (each component's
`sync-to-meta` workflow batches its submodule-pointer bump into that PR, so a
commit on `main` always carries a coherent API/dashboard pair). Merging
triggers `.github/workflows/cd.yml` on `push`:

1. **`wait-for-ci`** blocks until the `CI Summary` check on that commit is
   green. Skipped entirely on a manual `workflow_dispatch` run.
2. **`verify-images`** decides the image tag (the input if you gave one via
   `workflow_dispatch`, otherwise the commit SHA) and confirms both
   `ghcr.io/etqan-agency/chatbot/api:<tag>` and `.../dashboard:<tag>` exist in
   the registry before anything touches the server.
3. **`deploy`** rsyncs the compose file, `scripts/`, `traefik/` and
   `media/nginx.conf` to `DEPLOY_PATH`, then runs, over SSH:
   ```bash
   bash scripts/deploy.sh <tag> [--skip-backup] [--dry-run]
   ```
   `deploy.sh` runs, **in order**: preflight (disk/memory, Traefik API
   reachable, every rolled service at its steady replica count, no
   `traefik.http.services.*` label drift) → image pull → data tier `up -d
   --no-recreate` (never recreates `db`/`redis`) → a Postgres backup (unless
   `--skip-backup`) → `collectstatic` → `migrate` → writes the media smoke
   probe object → rolls `worker` → rolls `web` → rolls `dashboard` → runs the
   smoke checks.
4. Read the **Deployment summary** in the run's Job Summary: a table of both
   URLs and the image tag that is now `CURRENT`.

**`deploy.sh` auto-rolls-back only when the smoke checks fail.** Concretely:
a failure during preflight, `migrate`, or a `roll_service`/`roll_worker` call
that times out **leaves the system exactly as it was and rolls nothing back**
— the run just stops, with whatever was serving before still serving. Only a
smoke-check failure (the very last step) triggers the automatic call to
`rollback.sh`, and even then it rolls back to `CURRENT` from
`.release-state` — see §5 for why that matters. Read the failed run's log to
see which stage it stopped at before assuming anything was rolled back.

## 5. Rolling back

**Actions → Rollback → Run workflow.** Leave the `image_tag` input blank to
roll back to `PREVIOUS` from `.release-state` on the server, or enter a
specific known-good tag. The input is validated against
`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` before it is used — this is the same
pattern `cd.yml` enforces on its own `image_tag` input, so an operator who
types something exotic (spaces, shell metacharacters, a registry path with a
colon) gets a clean refusal at the "Roll back" step rather than a mysterious
downstream failure.

**Why the manual default is `PREVIOUS` here but `deploy.sh`'s own
auto-rollback (§4) reads `CURRENT` — this is not a bug, the two run at
different times against different states of `.release-state`.** `.release-state`
is only rewritten after smoke checks pass. When `deploy.sh` is deciding
whether to auto-rollback, that write has not happened yet for the run that is
failing, so the file's `CURRENT` still names the release that was actually
serving before this run started — reading `CURRENT` is correct there.
Running the Rollback workflow by hand, by contrast, normally happens some
time *after* a deploy has already succeeded and rewritten `.release-state`,
so by then `CURRENT` names the release you are trying to get away from and
`PREVIOUS` names the one to go back to — reading `PREVIOUS` is correct there.
Both scripts are reading the field that names "the release that was serving
before the thing you're recovering from," it is just a different field
depending on whether `.release-state` has been advanced yet.

**Do not re-run CD with an older tag as a way to "roll back."** That is a
*deploy* of that tag: it runs `collectstatic`, `migrate` and the
`.release-state` bookkeeping exactly like any other deploy, against a database
that has already been migrated forward past that tag's expectations. The
Rollback workflow, by contrast, calls `rollback.sh`, which never touches `db`
or `redis` and never runs `migrate`.

Schema is **deliberately never reverted**. The whole pipeline follows an
expand/contract discipline: release N's schema is required to stay compatible
with release N-1's code (and N+1's, until the following release retires the
compatibility shim). That is what makes an image-only rollback — swap the
container images back, leave the schema alone — safe. Reverting the schema
too would break that guarantee for no benefit, and would need its own
data-loss analysis (a rolled-back-schema-with-forward-data write is not
generally reversible).

`rollback.sh` also **reconciles** replica counts before rolling (see §6): it
will bring a service that is stuck at double replicas back to steady first,
rather than refusing like a deploy does. That's deliberate — see §6 for why.

## 6. When a rollout is interrupted

If a deploy is interrupted mid-roll (a timeout, a killed CI runner, a manual
`Ctrl-C` on the server), a service can be left at the wrong replica count. The
next `deploy.sh` run's preflight catches this and refuses with:

```
ERROR: web has N running replicas, expected 2.
```

The reconcile command it prints, and the one to run by hand, is:

```bash
docker compose -f docker-compose.production.yml up -d --no-deps --no-recreate --scale web=2 web
```

(substitute `dashboard`/2 or the affected service and its steady count).
**`--no-recreate` matters.** Without it, compose sees that `IMAGE_TAG` has
moved since the surviving containers were created and recreates them too —
which stops and restarts every replica of the service at once, i.e. exactly
the non-rolling restart this whole pipeline exists to avoid. `--no-recreate`
tells compose to leave the existing containers alone and only create the
ones needed to reach the target count.

Running the reconcile command by hand fixes the replica count but leaves the
deploy that was interrupted un-retried. In most cases, **running a rollback is
the faster way out**: `rollback.sh` reconciles automatically (scaling down to
steady first if there are too many, up if there are too few) as part of its
normal flow, then rolls to the target tag and re-verifies with the smoke
checks — one action that both fixes the replica count and confirms the site
is serving correctly.

## 7. Service-label drift

Traefik requires every container backing one service to declare an
**identical** `traefik.http.services.*` label set. A roll runs two
generations of containers at once by design (old and new coexist briefly
while the new ones warm up) — so if a compose-file change altered a
`traefik.http.services.*` label (a healthcheck path, a port, a status code)
between the old containers' creation and the new ones', Traefik sees
disagreement across the service's containers and **discards the whole
service**. The router has no backend, and the host 404s for the entire
duration of the rollout, not just for the changed replicas.

`deploy.sh`'s preflight checks for this drift before touching anything
(`assert_service_labels`), so a compose change that would trigger it is
caught before the rollout starts, not partway through. If it fires:

```bash
bash scripts/sync-service-labels.sh <service>
```

This force-recreates every replica of that one service at once to match the
compose file's current labels. **It is not zero-downtime** — that service's
host is briefly unavailable while all its replicas restart together — but
it's the correct trade: the alternative (rolling anyway, into a Traefik-wide
404) is a longer and harder-to-diagnose outage. Once it has run, rolling
deploys are zero-downtime again for that service.

## 8. Known residuals

These are accepted trade-offs, not oversights. Each has a bound on its blast
radius; none is scheduled to be fixed as of this writing.

- **`dashboard` is not drainable.** `web` has a drain-aware `/health/` route
  (returns 503 while a marker file exists, so Traefik pulls it from rotation
  *before* it is stopped). `dashboard` is static nginx with no such route —
  its Traefik healthcheck just probes `/`, which nginx answers 200 right up
  until the process dies. There is no way to signal "about to stop, drain me"
  to it. When a `dashboard` replica is retired, requests already dispatched to
  it at that instant are dropped rather than finished. This is bounded by the
  30s stop timeout: at most that long a window, and only for the small
  fraction of in-flight requests that land on the exact replica being
  stopped, not the whole service.

- **The dashboard's `/api/` proxy bypasses Traefik.** The dashboard's nginx
  resolves `web:8000` via Docker's embedded DNS with a 10-second resolver TTL
  (`valid=10s`), independent of Traefik's own health-aware routing. When a
  `web` replica is retired, any `dashboard` container whose resolver cache
  still points at that replica's now-dead IP will proxy to it and return 502,
  for up to 10 seconds, until its cache expires and re-resolves. This is why
  the roll order in `scripts/lib/services.sh` matters: rolling `dashboard`
  *immediately after* `web` replaces every `dashboard` container with one
  that has an empty resolver cache, which bounds the exposure to the gap
  between the two rolls rather than to the DNS TTL of long-lived containers.
  The complete fix — routing dashboard→API traffic through Traefik instead of
  directly to `web` over Docker DNS — is not done and is not currently
  scheduled.

- **`SECURE_SSL_REDIRECT` must stay `False`** in the server's `.env`. Traefik
  terminates TLS at the edge and talks to `web` over plain HTTP, including for
  its own health probes. If `SECURE_SSL_REDIRECT` were `True`, Django would
  answer every plain-HTTP request — including Traefik's own probe of
  `/health/` — with a 301 redirect to HTTPS. Traefik's
  `healthcheck.status=200` label reads anything other than exactly 200 as
  unhealthy, so every `web` backend would drop out of rotation and the API
  would 503 across the board. This is off deliberately: the HTTPS redirect is
  Traefik's job (`entrypoints.web-secure`), not Django's, on this topology.

## 9. Cutover from the old VPS

The only irreversible, client-facing step. Run it last, after the new stack
has been verified end-to-end and while the old stack is still serving
production.

1. **Dump and restore the database, then verify row counts.**
   ```bash
   pg_dump -U <old_user> -d <old_db> | gzip > old.sql.gz
   # copy old.sql.gz to the new host, then:
   gunzip -c old.sql.gz | psql -U <new_user> -d <new_db>
   ```
   Verify with the same query on both databases, diffed:
   ```sql
   SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;
   ```
   A mismatch here means the migration is incomplete or was run against the
   wrong source — do not proceed to DNS until every row is accounted for.

2. **`rsync` the `media_volume` contents** (tenant uploads) from the old host
   to the new one, into the volume the `media` and `web` services mount.

3. **Rebuild the vector index on the new host:**
   ```bash
   docker compose -f docker-compose.production.yml run --rm web \
     python manage.py setup_pgvector
   ```
   This creates the `vector` extension and HNSW index and backfills it from
   the restored `DocumentChunk.embedding` JSON column — the dump/restore in
   step 1 carries the JSON values, not the pgvector column, so this step is
   what makes them searchable again.

4. **Deploy the new stack and smoke-check it against the new hostnames**
   while the old stack still serves production traffic. This is exactly the
   deploy in §4, run for the first time against real data.

5. **Flip DNS** — repoint the `api.${DOMAIN}` and `app.${DOMAIN}` A records
   from the old host to the new one. **Keep the old stack running through the
   full TTL window** (however long the previous records' TTL was, plus
   margin for resolver caching in the wild): it is the rollback path if the
   new stack misbehaves under real traffic, and it stops being useful the
   moment it's torn down.

6. **Retire the Vercel dashboard deployment** only once the new `dashboard`
   deployment has been confirmed serving real traffic correctly.

## 10. Cutover silent-failure checklist

These fail *quietly* — nothing crashes, nothing pages anyone, but real
functionality silently stops working. Go through this list explicitly before
and immediately after the DNS flip; do not rely on the smoke checks in §4 to
catch any of them, they don't.

- **Paddle webhook URL** is registered in Paddle's dashboard against the old
  host. Until it's repointed at
  `https://api.${DOMAIN}/api/v1/billing/paddle/webhook/`, Paddle keeps sending
  webhook events to a host that no longer answers for them and **payments
  stop being fulfilled** with no visible error on the buyer's side. Verify
  with a sandbox event **before** the flip, not after.

- **Meta WhatsApp webhook URL** has the same failure mode, registered against
  the old host in Meta's app dashboard. It additionally has its own
  verify-token handshake that runs on re-registration — budget time for that,
  it isn't instant.

- **Tenants calling the old URL directly with `x-api-key`** (bypassing the
  dashboard, e.g. server-to-server integrations) break the instant DNS flips,
  with no graceful path: there is no useful HTTP redirect for a POST body,
  so a 301/302 will not save them. They need advance notice before the
  cutover date, not a redirect after it.

- **`DEBUG` must be `False`** in the new server's `.env`. Django only mounts
  its own `MEDIA_URL` handler when `DEBUG` is true; in production `/media/`
  must come exclusively from the dedicated `media` nginx service (§1). If
  `DEBUG` is accidentally left `True`, `/media/` is served by **two**
  different components with different cache headers, and which one answers a
  given request becomes routing-dependent and inconsistent.

## 11. First-deploy checklist

Tick these off once, before the very first real deploy against this host:

1. **DNS resolves both hostnames** — `dig +short api.${DOMAIN}` and
   `dig +short app.${DOMAIN}` both return this host's IP.
2. **The certificate is real, not self-signed:**
   ```bash
   curl -sI https://api.${DOMAIN}/health/
   ```
   succeeds with no certificate warning. If `curl` complains about the
   certificate, ACME has not completed — recheck DNS (step 1) before
   retrying; Traefik will keep retrying ACME on its own once DNS is correct.
3. **Traefik has registered both `web` backends as UP:**
   ```bash
   docker exec chatbot-traefik-1 wget -qO- http://127.0.0.1:8080/api/http/services/web@docker
   ```
   shows two backend entries, both `"UP"`.
4. **`.env` is present on the server and `DEBUG=False`** in it.
5. **Trigger CD once with `dry_run: true`** (Actions → CD → Run workflow →
   `dry_run: true`) before the first real deploy. This pulls both images and
   stops — it proves image access and the SSH/sync path work without touching
   any running container.
