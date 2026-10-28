# Deployment runbook

This is the document to read at 2am, or six months from now when every
decision below has been forgotten. It assumes no prior context: it names every
file, secret and command it depends on.

The stack is one Docker Compose project (`docker-compose.production.yml`,
pinned `name: chatbot`), fronted by Traefik, which is the public edge and
terminates TLS itself (see §1 for the full request path). Deploys and rollbacks are
driven from GitHub Actions, but the scripts they call
(`scripts/deploy.sh`, `scripts/rollback.sh`, `scripts/sync-service-labels.sh`)
are ordinary bash and can be run by hand on the server if Actions is
unavailable.

This repository deploys **one** environment to **one** host: the image path,
the two public hostnames and the deploy target are each written in exactly one
place and read as constants everywhere else. To stand up a second, independent
client on its own host, see [`NEW-CLIENT.md`](NEW-CLIENT.md) — it lists the
couplings a fork has to break, and then returns you here for §2 and §11.

## 1. Topology

There is nothing in front of the Docker stack:

```text
client → Traefik (:80 redirect, :443 TLS) → containers
```

**Traefik is the edge.** It owns `:80` and `:443` directly, terminates TLS
itself, and obtains its own certificates from Let's Encrypt over HTTP-01. There
is no nginx on the host and no certbot — the only nginx in this system is the
`media` *container*, which serves `/media/` and is reached through Traefik like
any other backend.

`:80` carries a blanket 301 to `:443` and nothing else. The ACME challenge is
answered on that same entrypoint by a handler Traefik registers at a higher
priority than the redirect, which is why the two coexist. `scripts/e2e.sh`
asserts both halves on every run: a normal path must redirect, and
`/.well-known/acme-challenge/` must not.

**Certificates and deploys are completely decoupled from each other in the
other direction now.** Under the previous topology a deploy could not affect
TLS because certbot owned it. Here a deploy does not either — ACME state lives
in the `traefik_acme` volume and survives container recreation — but a *gateway
restart* is now a TLS event, not just a routing one. See §4.

