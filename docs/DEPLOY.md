# Deployment runbook

This is the document to read at 2am, or six months from now when every
decision below has been forgotten. It assumes no prior context: it names every
file, secret and command it depends on.

The stack is one Docker Compose project (`docker-compose.production.yml`,
pinned `name: chatbot`), fronted by Traefik, fronted in turn by nginx on the
same Ubuntu host (see §1 for the full request path). Deploys and rollbacks are
driven from GitHub Actions, but the scripts they call
(`scripts/deploy.sh`, `scripts/rollback.sh`, `scripts/sync-service-labels.sh`)
are ordinary bash and can be run by hand on the server if Actions is
unavailable.

## 1. Topology

The request path has a hop in front of the Docker stack:

```text
client → nginx (host, :443, certbot TLS) → 127.0.0.1:8081 → Traefik → containers
```

nginx runs directly on the host (not in Compose), owns `:80`/`:443`, and
terminates TLS with certbot-issued certificates. It reverse-proxies everything
to Traefik over loopback. Traefik **terminates nothing and requests no
certificates of its own** — its one active entrypoint (`web`, plaintext
`:80`) is published as `127.0.0.1:8081` only, so nothing outside the host can
reach it directly. Its ACME configuration (`web-secure`, `certificatesResolvers`
in `traefik/traefik.yml`) is kept in the file but dormant: no router names a
`certresolver`, so Traefik never contacts Let's Encrypt. See §2 for why it's
kept rather than deleted.

