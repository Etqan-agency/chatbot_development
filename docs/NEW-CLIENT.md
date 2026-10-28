# Standing up a new client deployment

This repository deploys **one** environment to **one** host. Nothing in it is
parameterised by client or environment: the image path, the two public
hostnames, and the deploy target are each written in exactly one place and
read as constants everywhere else.

So a second client gets a **fork** — its own repository, its own GHCR images,
its own server, its own secrets. This document is the list of couplings a fork
must break, in the order they bite, followed by the parts of the existing
runbook that apply unchanged.

Read [`DEPLOY.md`](DEPLOY.md) first. This document does not repeat it; it only
records what is *different* about a fork. Everything in `DEPLOY.md` §2
(provisioning), §4 (a normal deploy), §5 (rollback) and §11 (first-deploy
checklist) applies to the fork verbatim once the substitutions below are done.

Throughout, substitute:

| Placeholder | Meaning | Example from the original |
|---|---|---|
| `<ORG>/<REPO>` | The fork's GitHub owner and name | `Etqan-agency/chatbot` |
| `<org>/<repo>` | The same, **lowercased** (the registry demands it) | `etqan-agency/chatbot` |
| `<API_HOST>` | The API hostname | `api.chatbot-demo.etqanbackend.tech` |
| `<APP_HOST>` | The dashboard hostname | `app.chatbot-demo.etqanbackend.tech` |

`<API_HOST>` and `<APP_HOST>` are **independent values**. Do not derive one
from the other or from a shared base — the original's domain is shared with
unrelated servers, and a fork's may be too.

---

## 1. Decide the submodule policy first

This is the decision that is expensive to reverse, so make it before forking.

`chabot_dev_api` and `chabot_dev_dash` are submodules
([`.gitmodules`](../.gitmodules)) pointing at `Etqan-agency/chabot_dev_api` and
`Etqan-agency/chabot_dev_dash`. **Forking the meta-repository does not fork
them** — the fork's `.gitmodules` still points at the originals.

