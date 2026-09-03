# click.ai — deployment meta-repo

This repository owns **deployment only**. It contains no application code; the two
components are git submodules that keep their own history and their own `main`.

```
chatbot/
├── chatbot_api/          → submodule: Etqan-agency/chatbot_api (Django 5.2 + DRF)
├── chatbot_dashboard/    → submodule: Etqan-agency/chatbot_dashboard (Vite + React 19)
├── traefik/              → gateway config            (not yet implemented)
├── scripts/              → deploy.sh, rollback.sh    (not yet implemented)
├── docker-compose.production.yml                     (not yet implemented)
└── .github/workflows/    → ci.yml, cd.yml, rollback.yml (not yet implemented)
```

## Clone

```bash
git clone --recurse-submodules git@github.com:Etqan-agency/chatbot.git
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

- `chatbot_api/docs/superpowers/specs/2026-09-03-infrastructure-pipeline-design.md`
- `chatbot_api/docs/superpowers/plans/2026-09-03-component-readiness.md`

## Next: sub-project 1, remaining phases

This repo's own contents — Traefik gateway, production compose, `deploy.sh` /
`rollback.sh`, and the `ci.yml` → `cd.yml` → `rollback.yml` pipeline — are the next
phase of work. Two constraints already established that the compose file must honour:

1. **A `media` service is mandatory.** The dashboard's nginx resolves `media:80` at
   parse time and will not start without it. Django serves `/media/` only under
   `DEBUG`, so media must come from a dedicated nginx bound read-only to the media
   volume, on a Traefik router with priority above the `web` catch-all.
2. **`ALLOWED_HOSTS` must include both the `api.` and `app.` hostnames.** The
   dashboard's nginx forwards `Host: app.<domain>`, and a bare apex does not cover
   subdomains — otherwise Django answers 400 to every proxied API request.

Merging the release PR into `main` here is intended to be the deploy decision: each
component's `sync-to-meta` workflow accumulates its submodule pointer bump on a
`release/next` branch and collects them into a single PR, so a commit on `main`
always carries a coherent set of pointers.