This only changes what sits in front of Traefik. The load-balancer
healthchecks that gate a rolling deploy (`web`'s drain-aware `/health/` probe,
`dashboard`'s `/` probe) and the drain gate described in §4/§6 run
Traefik→container, entirely behind nginx, and are unaffected by anything
in front of Traefik.

Ten containers, five services never rolled and three rolled:

| Service | Replicas | Rolled? | Role |
|---|---|---|---|
| `traefik` | 1 | no | Gateway: plaintext routing only. Reachable over loopback (`127.0.0.1:8081`); TLS terminates at nginx (host), not here |
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

Two hostnames, **independent** — `API_HOST` and `APP_HOST`, `.env` values on
the server; nothing derives one from the other:

- **`API_HOST`** (`api-demo-chatbot.abdulkhalek.dev`) serves the Django API on
  the `api` router, and `/media/` on a separate `media` router with
  **priority 100** (higher than `api`'s default rule-length priority), so a
  request for `/media/...` on that host goes to the `media` service, not to
  `web`.
- **`APP_HOST`** (`app-demo-chatbot.abdulkhalek.dev`) serves the React SPA
  (`dashboard`). The dashboard's own nginx proxies `/api/` **same-origin**,
  straight to `web:8000` over Docker DNS — this request never goes through
  Traefik. See §8 for why that matters.

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
   80 and 443 are for **nginx** — it is what listens on `0.0.0.0`. Traefik
   needs no firewall rule of its own: it is published as `127.0.0.1:8081`
   (see §1), which is not reachable from outside the host regardless of what
   ufw allows.

   **Loopback binding is the control here, not the firewall.** Docker inserts
   its own iptables `DOCKER-USER`/`DOCKER` chain rules ahead of ufw's, so a
   container port published on `0.0.0.0` is reachable from the network
   whether or not ufw has a matching `allow` rule — ufw simply never gets a
   say for Docker-published ports. If Traefik's port publication in
   `docker-compose.production.yml` were ever changed from
   `127.0.0.1:8081:80` to `8081:80` (or `0.0.0.0:8081:80`), the whole stack
   would become reachable over plain HTTP on 8081, bypassing nginx's TLS and
   its access log, and ufw would not stop it. (Rate limiting is *not* among
   the losses: it is Traefik's, in `traefik/dynamic/middlewares.yml`, and is
   applied on the 8081 path itself.) `deploy.sh`'s preflight asserts every
   published Traefik mapping is on `127.0.0.1` and refuses otherwise, so a
   deploy cannot proceed against a wrongly-published gateway — but a manual
   `docker compose up -d` still can, which is why §11 also checks it.

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
   `deploy.sh` reads it as the authoritative source for `API_HOST`, `APP_HOST`
   and everything else.

7. **Install nginx, then the two vhosts, then certbot — before the first
   deploy, and independent of it.** With the gateway split (§1), certificates
   are decoupled from deploys entirely: nothing in `deploy.sh` talks to Let's
   Encrypt, so this step has no deadline relative to CD, only relative to DNS.

   - **DNS A and AAAA records for both `api-demo-chatbot.abdulkhalek.dev` and
     `app-demo-chatbot.abdulkhalek.dev`, pointing at this host, must exist
     before certbot runs** (not before the first deploy — see above). certbot
     uses the same HTTP-01 challenge Traefik's dormant resolver would have
     used: it resolves the hostname over the public internet to validate
     ownership, so a missing record fails the request for that host outright.
   - Install nginx (`sudo apt install nginx`), then copy the two reference
     vhosts from `docs/nginx/` into `/etc/nginx/sites-available/` and enable
     them:
     ```bash
     sudo cp docs/nginx/api-demo-chatbot.conf \
       /etc/nginx/sites-available/api-demo-chatbot.abdulkhalek.dev
     sudo cp docs/nginx/app-demo-chatbot.conf \
       /etc/nginx/sites-available/app-demo-chatbot.abdulkhalek.dev
     sudo ln -s /etc/nginx/sites-available/api-demo-chatbot.abdulkhalek.dev \
       /etc/nginx/sites-enabled/
     sudo ln -s /etc/nginx/sites-available/app-demo-chatbot.abdulkhalek.dev \
       /etc/nginx/sites-enabled/
     sudo nginx -t && sudo systemctl reload nginx
     ```
     **The files under `/etc/nginx/sites-available/` are the live vhosts.
     `docs/nginx/*.conf` are reference copies only — CD cannot deploy them**
     (they live outside `DEPLOY_PATH` and are root-owned, unlike everything
     else CD syncs). **The two are kept in sync by hand.** If either vhost is
     changed — a header, a timeout, a body-size limit — copy the change into
     both places yourself; nothing else does it for you.

     `deploy.sh` reports any disagreement on every deploy, and
     `bash scripts/check-vhost-drift.sh` gives the same answer on demand with a
     non-zero exit. It compares behaviour, not bytes: where traffic is proxied,
     which hostnames and ports are answered, the upload ceiling, the proxy
     timeouts and the forwarded headers. TLS plumbing and comments are ignored,
     because those differ legitimately between a host that has run
     `certbot --nginx` and one that has only ever run `certonly --webroot`.

     **The shipped vhosts contain a `:80` server block only** — no `listen
     443`, no `ssl_certificate`. That is deliberate and must stay that way
     until certbot has run. A `listen 443 ssl` block whose certificate lines
     are commented out is not a valid configuration: nginx fails the whole
     config with `no "ssl_certificate" is defined for the "listen ... ssl"
     directive`. With the symlinks already live, that failure means nginx
     **refuses to start at all** on the next `systemctl restart` (a reboot, an
     apt upgrade), taking `:80` and `:443` down for *every* site on this host.
     certbot cannot rescue it either — it runs `nginx -t` itself first.
   - **Obtain the certificates with `certonly --webroot`, not `--nginx`:**
     ```bash
     sudo certbot certonly --webroot -w /var/www/html \
       -d api-demo-chatbot.abdulkhalek.dev
     sudo certbot certonly --webroot -w /var/www/html \
       -d app-demo-chatbot.abdulkhalek.dev
     ```
     **Do not use `certbot --nginx` here.** The nginx plugin does not create a
     second server block: with only a `:80` server present it *appends*
     `listen 443 ssl` and the certificate lines to that same block. The `:80`
     `location /` redirect then applies to https as well, and every https
     request 301s to itself — an infinite redirect loop on both hostnames.
     That is measured behaviour on this stack, not a theoretical risk.

     `certonly --webroot` writes no nginx configuration at all. It answers the
     HTTP-01 challenge through the `location /.well-known/acme-challenge/`
     already in the `:80` block, which is also what keeps renewals working:
     certbot's systemd timer (`certbot.timer`) reuses the webroot authenticator
     recorded in `/etc/letsencrypt/renewal/<host>.conf`. There is no Traefik
     involvement in issuance or renewal.

     Note the redirect is written as `location / { return 301 ... }` rather
     than a server-level `return 301`: a server-level return runs in nginx's
     rewrite phase, *before* location matching, and would swallow the challenge
     — every renewal would then fail.
   - **Uncomment the `:443` block in each vhost.** Both files ship it commented
     out below the `:80` server. It carries `client_max_body_size 25M`, the two
     `120s` proxy timeouts, the `ssl_certificate` lines, the TLS settings and
     the `location /` `proxy_pass` to `127.0.0.1:8081` — none of which exist
     until you uncomment them, and without which the vhost terminates TLS and
     then serves nothing.

     The TLS settings are written out **inline** rather than pulled in with
     `include /etc/letsencrypt/options-ssl-nginx.conf` and `ssl_dhparam
     /etc/letsencrypt/ssl-dhparams.pem`, which is what these files used to do.
     Both of those are written into `/etc/letsencrypt` by certbot's *nginx
     installer* plugin, and `certonly --webroot` runs no installer — that is
     the entire reason the previous step uses it. On a host that has never run
     `certbot --nginx` neither file exists, and `include`ing a missing file is
     a hard `nginx -t` failure at this exact step. If you are adopting an
     existing host, confirm before assuming either way:
     ```bash
     ls -l /etc/letsencrypt/options-ssl-nginx.conf /etc/letsencrypt/ssl-dhparams.pem
     ```

     It uses `listen 443 ssl http2`, not the standalone `http2 on;` directive:
     that form requires nginx >= 1.25, and on 1.24 nginx rejects the entire
     configuration with `unknown directive "http2"`.

     ```bash
     sudo nginx -t && sudo systemctl reload nginx
     ```
     Verify before moving on — the loop above is invisible to `nginx -t`:
     ```bash
     curl -sS -o /dev/null -L --max-redirs 3 \
       -w 'code=%{http_code} redirects=%{num_redirects}\n' \
       https://api-demo-chatbot.abdulkhalek.dev/
     ```
     Expect `redirects=0`. A `curl: (47) Maximum (3) redirects followed` means
     the `:80` and `:443` blocks have been merged into one server.

   - **Do not add IPv6 listeners without checking every other vhost on the
     host.** nginx makes the *first* server block on an `address:port` the
     default server for that address, and `sites-enabled/` is read
     alphabetically. Adding `listen [::]:80` to a vhost whose name sorts early,
     on a host where the other sites' vhosts are IPv4-only, silently makes it
     the default server for **all** IPv6 traffic — including ACME challenges
     for those other sites, which then 404. Let's Encrypt does not retry over
     IPv4 after a 404 (it is a valid HTTP response), so the co-hosted site's
     certificate stops renewing and nothing reports it until expiry. That
     happened during this host's provisioning and broke `etqanbackend.tech`'s
     renewal; `nginx -t` is blind to it. The shipped vhosts are IPv4-only
     because these hostnames have no AAAA records. If they gain them, add the
     IPv6 listener to *every* vhost on the host at once.
   - **Prove renewal works before walking away** — for every certificate on the
     host, not just the new ones:
     ```bash
     sudo certbot renew --dry-run
     ```
     Expect `Congratulations, all simulated renewals succeeded` and one
     `(success)` line per certificate. This is the only check that exercises
     the challenge path end to end, and a renewal that fails here fails
     silently in 60 days.

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
| `API_HOST` | **repository variable**, not a secret | `cd.yml` reads it as `vars.API_HOST` for the deployment summary table only. **This is cosmetic only** — `deploy.sh` never reads it from the workflow. |
| `APP_HOST` | **repository variable**, not a secret | `cd.yml` reads it as `vars.APP_HOST`, for both the GitHub environment's `url:` field and the deployment summary table. **This is cosmetic only** — `deploy.sh` never reads it from the workflow. |

`API_HOST` and `APP_HOST` are **independent** repository variables — neither
is derived from the other, and there is no `DOMAIN` variable to derive them
from. In both cases the authoritative value is whatever is written in the
server's `.env`, read via `envval API_HOST` / `envval APP_HOST`. If a
repository variable and the server's `.env` disagree, the environment link or
summary table points at the wrong host but the deploy itself still targets
whatever `.env` says (or vice versa if `.env` is stale) — check `.env` on the
server, not the repository variables, when in doubt.

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
   `deploy.sh` runs, **in order**: preflight (disk/memory, gateway published on
   loopback, gateway running its current *static* config, Traefik API
   reachable, every rolled service at its steady replica count, no
   `traefik.http.services.*` label drift) → image pull → data tier `up -d
   --no-recreate` (never recreates `db`/`redis`) → a Postgres backup (unless
   `--skip-backup`) → `collectstatic` → `migrate` → writes the media smoke
   probe object → rolls `worker` → rolls `web` → rolls `dashboard` → runs the
   smoke checks.
4. Read the **Deployment summary** in the run's Job Summary: a table of both
   URLs and the image tag that is now `CURRENT`.

### Changing `traefik/traefik.yml` needs an explicit gateway restart

`traefik.yml` is **static** configuration: Traefik reads it once, at process
start. Only `traefik/dynamic/` hot-reloads. `cd.yml` rsyncs `traefik/` to the
server, but nothing in a deploy recreates the Traefik container — it touches
`db`, `redis`, `socket-proxy` and `media`, and rolls `worker`, `web` and
`dashboard`. A changed `traefik.yml` therefore lands on disk, is never read,
and the deploy reports success while the configuration in Git and the one
actually serving traffic disagree — silently, and indefinitely.

That is not hypothetical: the `providers.docker` constraint that stops Traefik
discovering a co-tenant project's containers arrived exactly this way, correct
in Git and inert in production.

So `deploy.sh`'s preflight compares `traefik/traefik.yml`'s mtime against the
Traefik container's start time and **refuses** when the file is newer:

```
ERROR: traefik/traefik.yml is newer than the running chatbot-traefik-1.
       Traefik reads that file ONCE, at process start; it does not
       hot-reload, unlike traefik/dynamic/. ...
         docker compose -f docker-compose.production.yml up -d --no-deps --force-recreate traefik
```

Run that one command on the server, then re-run the deploy. It is **not** done
automatically: recreating Traefik drops every in-flight connection, and when to
take that hit is an operator's decision, not a rolling deploy's to make
silently.

The mtime comparison only means anything because `cd.yml` syncs `traefik/` with
**both** `--checksum` and `--no-times`, and both are load-bearing. `--checksum`
stops rsync retransmitting a file that a fresh checkout merely re-timestamped.
`--no-times` stops it copying the source mtime across anyway — `-a` implies
`-t`, which syncs timestamps even for files `--checksum` decided not to
transfer. That second one is easy to miss: with `--checksum` alone, an unchanged
`traefik.yml` still had its server-side mtime advanced on every run, and this
check refused a deploy it should have passed. Get either flag wrong and it cries
wolf on every deploy.

**`deploy.sh` auto-rolls-back only when the smoke checks fail.** Concretely:
a failure during preflight, `migrate`, or a `roll_service`/`roll_worker` call
that times out **leaves the system exactly as it was and rolls nothing back**
— the run just stops, with whatever was serving before still serving. Only a
smoke-check failure (the very last step) triggers the automatic call to
`rollback.sh`, and even then it rolls back to `CURRENT` from
`.release-state` — see §5 for why that matters. Read the failed run's log to
see which stage it stopped at before assuming anything was rolled back.

### The five smoke probes

`smoke_probes` (`scripts/lib/services.sh`) emits five checks, not three — the
last two exist specifically to tell a broken release apart from a broken
gateway:

1. `https://<API_HOST>/health/` — public, through nginx and Traefik.
2. `https://<APP_HOST>/` — public, through nginx and Traefik.
3. `https://<API_HOST>/media/<probe path>` — public, through nginx, Traefik
   and the `media` service; the only probe that exercises the priority router
   and the shared volume mount.
4. `http://127.0.0.1:8081/health/` with an explicit `Host: <API_HOST>` header
   — straight at Traefik's loopback port, bypassing nginx entirely.
5. `http://127.0.0.1:8081/` with an explicit `Host: <APP_HOST>` header — same,
   for the dashboard.

Probes 4 and 5 have to carry the `Host` header themselves because they are
not going through nginx, which is what would normally supply it from the
public hostname — Traefik's routers match on `Host(...)`, so a request
without one falls through to no router at all.

Read the two probe layers together:

| Public | Loopback | Means |
|---|---|---|
| fail | pass | The application is healthy. The fault is nginx, certbot or DNS. `deploy.sh` will still have rolled back — re-deploy after fixing the gateway. |
| fail | fail | The release is bad. The auto-rollback was correct. |
| pass | fail | Should be impossible; nginx is proxying somewhere other than `127.0.0.1:8081`. |

(pass/pass is the fifth, unlisted combination: everything is healthy, nothing
to do.)

## 5. Rolling back

**Actions → Rollback → Run workflow.** Leave the `image_tag` input blank to
roll back to `PREVIOUS` from `.release-state` on the server, or enter a
specific known-good tag. The input is validated against
`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` before it is used — this is the same
pattern `cd.yml` enforces on its own `image_tag` input, so an operator who
types something exotic (spaces, shell metacharacters, a registry path with a
colon) gets a clean refusal at the "Roll back" step rather than a mysterious
downstream failure.

**Blank is only correct after a deploy that SUCCEEDED and was then found bad.**
If you are recovering from a deploy that failed *before* its smoke checks,
`.release-state` has not been advanced and blank resolves one release too far
back — enter the tag named by `CURRENT` instead. See §6.

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

### A rollback does not require the registry

`rollback.sh` pulls the target images first, but a **failed pull no longer
aborts it**. Under `set -e` a bare `docker compose pull` used to end the script
there — so a ghcr.io outage, an expired `GHCR_PAT`, or a DNS failure on the
host removed the recovery path at exactly the moment it was needed, and did so
for a step that is usually unnecessary: rolling *back* means returning to a
release that was recently running on this host, whose images are therefore
already in the local image store. The registry is an optimisation here, not a
dependency.

So the pull is attempted; if it fails, every image the compose file names for
`web`, `worker` and `dashboard` must be present locally and the rollback
continues with a warning. It refuses only when one is genuinely missing — and
names it, because "obtain that image some other way" is then the operator's
next move. The warning matters: it means the tag was **not** re-verified
against the registry, so a locally-tagged image that does not match what the
registry holds under that tag would be used without complaint.

## 6. When a rollout is interrupted

If a deploy is interrupted mid-roll (a timeout, a killed CI runner, a manual
`Ctrl-C` on the server), a service can be left at the wrong replica count. The
next `deploy.sh` run's preflight catches this and refuses with:

```
ERROR: web has N running replicas, expected 2.
```

The reconcile command it prints, and the one to run by hand, is:

```bash
IMAGE_TAG=<the currently deployed tag> docker compose -f docker-compose.production.yml up -d --no-deps --no-recreate --scale web=2 web
```

(substitute `dashboard`/2 or the affected service and its steady count). The
scripts fill in the tag for you — `assert_steady_replicas` when it refuses,
and `reconcile_service` when its own scale fails to take, read `CURRENT` from
`.release-state` and print it inline, so the line in the error message is
copy-pasteable as printed. If it prints
the placeholder instead, `.release-state` could not be read; get the tag with
`cat .release-state` or `docker inspect` on a surviving replica.

**Both halves of that line matter, for mirror-image reasons.**

`--no-recreate` protects the containers that already exist. Without it,
compose sees that `IMAGE_TAG` has moved since the surviving containers were
created and recreates them too — which stops and restarts every replica of
the service at once, i.e. exactly the non-rolling restart this whole pipeline
exists to avoid.

The explicit `IMAGE_TAG=` decides what the **scale-up** creates. Without it,
compose interpolates `IMAGE_TAG` from the server's `.env`, which is `latest`
(see `.env.example`), and CI pushes `latest` on every build of `main`. The new
replica would come up on the newest *unreleased* `main` build while its
siblings stayed on the deployed release — a mixed-version service, possibly
running code whose migrations have not been applied.

Running the reconcile command by hand fixes the replica count but leaves the
deploy that was interrupted un-retried. In most cases, **running a rollback is
the faster way out**: `rollback.sh` reconciles automatically (scaling down to
steady first if there are too many, up if there are too few) as part of its
normal flow, then rolls to the target tag and re-verifies with the smoke
checks — one action that both fixes the replica count and confirms the site
is serving correctly.

### Which tag to roll back to after an interrupted deploy

**A failure *before* the smoke checks: enter the tag named by `CURRENT` in
`.release-state`. Do not leave the tag blank.**

`.release-state` is only rewritten after smoke checks pass (§5), so a deploy
that died in the preflight, in `migrate`, or in a roll that timed out has not
advanced it: `CURRENT` still names the release that was serving before the run
started, and `PREVIOUS` names the one before *that*.

Leaving the tag blank resolves to `PREVIOUS`, which here is release N−2. If
`migrate` had already run, release N's schema is live — and expand/contract
only guarantees that a schema is compatible **one** release back. N−2 code on
N schema is precisely the breakage the pipeline exists to prevent.

```bash
# on the server
cat "${DEPLOY_PATH}/.release-state"
# -> CURRENT=<enter this one>   PREVIOUS=<not this one>
```

Blank (i.e. `PREVIOUS`) is correct only in the other case: a deploy that
*succeeded*, advanced `.release-state`, and turned out bad afterwards.

### A leftover one-off container

`deploy.sh` runs `collectstatic`, `migrate` and the media-probe write as
`docker compose run --rm` one-off containers. Compose names those
`chatbot-web-run-<hash>`, and `service_containers` matches on the
`chatbot-<service>-` prefix — so a run killed *during* `migrate` (`--rm` never
fires) leaves a container that the preflight counts as a `web` replica:

```
ERROR: web has 3 running replicas, expected 2.
```

The reconcile command will **not** fix this. `--scale web=2` counts and
removes only the containers compose considers replicas of the service; the
one-off is not one, so the scale is a no-op and the preflight fails again with
the same message.

Spot it by the name, then remove it by hand:

```bash
docker ps --format '{{.Names}}' | grep -- '-run-'
# chatbot-web-run-7f3a91c0d2e4
docker rm -f chatbot-web-run-7f3a91c0d2e4
```

Check first that it really is dead and not a `migrate` still running against
the database (`docker logs <name>`); killing a live migration mid-transaction
is a different and worse problem. Postgres will roll back an interrupted
transaction, but a migration split across several is not atomic as a whole.
Once the one-off is gone, re-check the count and proceed.

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

The script pins `IMAGE_TAG` to `CURRENT` from `.release-state` and prints it:

```
>>> recreating at the deployed release tag IMAGE_TAG=<tag>
```

That pin is not cosmetic. `--force-recreate` replaces every replica, and
without an explicit tag compose would read `IMAGE_TAG` from the server's
`.env` — `latest`, which CI pushes on every build of `main` — and this
"remedy for label drift" would quietly replace the running release with the
newest unreleased build, migrations or no migrations.

If `.release-state` cannot be read the script **refuses** rather than
defaulting, because there is no safe default. Name the tag yourself:

```bash
IMAGE_TAG=<deployed-tag> bash scripts/sync-service-labels.sh <service>
```

`rollback.sh` also checks label parity, but only **warns** — it names this
script and continues. Refusing there would block the recovery path with a
condition rollback exists to recover from, the same reasoning that makes a
rollback reconcile replica counts instead of asserting them. A rollback is in
fact where drift is *most* likely: `cd.yml` rsyncs the new
`docker-compose.production.yml` to the server **before** `deploy.sh` runs, so
a deploy that fails after that sync leaves new compose beside old containers.
If a rollback's verification fails with 404s and this warning is in the log,
that is the cause.

## 8. Known residuals

These are accepted trade-offs, not oversights. Each has a bound on its blast
radius; none is scheduled to be fixed as of this writing.

**What "zero-downtime" has actually been measured to mean here.** A local
rehearsal of a full rolling deploy served **400/400 requests with none
dropped**. That measurement was taken directly against Traefik (this rehearsal
predates the nginx front-end in §1, and nginx adds a proxy hop, not a change
to Traefik's own health-aware routing or its drain-aware `/health/` route, so
the result still describes that path). The dashboard's `/api/` path, where the
dashboard's own nginx proxies to `web:8000` over Docker DNS and bypasses
Traefik entirely, was **not** measured. That is the path carrying the
10-second resolver residual described below, so the 400/400 result should not
be read as covering it.

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
  for up to 10 seconds, until its cache expires and re-resolves.

  **The bound is the 10 seconds, and it comes from `valid=10s` — not from the
  roll order.** An earlier version of this document (and of the comment in
  `scripts/lib/services.sh`) claimed that rolling `dashboard` immediately
  after `web` bounded the exposure to the gap between the two rolls. That is
  not how it works. `valid=10s` expires a cached entry 10 seconds after it was
  taken, in a long-lived container exactly as in a fresh one, so there is no
  "DNS TTL of long-lived containers" to improve on. And the old `dashboard`
  replicas — the ones holding the stale caches — keep serving right through
  the new dashboard generation's warm-up, which takes longer than 10 seconds,
  so they have re-resolved on their own before they are retired. The roll
  order is web-before-dashboard because dashboard is downstream of web; it is
  not what produces the bound.

  This residual is on the dashboard's own `/api/` path only, and it is the path
  the 400/400 rehearsal did **not** measure (see above). The complete fix —
  routing dashboard→API traffic through Traefik instead of directly to `web`
  over Docker DNS — is not done and is not currently scheduled.

- **`SECURE_SSL_REDIRECT` must stay `False`** in the server's `.env`. nginx
  terminates TLS at the edge (§1); Traefik and `web` only ever see plain HTTP,
  including for Traefik's own health probes. If `SECURE_SSL_REDIRECT` were
  `True`, Django would answer every plain-HTTP request — including Traefik's
  own probe of `/health/` — with a 301 redirect to HTTPS. Traefik's
  `healthcheck.status=200` label reads anything other than exactly 200 as
  unhealthy, so every `web` backend would drop out of rotation and the API
  would 503 across the board. This is off deliberately: the HTTPS redirect is
  nginx's job (its `:80` server block, per `docs/nginx/*.conf`), not
  Django's or Traefik's, on this topology.

- **A second proxy hop.** nginx's `client_max_body_size` and
  `proxy_read_timeout` (`docs/nginx/*.conf`, both `25M`/`120s`) must stay at
  or above the dashboard's own internal nginx (also `25M`/`120s`) or a request
  that the dashboard's nginx would have allowed fails one hop earlier, at the
  host vhost, before it ever reaches Traefik or `web`. **`scripts/check-vhost-drift.sh` now
  compares the repository's reference copies against the live vhosts** and
  `deploy.sh` runs it on every deploy, so a value edited on the server and
  never brought back is reported rather than silently kept. It warns instead
  of refusing: unlike stale Traefik static config, a drifted vhost does not
  make the deploy itself dishonest, and blocking on it would put a
  documentation reconciliation in the path of an urgent release. What it still
  does **not** check is that these values stay at or above the dashboard's own
  internal nginx — that pairing is a judgement, not an equality.

- **HSTS is set in exactly one place, and only because of one setting**:
  Traefik's `secure-headers` middleware (`traefik/dynamic/middlewares.yml`).
  The host nginx vhosts deliberately omit `Strict-Transport-Security`, so if a
  future nginx change adds it there too, clients receive the header twice —
  harmless in most clients but worth knowing before debugging a doubled header
  in a response inspector.

  The load-bearing setting is **`forceSTSHeader: true`**. Traefik emits
  `Strict-Transport-Security` only for a request it considers TLS; with TLS
  terminating at the host nginx, every request Traefik sees arrives plain
  http on the loopback `web` entrypoint, and the `stsSeconds` /
  `stsIncludeSubdomains` / `stsPreload` settings beside it are inert without
  it — no route gets HSTS at all, silently. `X-Forwarded-Proto: https` does
  not change this. Django is not a fallback either: `SECURE_HSTS_SECONDS`
  defaults to `0`. Verify with:

  ```bash
  curl -sI -H 'Host: <APP_HOST>' http://127.0.0.1:8081/ | grep -i strict
  ```

  If that returns nothing, HSTS is off everywhere.

- **The dashboard's `/api/` calls are rate-limited as static, not as API.**
  Browser traffic to `https://<APP_HOST>/api/...` arrives on the `app`
  router, so it gets `rate-limit-static` (100/s, burst 200) and never
  `rate-limit-api` (50/s, burst 100) — the latter applies only to requests
  addressed to `<API_HOST>`, i.e. tenants' own integrations. This predates the
  gateway split and is not a regression, but it means the API's coarse abuse
  guard does not cover the path most real user traffic takes. Per-tenant
  limits in `knowledge/services/quota.py` are what actually bound that
  traffic.

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
   This creates the `vector` extension and column and backfills it from the
   restored `DocumentChunk.embedding` JSON column — the dump/restore in step 1
   carries the JSON values, not the pgvector column, so this step is what makes
   them searchable again.

   **Read the command's closing line.** It reports which of two outcomes it
   produced, and they are not equivalent. The configured `EMBEDDING_MODEL` is
   `text-embedding-3-large` at 3072 dimensions, and pgvector will not build an
   HNSW index on a `vector` column above 2000 — so at this width the index is
   built on the column's `halfvec` cast instead. Storage keeps full float32
   precision; only index search runs at 16 bits, for a small but non-zero
   recall cost. Expect:

   ```
   pgvector is ready, with an HNSW cosine index over halfvec(3072).
   ```

   The `halfvec` type needs pgvector 0.7.0 or newer. On an older server the
   command builds no index at all and says so, ending with
   `pgvector is ENABLED BUT NOT INDEXED` — correct results by sequential scan
   over every chunk. That is not a state to deploy into and leave; upgrade
   pgvector, or move to a ≤2000-dim model and re-embed.

   Either way the `knowledge.W002` system check reports an unindexed table on
   every subsequent deploy, so this cannot pass unnoticed.

   The command also needs at least one embedding present to infer the
   dimension, which is why it runs *after* the restore. Pass `--dim` only if
   you are setting up ahead of the data.

4. **Deploy the new stack and smoke-check it against the new hostnames**
   while the old stack still serves production traffic. This is exactly the
   deploy in §4, run for the first time against real data.

5. **Flip DNS** — repoint the `API_HOST` and `APP_HOST` A records
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
  `https://api-demo-chatbot.abdulkhalek.dev/api/v1/billing/paddle/webhook/`, Paddle keeps sending
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

1. **DNS resolves both hostnames:**
   ```bash
   dig +short api-demo-chatbot.abdulkhalek.dev
   dig +short app-demo-chatbot.abdulkhalek.dev
   ```
   both return this host's IP.
2. **certbot lists both certificates with a future expiry:**
   ```bash
   sudo certbot certificates
   ```
   shows both `api-demo-chatbot.abdulkhalek.dev` and
   `app-demo-chatbot.abdulkhalek.dev`, each with an `Expiry Date` in the
   future. If either is missing, certbot has not been run for that host yet
   (§2, step 7) — recheck DNS before retrying.
3. **The certificate nginx actually serves is real, not self-signed or
   expired:**
   ```bash
   curl -sI https://api-demo-chatbot.abdulkhalek.dev/health/
   ```
   returns `HTTP/2 200` (or `HTTP/1.1 200`) with no certificate warning. A
   `curl` certificate complaint here means nginx is not yet serving the
   certbot certificate for this vhost, even if step 2 lists it — check that
   `/etc/nginx/sites-enabled/` has the symlink and that `nginx -t` is clean.
4. **Traefik's loopback port is not reachable from outside the host:**
   ```bash
   ss -ltnp | grep 8081
   ```
   shows the listener bound to `127.0.0.1:8081`, not `0.0.0.0:8081` or
   `:::8081`. This is the check for the failure mode described in §2, step 3
   — a `0.0.0.0` binding here bypasses nginx entirely and ufw will not stop
   it.

   Every subsequent deploy re-checks this on its own:
   `deploy.sh`'s preflight runs `docker port chatbot-traefik-1` and refuses,
   before any mutation, unless every published mapping is on `127.0.0.1`. So
   this step is a first-deploy confirmation rather than the only guard — but
   it is still worth running by hand after any change made outside a deploy
   (a hand-run `docker compose up -d`, an edit to the compose file applied
   directly), because nothing checks that path.
5. **Traefik has registered both `web` backends as UP:**
   ```bash
   docker exec chatbot-traefik-1 wget -qO- http://127.0.0.1:8080/api/http/services/web@docker
   ```
   shows two backend entries, both `"UP"` (the `serverStatus` map in the
   response). **If the response has `loadBalancer.servers` entries but no
   `serverStatus` field at all**, this is not a fault by itself: `serverStatus`
   is populated only after Traefik's load-balancer healthcheck has completed
   at least one cycle (5s interval, per the `healthcheck.interval=5s` label in
   `docker-compose.production.yml`), so a response taken in the first few
   seconds after Traefik itself is (re)started or recreated will genuinely
   have no `serverStatus` yet even though the backends are registered. Wait
   ~10s and re-run; only treat a missing or non-`"UP"` `serverStatus` as a
   real fault if it is still that way after the wait.
6. **`.env` is present on the server, has both `API_HOST` and `APP_HOST` in
   `ALLOWED_HOSTS`, and `DEBUG=False`.** Miss either host in `ALLOWED_HOSTS`
   and Django 400s every request for it — including Traefik's own healthcheck
   probe (see §1, and the compose file's `healthcheck.hostname` label), which
   takes the whole `web` service out of rotation, not just that one host.
7. **Trigger CD once with `dry_run: true`** (Actions → CD → Run workflow →
   `dry_run: true`) before the first real deploy. This pulls both images and
   stops — it proves image access and the SSH/sync path work without touching
   any running container.