The load-balancer healthchecks that gate a rolling deploy (`web`'s drain-aware
`/health/` probe, `dashboard`'s `/` probe) and the drain gate described in
§4/§6 run Traefik→container over the internal network, and are unaffected by
anything happening at the edge.

> **Historical note for anyone reading git history or merging an upstream
> branch.** This stack used to run `client → nginx (host, certbot TLS) →
> 127.0.0.1:8081 → Traefik`. Several settings were *correct only under that
> topology* and are actively dangerous if restored: `forwardedHeaders.trustedIPs`
> in `traefik.yml`, `sourceCriterion.ipStrategy.excludedIPs` on the rate-limit
> middlewares, the `csrf-headers` middleware, `forceSTSHeader`, and the
> `- "127.0.0.1:8081:80"` ports entry. Each is commented at its own site with
> the reason. The rate-limiter one is the dangerous one: with Traefik at the
> edge, `X-Forwarded-For` is attacker-controlled, so keying the limiter off it
> lets any caller forge its own bucket.

Ten containers, five services never rolled and three rolled:

| Service | Replicas | Rolled? | Role |
|---|---|---|---|
| `traefik` | 1 | no | Gateway and edge: owns `:80`/`:443`, terminates TLS, runs ACME |
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

- **`API_HOST`** (`api.chatbot-demo.etqanbackend.tech`) serves the Django API on
  the `api` router, and `/media/` on a separate `media` router with
  **priority 100** (higher than `api`'s default rule-length priority), so a
  request for `/media/...` on that host goes to the `media` service, not to
  `web`.
- **`APP_HOST`** (`app.chatbot-demo.etqanbackend.tech`) serves the React SPA
  (`dashboard`). The dashboard's own nginx proxies `/api/` **same-origin**,
  straight to `web:8000` over Docker DNS — this request never goes through
  Traefik. See §8 for why that matters.

## 2. Provisioning a host

Spec: `chabot_dev_api/docs/superpowers/specs/2026-09-03-infrastructure-pipeline-design.md`
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
   80 and 443 are Traefik's — it is what listens on `0.0.0.0`, and both are
   required. 443 is obvious; **80 is the one people close**, and closing it
   breaks nothing visible because every real client is already on https. What
   it breaks is the ACME HTTP-01 challenge, so certificates stop renewing and
   the site fails everywhere at once up to 60 days later.

   **Note that ufw is not actually what is controlling this.** Docker inserts
   its own iptables `DOCKER-USER`/`DOCKER` chain rules ahead of ufw's, so a
   container port published on `0.0.0.0` is reachable from the network whether
   or not ufw has a matching `allow` rule — ufw never gets a say for
   Docker-published ports. The `allow` lines above are therefore documentation
   of intent rather than enforcement, and adding or removing a rule for 80/443
   changes nothing. Conversely, **do not rely on ufw to close a port Docker
   publishes**: the only way to stop publishing something is to remove it from
   the `ports:` entry.

   `deploy.sh`'s preflight (`assert_edge_publication`) asserts that Traefik
   publishes exactly 80 and 443, that neither is confined to loopback, and that
   nothing else is published at all — and refuses the deploy otherwise. A
   manual `docker compose up -d` bypasses that, which is why §11 checks it
   too.

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

7. **Create A records for both hostnames, pointing at this host — before the
   first bring-up, not after it.**

   There is no nginx to install, no vhost to copy, and no certbot to run.
   Traefik requests certificates itself, on demand, the first time a TLS
   handshake arrives for a hostname one of its routers claims. That makes DNS a
   hard precondition of the *first bring-up* (§2.8) rather than of a separate
   certificate step.

   ```bash
   dig +short <API_HOST>
   dig +short <APP_HOST>
   ```
   Both must return this host's IP, and `:80` must be reachable from the public
   internet, before the stack comes up — Traefik answers the HTTP-01 challenge
   there itself.

   **Getting this wrong is not a quick retry.** Let'''s Encrypt'''s production CA
   allows **5 failed authorisations per account, per hostname, per hour**. A
   stack brought up against a hostname that does not resolve yet burns that in
   one sitting, and then cannot obtain a certificate for the rest of the hour
   even once DNS is correct. If there is any doubt, rehearse against staging
   first by adding one line under `acme:` in `traefik/traefik.yml`:

   ```yaml
   caServer: https://acme-staging-v02.api.letsencrypt.org/directory
   ```

   Bring the stack up, confirm a certificate is issued — it will be untrusted
   in a browser, which is the expected result — then remove the line and
   recreate the gateway.

   **Check it actually landed before trusting it**, anchored to the config key
   rather than the word, because `traefik.yml` mentions `caServer:` in a comment
   too and a bare `grep` matches that:

   ```bash
   grep -E '^\s+caServer:' traefik/traefik.yml
   ```

   No output means you are on the production CA, whatever the file appears to
   say.


   ```bash
   docker compose -f docker-compose.production.yml up -d --no-deps --force-recreate traefik
   ```

   Staging'''s limits are far more generous and share nothing with production'''s.
   (`scripts/e2e.sh` does the same substitution against a dead local address, so
   a rehearsal never contacts either CA.)

   **Certificates live in the `traefik_acme` volume**, which is what makes them
   survive container recreation and every deploy. `docker compose down -v`
   destroys that volume, and re-issuing counts against the rate limit above —
   so never pass `-v` on a host that is serving.

   **Renewal needs no timer and no cron.** Traefik renews in the background
   from the same volume, using the same HTTP-01 challenge on `:80`. That is the
   entire reason `:80` must stay published and reachable forever (§2.3), long
   after every real client has moved to https.

   **IPv6:** the shipped configuration assumes these hostnames have A records
   only. Let'''s Encrypt prefers AAAA when one exists, so publishing an AAAA
   record for a host that does not actually answer on `:80` over IPv6 makes
   validation fail — add the record and confirm reachability together, or
   neither.

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

`smoke_probes` (`scripts/lib/services.sh`) emits five checks, in two groups.
One definition serves both `deploy.sh` and `rollback.sh`, so a rollback can
never verify less than the deploy gated on.

**Three public https probes, expecting 200:**

1. `https://<API_HOST>/health/` — the API through Traefik.
2. `https://<APP_HOST>/` — the dashboard through Traefik.
3. `https://<API_HOST>/media/<probe path>` — through Traefik and the `media`
   service; the only probe that exercises the priority router and the shared
   volume mount.

**Two cleartext `:80` probes, expecting 301** — `http://127.0.0.1/health/` and
`http://127.0.0.1/`, each with an explicit `Host:` header (Traefik's routers
match on `Host(...)`, and a request without one falls through to no router at
all).

**301 is the pass for these, not 200.** They replaced the old
"bypass nginx and hit Traefik directly" probes, which existed to tell a gateway
fault apart from a bad release. There is no second layer to bypass now, so
there is nothing to discriminate: if Traefik is broken the application is
unreachable regardless.

What they catch instead is the failure that is *now* the silent one. If `:80`
stops answering, nothing user-facing breaks — every real client is already on
https — but the ACME challenge is answered there, so **certificate renewal
dies and the site fails everywhere at once up to 60 days later**. A deploy that
checked only https would report success every time, right up to the expiry.

So read a failure this way:

| https | `:80` | Means |
|---|---|---|
| pass | fail | Everything is serving, and renewal is broken. Nothing will look wrong until the certificate expires. Fix before that. |
| fail | pass | Traefik is up and routing, but the TLS entrypoint or the certificate is not working. Check the gateway logs for ACME errors. |
| fail | fail | The release is bad, or Traefik is down. The auto-rollback was correct. |

(pass/pass is the fourth, unlisted combination: everything is healthy.)

### A gateway restart is now a TLS event

Under the old topology, restarting Traefik moved routing only — nginx held TLS
and clients saw nothing. Traefik now terminates TLS itself, so
`up -d --no-deps --force-recreate traefik` drops every in-flight connection at
the edge rather than just re-reading routes.

It is still brief and still safe: certificates come back from the `traefik_acme`
volume, not from Let'''s Encrypt, so a restart neither re-issues anything nor
touches the rate limit. But it is no longer invisible, and it should not be
done casually during traffic.


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

- **`SECURE_SSL_REDIRECT` must stay `False`** in the server's `.env`. Traefik
  terminates TLS at the edge (§1) and forwards to `web` over plain HTTP —
  including for its own load-balancer health probes, which carry no
  `X-Forwarded-Proto` at all. If `SECURE_SSL_REDIRECT` were `True`, Django
  would answer every such request — including the probe of `/health/` — with a
  301 to https. Traefik's `healthcheck.status=200` label reads anything other
  than exactly 200 as unhealthy, so every `web` backend would drop out of
  rotation and the API would 503 across the board. The https redirect is the
  `web` entrypoint's job (§1), not Django's.

- **Request-size and timeout ceilings now live in Traefik, not in a host
  vhost.** The `body-limit` middleware's `maxRequestBodyBytes` (25 MB) and the
  `web-secure` entrypoint's `respondingTimeouts` (120s) carry the values the
  host nginx used to. Both must stay at or above the dashboard's own internal
  nginx (`25M`/`120s`) or a request the dashboard would have allowed fails one
  hop earlier, at the edge, before it reaches `web`.

  This pairing is **not** checked by anything — it is a judgement, not an
  equality. What *has* gone away is the drift problem: these values are in
  `traefik/` and the compose labels, which CD syncs on every deploy, so they
  can no longer be edited on the server and silently kept.

  One behavioural difference from nginx worth knowing: `buffering` reads the
  whole request body before forwarding it, whereas nginx rejected an oversized
  body from its declared `Content-Length` without reading it. `body-limit` is
  therefore applied to the `api` router only, and any route that streams should
  be checked against it before that is widened.

- **HSTS is set in exactly one place**: Traefik's `secure-headers` middleware
  (`traefik/dynamic/middlewares.yml`). With the host nginx gone there is no
  second emitter, so the doubled-header case that used to be possible here no
  longer is. See the `forceSTSHeader` note above for the setting that must
  *not* come back.

  HSTS now works through the plain `stsSeconds` / `stsIncludeSubdomains` /
  `stsPreload` settings, because Traefik terminates TLS itself and therefore
  considers these requests TLS.

  **`forceSTSHeader` has been removed, and must not be restored.** It existed
  only because TLS used to terminate at the host nginx, leaving every request
  Traefik saw as plain http on a loopback entrypoint — without it the `sts*`
  settings were silently inert. Under this topology it is not merely redundant:
  it would emit HSTS on the `:80` redirect response, i.e. over cleartext, which
  the spec says clients must ignore. Django is not a fallback either:
  `SECURE_HSTS_SECONDS` defaults to `0`. Verify against the real edge:

  ```bash
  curl -sI https://<APP_HOST>/ | grep -i strict
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
  `https://api.chatbot-demo.etqanbackend.tech/api/v1/billing/paddle/webhook/`, Paddle keeps sending
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
   dig +short api.chatbot-demo.etqanbackend.tech
   dig +short app.chatbot-demo.etqanbackend.tech
   ```
   both return this host's IP.
2. **Traefik has actually obtained a certificate for both hostnames:**
   ```bash
   docker exec chatbot-traefik-1 \
     wget -qO- http://127.0.0.1:8080/api/http/routers | tr ',' '\n' | grep -i tls
   ```
   There is no `certbot certificates` to run any more — issuance is Traefik's,
   and the state lives in the `traefik_acme` volume. The authoritative check is
   step 3 below; this one is for reading the gateway's own view when step 3
   fails.

   If no certificate was issued, the reason is almost always in the gateway
   log:
   ```bash
   docker logs chatbot-traefik-1 2>&1 | grep -i acme
   ```
   A rate-limit message there means §2.7's five-failures-per-hour limit has
   already been spent — fix DNS first, then wait it out. Retrying immediately
   only spends the next hour's.

3. **The certificate actually served is real, not Traefik's self-signed
   default:**
   ```bash
   curl -sI https://api.chatbot-demo.etqanbackend.tech/health/
   ```
   returns `HTTP/2 200` (or `HTTP/1.1 200`) with no certificate warning.

   **A `curl` certificate complaint here is the expected symptom of a failed
   ACME order**, not a separate fault: Traefik serves a self-signed certificate
   of its own for any host it has no real one for, so the port answers and the
   handshake completes — it is just untrusted. Do not read "the site loads with
   a warning" as "TLS is nearly working"; it means no certificate was ever
   issued. Go back to step 2.

4. **Traefik publishes both public ports, and nothing else:**
   ```bash
   docker port chatbot-traefik-1
   ```
   shows exactly `80/tcp -> 0.0.0.0:80` and `443/tcp -> 0.0.0.0:443` (IPv6
   `[::]` forms are equally fine). Three things are being checked at once:

   - **443 present and not loopback-bound** — otherwise nothing serves https.
   - **80 present and not loopback-bound** — nothing user-facing breaks if this
     is wrong, but certificate renewal stops and the site fails up to 60 days
     later. This is the one to be careful about.
   - **nothing else published** — the `traefik` API entrypoint serves the whole
     routing configuration.

   Every subsequent deploy re-checks this on its own: `deploy.sh`'s preflight
   (`assert_edge_publication`) runs the same `docker port` and refuses, before
   any mutation, unless all three hold. So this step is a first-deploy
   confirmation rather than the only guard — but it is still worth running by
   hand after any change made outside a deploy (a hand-run
   `docker compose up -d`, an edit to the compose file applied directly),
   because nothing checks that path.
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
