# click.ai — deployment meta-repo

This repository owns **deployment only**. It contains no application code; the two
components are git submodules that keep their own history and their own `main`.

```
chatbot/
├── chabot_dev_api/          → submodule: Etqan-agency/chabot_dev_api (Django 5.2 + DRF)
├── chabot_dev_dash/    → submodule: Etqan-agency/chabot_dev_dash (Vite + React 19)
├── traefik/              → Traefik v3 static config (traefik.yml) and dynamic
│                           middlewares (traefik/dynamic/middlewares.yml) --
│                           pending merge via the open gateway/compose PR
├── scripts/              → deploy.sh, rollback.sh    (not yet implemented -- Plan 3)
├── docker-compose.production.yml → gateway, data tier, API, worker, media and
│                           dashboard services -- pending merge via the open
│                           gateway/compose PR
└── .github/workflows/    → ci.yml (lint, test against Postgres, publish both
                            images to GHCR) and sync-to-meta.yml (lives in each
                            component repo, not here -- see below); cd.yml and
                            rollback.yml are not yet implemented (Plan 3)
```

## Clone

```bash
git clone --recurse-submodules git@github.com:Etqan-agency/chatbot-zaychain.git
# already cloned?
git submodule update --init --recursive
```

## Status

Sub-project 1 of 4 (**component readiness**) is complete and under review on the
`infra/component-readiness` branch of each component:

- Python 3.13 across image, CI and local dev; `ruff` + `pre-commit` gate enforced
- Drain-aware `/health/` probe (503 while the drain file exists) — the mechanism the
  rolling deploy needs to take a replica out of rotation before stopping it
- Local dev CORS origins trusted only when `DEBUG`; production origins come solely
  from the environment
- Hardened production images for both components: multi-stage, non-root, health-checked
- Dashboard served by nginx reproducing the Vercel `/api` + `/media` rewrites, so the
  SPA stays same-origin and no API hostname is baked into the bundle

The design and plan documents live in the API submodule:

- `chabot_dev_api/docs/superpowers/specs/2026-09-03-infrastructure-pipeline-design.md`
- `chabot_dev_api/docs/superpowers/plans/2026-09-03-component-readiness.md`

## Operations

- [`docs/DEPLOY.md`](docs/DEPLOY.md) — provisioning, deploys, rollbacks, the
  cutover checklist, and the residuals this topology accepts.

## Next: sub-project 1, remaining phases

The Traefik gateway, production compose file, and `ci.yml` have been written on the
`infra/gateway-compose-ci` branch and are on an open PR into `main`; CI itself is
green there and publishes both images to GHCR. Two constraints already established
that the compose file must honour:

1. **A `media` service is mandatory.** The dashboard's nginx resolves `media:80` at
   parse time and will not start without it. Django serves `/media/` only under
   `DEBUG`, so media must come from a dedicated nginx bound read-only to the media
   volume, on a Traefik router with priority above the `web` catch-all.
2. **`ALLOWED_HOSTS` must include both the `api.` and `app.` hostnames.** The
   dashboard's nginx forwards `Host: app.<domain>`, and a bare apex does not cover
   subdomains — otherwise Django answers 400 to every proxied API request.

Each component now has its own `sync-to-meta.yml` workflow (in `chabot_dev_api` and
`chabot_dev_dash`, not in this repo): pushing to a component's `main` bumps that
component's submodule pointer here on a shared `release/next` branch and opens or
updates a single "Release: submodule pointer updates" PR. Merging that PR into
`main` is intended to be the deploy decision, since a commit on `main` always
carries a coherent set of pointers — this is what stops a new API deploying
against an old dashboard, or vice versa.

Still outstanding for sub-project 1 (Plan 3): `scripts/deploy.sh`,
`scripts/rollback.sh`, `cd.yml`, `rollback.yml`, VPS provisioning verification,
and the DNS cutover.