More importantly: each component repository has its own `sync-to-meta`
workflow that bumps the submodule pointer and opens the release PR **against
the original meta-repository only** ([`cd.yml:5-16`](../.github/workflows/cd.yml#L5-L16)).
It knows nothing about forks. So whichever option you choose, **the fork will
not receive automatic pointer bumps.** Something has to advance them.

| Option | What it means | Cost |
|---|---|---|
| **Track upstream components** (shared codebase) | Fork's `.gitmodules` keeps pointing at `Etqan-agency/*`. All clients run the same application code, pinned at different commits. | Fork's CI needs a `SUBMODULE_TOKEN` with read access to the component repos. Pointer bumps are advanced by hand, or by adding the fork as a second target in each component's `sync-to-meta`. |
| **Fork the components too** (divergent codebase) | Three forks per client. The client can carry bespoke application changes. | Every upstream fix must be merged into three repositories per client. This compounds fast — do not choose it to accommodate configuration differences that belong in `.env`. |

Default to **tracking upstream** unless the client genuinely needs different
application code. Per-client *configuration* belongs in `.env` on the server,
not in a code fork.

---

## 2. Couplings the fork must change

Each of these is a hardcoded constant. None of them fails loudly in a way that
points at the real cause, which is why they are enumerated rather than left to
be discovered.

### 2.1 Registry path — 5 lines, 2 files, plus the compose file

CI pushes to `IMAGE_PREFIX` and CD verifies the same path. In a fork under a
different owner, CI will push to the fork's namespace while CD still looks in
the original's — and CD's failure is `Image not found in the registry`, which
reads exactly like a broken build.

- [`.github/workflows/ci.yml:19`](../.github/workflows/ci.yml#L19) — `IMAGE_PREFIX: <org>/<repo>`
- [`.github/workflows/cd.yml:40`](../.github/workflows/cd.yml#L40) — `IMAGE_PREFIX: <org>/<repo>`
- [`docker-compose.production.yml:103`](../docker-compose.production.yml#L103) (`web`), [`:146`](../docker-compose.production.yml#L146) (`worker`), [`:202`](../docker-compose.production.yml#L202) (`dashboard`) — `ghcr.io/<org>/<repo>/api` and `.../dashboard`

Lowercase is not stylistic. The registry rejects uppercase in a repository
path, and GitHub owner names are frequently mixed-case.

### 2.2 The ACME account email

`traefik/traefik.yml` carries the Let's Encrypt account email under
`certificatesResolvers.letsencrypt.acme.email`, and each fork must set its own.

It is in the file rather than an environment variable deliberately: Traefik
takes its static configuration from a file **or** environment variables **or**
CLI flags, and mixing them is not a documented merge — so one source means
nothing silently half-applies. That does mean this line conflicts on an
upstream merge, which is expected and is the cheapest of the alternatives.

This is also the one place a fork can reasonably want a different `caServer`
while testing; see §5.

> **There are no nginx vhosts to rename.** Earlier revisions of this document
> had a long section here about `docs/nginx/*.conf`, the `server_name` inside
> them, the commented-out `:443` block and the drift check that compared them
> against `/etc/nginx/sites-available/`. All of it is gone with the host nginx.
> Traefik takes the hostnames from `${API_HOST}`/`${APP_HOST}` in the server's
> `.env` via the compose router labels, so §2.3 below is the only place a
> hostname is written in the repository at all.


### 2.3 `.env.example` — the hostnames, and the only place they appear

[`.env.example`](../.env.example) is the template the server's `.env` is
written from, and since the nginx vhosts went away it is the **only** file in
the repository that names a hostname. `scripts/e2e.sh` reads its `API_HOST` and
`APP_HOST` to drive the whole rehearsal, and the compose router labels read the
same two keys from the server's real `.env`. Update:

`API_HOST`, `APP_HOST`, `ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`, `FRONTEND_URL`
— and note `ALLOWED_HOSTS` must keep `localhost,127.0.0.1` alongside both new
hostnames. `DEPLOY.md` §11.6 explains the failure: miss one and Traefik's
healthcheck (which sends `Host: <API_HOST>`) gets a 400, every backend reads
as unhealthy, and the whole service leaves rotation.

`.env` itself is gitignored and written on the server by hand. It never enters
Git and CD never syncs it.

### 2.4 Prose references to the original host

`DEPLOY.md` names `api.chatbot-demo.etqanbackend.tech` throughout, including in
§9's Paddle and Meta WhatsApp webhook URLs. Nothing executes these, but §10 is
a checklist someone follows under time pressure — a stale URL there is a
webhook pointed at the wrong host, and that fails silently while payments stop
being fulfilled.

---

## 3. Fork-time checklist

```text
[ ] Submodule policy decided (§1)
[ ] Repository forked / created as <ORG>/<REPO>
[ ] IMAGE_PREFIX updated in ci.yml and cd.yml               (§2.1)
[ ] Three image paths updated in docker-compose.production.yml (§2.1)
[ ] ACME account email set in traefik/traefik.yml            (§2.2)
[ ] .env.example's five hostname values updated              (§2.3)
[ ] DNS A records for both hostnames point at the new host   (§5)
[ ] bash scripts/e2e.sh passes locally                       (proves §2.1–2.3)
[ ] GHCR packages for the fork exist and are readable by GHCR_PAT
```

Run `scripts/e2e.sh` before touching a server. It brings the real gateway up
and exercises TLS termination, the `:80` redirect, the ACME challenge path, the
rolling deploy, the drain gate and rollback against stand-in images. It never
contacts Let's Encrypt — it points `caServer` at a dead local address in its own
throwaway copy of `traefik.yml` — so it is safe to run repeatedly.

## 4. GitHub secrets and variables

Set on the fork, per [`DEPLOY.md`](DEPLOY.md) §3 — that table lists what each
one breaks when wrong, which is the useful part.

Seven secrets: `SUBMODULE_TOKEN`, `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`,
`DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_PATH`, `GHCR_PAT`.
Two repository **variables** (not secrets): `API_HOST`, `APP_HOST` — cosmetic
only, used for the environment link and the summary table. The authoritative
values are in the server's `.env`.

`SSH_KNOWN_HOSTS` must come from a real `ssh-keyscan` against the new host.
Left empty it does not fail closed — it silently accepts whatever host answers.

`GHCR_PAT` needs read access to the **fork's** packages (§2.1), not the
original's.

## 5. Provisioning and first deploy

Follow [`DEPLOY.md`](DEPLOY.md) §2 as written, substituting the new hostnames.
Nothing in it is specific to the original client. Three things there are worth
flagging because they are the ones that go wrong:

- **8 GB RAM, not 4** (§2.1). A roll briefly runs two generations of a
  2-replica service, so peak is roughly double steady state. A 4 GB host boots
  fine and fails partway through the first real rollout.
- **DNS must resolve, and `:80` must be publicly reachable, BEFORE the first
  bring-up** (§2.7) — not before a separate certificate step, because there
  isn't one. Traefik requests certificates itself the first time a handshake
  arrives. There is no certbot to install and no vhost to write.

  **Rehearse against the Let's Encrypt staging CA on a fork's first host.** The
  production CA allows five failed authorisations per account, per hostname,
  per hour, and a new client is exactly the situation where DNS is likeliest to
  be half-propagated. `DEPLOY.md` §2.7 has the one-line `caServer` change and
  how to back it out. A fork that skips this and gets it wrong is locked out of
  issuing that hostname's certificate for the rest of the hour.

  **Do not mistake "loads with a certificate warning" for "nearly working".**
  Traefik serves a self-signed certificate for any host it has no real one for,
  so a failed ACME order still answers on 443 and still completes a handshake.
  It means no certificate was ever issued. `DEPLOY.md` §11.3 covers this.
- **Bring the stack up once by hand before any CD run** (§2.8). `deploy.sh`
  deploys, it does not bootstrap: its preflight refuses unless `web` is already
  running at 2 replicas with Traefik backends registered.

Then work [`DEPLOY.md`](DEPLOY.md) §11's first-deploy checklist, ending with a
`dry_run: true` CD run — it proves image access and the SSH/sync path without
touching a running container.

**§9 (cutover) and §10 (silent-failure checklist) do not apply** to a new
client with no existing data or traffic. The exception is §10's last item,
which applies to any deployment: **`DEBUG` must be `False`**, or `/media/` is
served by both Django and the `media` service with different cache headers, and
which one answers becomes routing-dependent.

New client, new Paddle and Meta WhatsApp webhook registrations — pointed at
`<API_HOST>` from the start rather than repointed.

## 6. The ongoing cost

A fork does not stay in sync by itself. Every upstream fix to `deploy.sh`,
`rollout.sh`, the compose file or the workflows has to be merged into every
client fork, and the merge conflicts will land precisely on the lines §2 told
you to change — that is the same set of lines, by construction.

Keep the fork's divergence from upstream limited to §2's list. Anything else
that differs per client belongs in `.env` on that client's server, where it
costs nothing to maintain. The moment a second thing diverges in code, the
fork stops being a configuration change and becomes a maintenance burden that
grows with the client count.
