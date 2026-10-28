# Deploy/rollback rehearsal

`bash scripts/e2e.sh [--fast] [--keep] [--purge]`

Brings the real production stack up locally, rolls it forward, forces a failed
smoke check, and rolls it back — asserting at each step. Wired into CI as the
`Deploy/Rollback Rehearsal` job, gated on the same `infra` path filter as
`infra-lint` and `rollout-tests`.

## What is real, and what is not

| | |
|---|---|
| **Real** | `docker-compose.production.yml`, `traefik/traefik.yml`, `traefik/dynamic/middlewares.yml`, `media/nginx.conf`, `scripts/deploy.sh`, `scripts/rollback.sh`, `scripts/lib/*`, postgres, redis, traefik, the socket proxy. Traefik is the edge here exactly as in production — it owns both ports and terminates TLS. |
| **Stand-in** | the two application images only — `api-standin/`, `dashboard-standin/` |

The stand-ins are built and tagged as `ghcr.io/etqan-agency/chatbot/{api,dashboard}`,
so the compose file runs **byte-for-byte unmodified** against them. They are not
mocks of the application; they implement the contract the compose file and
`services.sh` demand of whatever image is deployed:

- `web` listens on `:8000` and serves `/health/` — 200 normally, **503 once
  `/tmp/drain` exists**, which is the gate `retire_container` depends on
- a `manage.py` that answers `collectstatic` and `migrate`
- a `celery` that warm-shuts-down on SIGTERM (without the trap, `docker stop
  -t 360` would add six minutes to every worker roll)
- a `HEALTHCHECK`, so `wait_containers_healthy` is a real gate rather than an
  instant `none:running`
- an `X-E2E-Release` header, so "the roll swapped generations" is an
  observation rather than an inference from timing

Using stand-ins is deliberate. This repo owns the gateway topology and the
rollout mechanics; the application images are tested by their own repos' CI.
A rehearsal that built them would couple an infra gate to two submodules,
need a registry token, and re-run on every application change.

## What it proves that `rollout.test.sh` cannot

`scripts/lib/rollout.test.sh` stubs `docker` and proves the primitives in
isolation — 145 assertions, no daemon, no network. It cannot observe anything
outside the stub's model. This does:

- Traefik really host-routes these labels, and the `media` router's
  `priority=100` really beats the api catch-all on the same host
- a drained replica really leaves the pool, and the host keeps serving while
  it does
- a roll of `web` really drops **zero** requests under continuous load
  (`dashboard` is asserted against its documented non-zero residual instead —
  it has no drain route, and pretending otherwise would assert a property the
  design does not claim)
- `pg_dump | gzip` really reports its failures — against the real postgres
  image, including whether `bash` and `set -o pipefail` exist there at all
- Traefik really terminates TLS, really redirects `:80` to `:443`, and really
  leaves `/.well-known/acme-challenge/` unredirected — the priority ordering
  the whole certificate-renewal path depends on
- a rollback really survives an unreachable registry
- the pool really converges after a roll, before anything probes it

Three defects it found on its first runs, none of which any existing check
could see: `rollback.sh` aborting on `docker compose pull` (no rollback during
a registry outage), Traefik discovering a co-tenant project's containers and
discarding both stacks' routers on a name collision, and `deploy.sh` smoking
immediately after a roll while Traefik still held a removed backend — whose IP
is gone from the bridge, so requests hang rather than failing fast.

That last one is why this exists in its current shape. The `:443` block used to
`include /etc/letsencrypt/options-ssl-nginx.conf` and reference
`ssl-dhparams.pem` — files written only by certbot's *nginx installer*, which
`certonly --webroot` never runs. On a host that had never run `certbot --nginx`,
step 3 of the runbook failed `nginx -t`. `$WORK/edge/letsencrypt/` is kept empty
of those files on purpose; do not "fix" it by adding them.

## Ports, and why URLs still look like production

The edge wants `80`/`443`. If they are taken it falls back to `8080`/`8443`
(then `9080`/`9443`, `18080`/`18443`), rewriting only the two `listen` lines.
Probes reach it with `curl --connect-to`, not `--resolve`: `--resolve` can only
remap the address for the port already in the URL, so a fallback port would
have to appear in every URL — changing the `Host` header, the redirect target
and the smoke probes themselves. `--connect-to` remaps address *and* port while
leaving the request exactly as production issues it.

## Blast radius

- The compose project name is pinned to `chatbot` and **cannot** be changed for
  this run: `rollout.sh` matches containers by the `chatbot-` prefix and execs
  into `chatbot-traefik-1`, and `traefik.yml` names the `chatbot_default`
  network. The script refuses to start while any container of that project
  exists.
- Teardown removes containers but **keeps** named volumes, so the run is not
  hermetic: it reuses whatever `chatbot_pgdata` holds, and its backups land in
  the existing `chatbot_pgbackups`, where `deploy.sh`'s own 14-file retention
  sweep can rotate older archives out. `--purge` switches to `down -v`, which
  is hermetic but destroys those volumes.
- `deploy.sh` ends with `docker image prune -f`, which removes dangling images
  belonging to anything else on the machine.
- The stand-in images are tagged as the *production* repository, which is what
  lets the compose file run unmodified. Teardown deletes them again so nothing
  that looks like a real release is left lying around; the layer cache means a
  re-run rebuilds them in seconds.
- Never point any of this at a server.

## Flags

| flag | effect |
|---|---|
| `--fast` | drain settle window 15s → 7s. Still above Traefik's 5s healthcheck interval, so the drain is genuinely observed. What CI uses. |
| `--keep` | leave the stack and work directory up for inspection |
| `--purge` | destroy the named volumes on teardown |
