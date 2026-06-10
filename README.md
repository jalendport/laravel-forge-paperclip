# Laravel Forge — Paperclip

A ready-to-deploy [Paperclip](https://github.com/paperclipai/paperclip) stack for a [Laravel Forge](https://forge.laravel.com/) server. Paperclip is an open-source control plane for orchestrating teams of AI coding agents (Claude Code, Codex, OpenCode, Gemini). This repo runs it with a dedicated PostgreSQL database in Docker, reachable **only over your [Tailscale](https://tailscale.com/) network** — no public ports, no internet-facing login page.

Fork it, point Forge at your fork, fill in a `.env`, and deploy — no nginx config, no manual certificates, no `docker` commands to memorize.

> **Why Tailscale-only?** Paperclip is an admin panel that holds your LLM API keys and can execute code through its agents. The blast radius of exposing it is much larger than a read-only analytics dashboard, so this stack deliberately keeps it off the public internet. Access is over your tailnet, with HTTPS terminated by `tailscale serve`.

## Table of contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Step 1 — Fork this repo](#step-1--fork-this-repo)
- [Step 2 — Create the site and connect your fork](#step-2--create-the-site-and-connect-your-fork)
- [Step 3 — Configure the environment](#step-3--configure-the-environment)
- [Step 4 — Deploy](#step-4--deploy)
- [Step 5 — Claim your board (first run)](#step-5--claim-your-board-first-run)
- [Step 6 — Add your LLM provider keys](#step-6--add-your-llm-provider-keys)
- [Backups](#backups)
- [Restoring from a backup](#restoring-from-a-backup)
- [Upgrading Paperclip](#upgrading-paperclip)
- [Configuration reference](#configuration-reference)
- [Security notes](#security-notes)
- [Makefile shortcuts](#makefile-shortcuts)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## How it works

- **Two containers, one stack.** [`docker-compose.yml`](docker-compose.yml) runs the Paperclip server (Node app + React UI, with the `claude` / `codex` / `opencode` / `gemini` CLIs pre-installed for in-container agents) and a dedicated PostgreSQL 17 database. Each has a healthcheck and a persistent named volume; Paperclip waits for Postgres to be healthy before starting, and runs its schema migrations automatically on boot.
- **Private over Tailscale.** Paperclip publishes nothing to the public internet. It binds to `127.0.0.1:3100` on the host, and [`deploy.sh`](deploy.sh) points `tailscale serve` at it so the app is reachable at `https://<your-server>.<your-tailnet>.ts.net` with a real Tailscale-issued certificate. It runs in `authenticated` + `private` mode, so a login is still required even on the tailnet.
- **Git-based deploys.** Forge pulls your fork and runs [`deploy.sh`](deploy.sh), which pulls the pinned image, brings the stack up, and (re)applies the `tailscale serve` mapping idempotently.
- **Pinned builds.** Paperclip only publishes `latest` and `sha-<commit>` image tags (there is no semver image tag). The stack pins an exact `sha-<commit>`, so deploys are reproducible and upgrades are an explicit, reviewable change.
- **Secrets stay encrypted.** Provider API keys are **not** stored in this repo or `.env`. You add them in Paperclip's Secrets UI; they are encrypted at rest with a master key you supply via `.env` and bound to agents individually.

> This stack expects the host to already be on your tailnet. The **[Install Tailscale recipe](https://github.com/jalendport/laravel-forge-recipes/tree/HEAD/recipes/install-tailscale)** sets that up (installs Tailscale, joins the tailnet, sets the `forge` operator). It's the private-network analog of the Install Docker recipe — run it once at/after provision, just like Docker.

## Prerequisites

- A **Laravel Forge** account connected to a server provider, with **Docker + the Compose plugin** installed on the server.
- The server **already joined to your Tailscale tailnet**, with **MagicDNS** and **HTTPS certificates** enabled in the [Tailscale admin console](https://login.tailscale.com/admin/dns). Set this up with the **[Install Tailscale recipe](https://github.com/jalendport/laravel-forge-recipes/tree/HEAD/recipes/install-tailscale)** before deploying here. You'll need the server's MagicDNS name (e.g. `my-server.tailnet-name.ts.net`).
- A device on the same tailnet (your laptop/phone) to reach the dashboard.
- A **GitHub account** to fork this repo, so Forge can deploy *your* copy.
- An **LLM provider API key** (Anthropic, OpenAI, …) for the agents to actually do work — added later via the Secrets UI, not now.

## Step 1 — Fork this repo

Forge deploys from a Git repository it can access, so you need your own copy.

1. Click **Fork** at the top of this repository on GitHub.
2. (Optional) Make the fork **private** — Forge supports private repositories.

You'll point Forge at this fork in [Step 2](#step-2--create-the-site-and-connect-your-fork).

## Step 2 — Create the site and connect your fork

A Forge "site" gives you Git-based deployment.

1. On the server, click **New site → Other** — *not* Laravel/PHP. This is a Docker stack, not a PHP app.
2. Fill in the **Create a new site** form:
   - **Name** — just a label; it becomes the site directory at `/home/forge/<name>` (e.g. `paperclip` → `/home/forge/paperclip`). It is **not** a real domain — Tailscale handles routing.
   - **Source control / Repository / Branch** — connect your **forked repo** and the `main` branch.
   - **Generate a site deploy key** — leave **off** for a public fork; turn it on only for a **private** repo.
3. Open **Advanced settings** and disable **both** toggles:
   - **Push to deploy** — off, so a push doesn't auto-redeploy. Deploy manually after reviewing changes.
   - **Zero downtime deployments** — off. **This is required and important.** Zero-downtime mode deploys into a new `releases/<timestamp>` directory each time. Docker Compose derives its project name from the directory, so a new directory means new container/volume names every deploy — which would **orphan your database and data volumes and lose everything**. The plain in-place `git pull` model is what this stack needs.
4. Create the site, then open its **deploy script** and replace it with:

   ```bash
   cd $FORGE_SITE_PATH
   git pull origin $FORGE_SITE_BRANCH
   bash deploy.sh
   ```

   Forge pulls the latest code first, then runs the repo's tracked [`deploy.sh`](deploy.sh).

> **No sudo needed for `tailscale serve`.** Forge runs the deploy script with no TTY, so it can't answer an interactive `sudo` password prompt. That's why the Install Tailscale recipe sets the Tailscale **operator** to `forge` — it lets the deploy user run `tailscale serve` directly, without sudo. `deploy.sh` uses that path (and falls back to non-interactive `sudo -n` only if the operator isn't set but the deploy user happens to have passwordless sudo). If you installed Tailscale some other way, run `sudo tailscale set --operator=$(whoami)` once over SSH so deploys can manage the serve mapping.

## Step 3 — Configure the environment

Provide settings via Forge's **Environment** editor (site → **Environment**). Forge writes them to a `.env` file in the site root, which Docker Compose reads automatically. The real `.env` is gitignored and never committed.

Use [`example.env`](example.env) as the template. The essentials:

| Variable | What to put |
|---|---|
| `PAPERCLIP_PUBLIC_URL` | Your server's Tailscale URL — e.g. `https://my-server.tailnet-name.ts.net` (https, no trailing slash) |
| `BETTER_AUTH_SECRET` | A session secret — `openssl rand -base64 48` |
| `PAPERCLIP_SECRETS_MASTER_KEY` | The secrets encryption key — `openssl rand -base64 32` (**store in your password manager**) |
| `POSTGRES_PASSWORD` | The database password — `openssl rand -base64 24` (**set once, before the first deploy**) |

The deployment posture (`PAPERCLIP_DEPLOYMENT_MODE=authenticated`, `PAPERCLIP_DEPLOYMENT_EXPOSURE=private`, `PAPERCLIP_SECRETS_STRICT_MODE=true`) is pre-filled in `example.env` and rarely needs changing.

### Generate the secrets

Run these anywhere (your laptop or the server over SSH) and paste the output:

```bash
openssl rand -base64 48   # BETTER_AUTH_SECRET
openssl rand -base64 32   # PAPERCLIP_SECRETS_MASTER_KEY
openssl rand -base64 24   # POSTGRES_PASSWORD
```

> ⚠️ **Keep `PAPERCLIP_SECRETS_MASTER_KEY` safe and stable.** Every secret you store in Paperclip's UI is encrypted with it. It is **not** included in any backup, so save it in your password manager — a database restore without it cannot decrypt your secrets. Rotating it orphans all existing secrets.
>
> ⚠️ **Set `POSTGRES_PASSWORD` once, before the first deploy.** Changing it after the database volume is initialized breaks authentication until you reset the volume.

## Step 4 — Deploy

Trigger a deploy from Forge (**Deploy Now**). The first deploy pulls the images and initializes the database, so give it a minute. Then SSH in and verify:

```bash
cd $FORGE_SITE_PATH         # /home/forge/paperclip
docker compose ps           # both services "running"; paperclip becomes "healthy"
docker compose logs -f paperclip
```

Confirm Tailscale is serving it (from the server):

```bash
sudo tailscale serve status   # should show https://<server>.<tailnet>.ts.net -> http://127.0.0.1:3100
```

Once `paperclip` reports **healthy**, open `https://<your-server>.<your-tailnet>.ts.net` **from a device on the same tailnet** — you should get the Paperclip login screen over a trusted certificate.

## Step 5 — Claim your board (first run)

On first start in `authenticated` mode, Paperclip emits a one-time **board-claim** URL in its logs. A signed-in user visits it to become the instance admin.

1. Register/sign in at `https://<your-server>.<your-tailnet>.ts.net`.
2. Grab the claim URL from the logs:

   ```bash
   cd $FORGE_SITE_PATH
   make claim          # or: docker compose logs paperclip | grep -i board-claim
   ```

3. Visit the printed `/board-claim/<token>?code=<code>` URL while signed in. This promotes you to instance admin and demotes the auto-created local admin.

## Step 6 — Add your LLM provider keys

Agents need provider credentials to run. This stack keeps them **out of `.env`** and in Paperclip's encrypted Secrets store instead (strict secrets mode is on).

1. In the dashboard, open **Company Settings → Secrets**.
2. Create a secret for each provider key you use — e.g. a secret holding your `ANTHROPIC_API_KEY` value, another for `OPENAI_API_KEY`, etc.
3. On each agent (or project), open its **Environment variables** field, add the key the CLI expects (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, …), set the row **source** to **Secret**, and select the stored secret.

At runtime Paperclip decrypts the bound secret server-side and injects it into that agent's process only — so each agent gets just the keys it needs, and nothing sits in plaintext on disk. The in-container `claude_local` / `codex_local` / `opencode_local` / `gemini_local` adapters then run with those credentials.

## Backups

Your data lives in two Docker volumes — **you own the backups.** Two hardened scripts dump them into [`backups/`](backups/) (gitignored), compress them, and prune old copies:

| Script | Backs up | Output | Default retention |
|---|---|---|---|
| [`scripts/db-backup.sh`](scripts/db-backup.sh) | PostgreSQL (companies, agents, issues, secret *metadata*) | `backups/db/*.sql.gz` | newest 20 |
| [`scripts/data-backup.sh`](scripts/data-backup.sh) | `/paperclip` volume (uploads, instance config, agent workspaces/memory) | `backups/data/*.tar.gz` | newest 20 |

Both are safe to run unattended (no TTY required) and fail loudly if anything goes wrong. Run them by hand with `make backup`, or — recommended — schedule them in Forge.

> 🔑 **The encryption master key is not in either backup.** It lives in `.env` as `PAPERCLIP_SECRETS_MASTER_KEY`. Keep it in your password manager. A backup without it cannot decrypt the secrets you stored in the UI.

### Schedule with Forge

Forge has a built-in **Scheduler** (site or server → **Scheduler**). Add two jobs as the `forge` user:

| Command | Suggested frequency |
|---|---|
| `/home/forge/paperclip/scripts/db-backup.sh` | Hourly or daily |
| `/home/forge/paperclip/scripts/data-backup.sh` | Daily |

Adjust paths to match your site name and tune the retention constant (`CONFIG_KEEP_BACKUPS`) at the top of each script.

> Backups are stored on the same server. For real durability, also copy `backups/` off-box periodically (e.g. an `rclone`/`rsync` Forge job to object storage). Test a restore occasionally — an untested backup isn't a backup.

## Restoring from a backup

> ⚠️ Restores are **destructive**. Paperclip is stopped during the restore and restarted automatically afterwards (even if the restore fails). Make sure the same `PAPERCLIP_SECRETS_MASTER_KEY` is in `.env` before restoring, or stored secrets won't decrypt.

PostgreSQL — pass the path to a `.sql.gz` (or `.sql`):

```bash
cd $FORGE_SITE_PATH
./scripts/db-restore.sh backups/db/paperclip_db_backup_YYYYMMDD_HHMMSS.sql.gz
# or: make restore-db FILE=backups/db/paperclip_db_backup_YYYYMMDD_HHMMSS.sql.gz
```

Data volume — pass the path to a `.tar.gz`:

```bash
cd $FORGE_SITE_PATH
./scripts/data-restore.sh backups/data/paperclip_data_backup_YYYYMMDD_HHMMSS.tar.gz
# or: make restore-data FILE=backups/data/paperclip_data_backup_YYYYMMDD_HHMMSS.tar.gz
```

The PostgreSQL restore uses `ON_ERROR_STOP=1`, so a corrupt or partial dump fails the restore instead of silently leaving you with a half-loaded database. For a full disaster recovery, restore **both** the database and the data volume from the same time window.

## Upgrading Paperclip

The image is pinned to an exact `sha-<commit>` in [`docker-compose.yml`](docker-compose.yml), so upgrades are deliberate. Paperclip publishes no semver image tag — you pin to a commit sha.

1. **Back up first** — `make backup` (or wait for a scheduled run).
2. Find the sha you want to move to. Each commit on [`paperclipai/paperclip`](https://github.com/paperclipai/paperclip) is published as `sha-<short-commit>`. To track a tagged release, look up that release's commit and use its short sha — for example release `v2026.529.0` is commit `911a1e8`, i.e. `sha-911a1e8` (the current pin). You can list published tags from the registry:

   ```bash
   token=$(curl -fsSL "https://ghcr.io/token?scope=repository:paperclipai/paperclip:pull&service=ghcr.io" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
   curl -fsSL -H "Authorization: Bearer $token" "https://ghcr.io/v2/paperclipai/paperclip/tags/list?n=50"
   ```

3. Bump the `image:` sha in `docker-compose.yml`, commit, and push to your fork.
4. Deploy from Forge. The deploy script runs `docker compose pull` and recreates the container; **schema migrations run automatically** on startup.
5. Once healthy, remove the old image: `make prune`.

Both volumes persist across upgrades, so your data is untouched. Read the [Paperclip changelog / releases](https://github.com/paperclipai/paperclip/releases) before a big jump.

> **PostgreSQL major upgrades** (e.g. `postgres:17` → a future `:18`) are *not* automatic and require a dump/restore. This repo pins Postgres 17; don't bump it casually — `make backup-db`, then restore into the new major version.

## Configuration reference

Full reference: Paperclip's [environment variables](https://github.com/paperclipai/paperclip/blob/master/docs/deploy/environment-variables.md) and [deployment modes](https://github.com/paperclipai/paperclip/blob/master/docs/deploy/deployment-modes.md) docs. The variables this stack wires through [`example.env`](example.env):

| Variable | Default | Notes |
|---|---|---|
| `PAPERCLIP_PUBLIC_URL` | — | **Required.** Your tailnet HTTPS URL. |
| `BETTER_AUTH_SECRET` | — | **Required.** Session secret; `openssl rand -base64 48`. |
| `PAPERCLIP_SECRETS_MASTER_KEY` | — | **Required.** 32-byte key; encrypts the Secrets UI. Back up separately. |
| `POSTGRES_PASSWORD` | — | **Required.** DB password; set once before first deploy. |
| `PAPERCLIP_DEPLOYMENT_MODE` | `authenticated` | Login required. |
| `PAPERCLIP_DEPLOYMENT_EXPOSURE` | `private` | Private (Tailscale/LAN/VPN) exposure. |
| `PAPERCLIP_SECRETS_STRICT_MODE` | `true` | Force `*_API_KEY` / `*_TOKEN` to use encrypted secret refs. |
| `DATABASE_URL` | (wired in compose) | Points at the bundled `db` service; override only for external Postgres. |

Provider keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, …) are **not** environment variables here — add them in the Secrets UI ([Step 6](#step-6--add-your-llm-provider-keys)).

## Security notes

- **Agents run inside the Paperclip container.** The `*_local` adapters execute agent CLIs as subprocesses in the app container, so an agent can read whatever that process can. Keep strict secrets mode on, and bind each agent only the secrets it needs. For stronger isolation later, Paperclip supports cloud/sandboxed adapters.
- **Nothing is public.** No ports are published to `0.0.0.0`; the app is loopback-only and reached solely through `tailscale serve`. Anyone who can reach the dashboard is already on your tailnet — manage tailnet ACLs accordingly.
- **Custom private hostname errors?** If you reach Paperclip via a hostname it doesn't trust, add it to the allowlist (see Troubleshooting).

## Makefile shortcuts

Run `make help` for the full list. Common ones (run from the site directory):

| Command | Does |
|---|---|
| `make up` / `make down` | Start / stop the stack |
| `make ps` / `make logs` | Status / follow logs (`make logs S=paperclip` to scope) |
| `make claim` | Print the first-run board-claim URL from the logs |
| `make upgrade` | Pull images and recreate containers (after bumping the sha) |
| `make prune` | Remove old images after an upgrade |
| `make backup` | Back up the database and data volume |
| `make restore-db FILE=…` / `make restore-data FILE=…` | Restore from a backup |

## Troubleshooting

**Can't reach the dashboard at all.**
- Are you on the same tailnet as the server? Check `tailscale status` on both devices.
- On the server: `sudo tailscale serve status` should map `https://…ts.net` → `http://127.0.0.1:3100`. If empty, re-run a deploy or `sudo tailscale serve --bg --https=443 http://127.0.0.1:3100`.
- Confirm `paperclip` is healthy: `docker compose ps`. The healthcheck hits `/api/health`.

**No HTTPS certificate / cert error on the `.ts.net` name.** Enable **HTTPS Certificates** (and **MagicDNS**) in the [Tailscale admin DNS settings](https://login.tailscale.com/admin/dns). Tailscale issues the cert for `serve` automatically once enabled.

**Login or redirect errors on the tailnet hostname.** Paperclip doesn't trust the host you're using. Make sure `PAPERCLIP_PUBLIC_URL` exactly matches the URL you open. If you reach it via a different private hostname, allow it inside the container:

```bash
docker compose exec paperclip paperclipai allowed-hostname my-server.tailnet-name.ts.net
```

(If `paperclipai` isn't on the container's PATH, run it via the app's CLI entrypoint — check `docker compose exec paperclip sh -lc 'which paperclipai'`.)

**`paperclip` container is `unhealthy`.** Check `docker compose logs paperclip`. Usually it can't reach Postgres (wait for `db` to be healthy first) or a required env var is missing — the `:?` guards in `docker-compose.yml` fail the deploy loudly if `PAPERCLIP_PUBLIC_URL`, `BETTER_AUTH_SECRET`, `PAPERCLIP_SECRETS_MASTER_KEY`, or `POSTGRES_PASSWORD` is unset.

**`tailscale serve` failed during deploy** (e.g. `sudo: a password is required`). The Docker stack still came up (the script warns rather than fails); only the tailnet mapping is missing. The deploy user needs to run `tailscale serve` **without** sudo, which requires the Tailscale operator bit. Fix it once over SSH, then re-deploy:

```bash
sudo tailscale set --operator=$(whoami)     # one-time; the install-tailscale recipe also does this
# map it immediately without waiting for a redeploy:
tailscale serve --bg --https=443 http://127.0.0.1:3100
tailscale serve status                       # confirm https://<server>.<tailnet>.ts.net -> 127.0.0.1:3100
```

Also confirm `tailscaled` is running and the node is up (`tailscale status`), and that MagicDNS + HTTPS Certificates are enabled in the admin console (otherwise serve can't get a cert).

**Deploy succeeds but data is gone after a redeploy.** **Zero-downtime deployments are enabled** — turn them off ([Step 2](#step-2--create-the-site-and-connect-your-fork)). They rename the Compose project each deploy and orphan your volumes. Your old volumes may still exist under the previous project name (`docker volume ls`); recover them before they're pruned.

**Agents fail with auth/credential errors.** The provider key isn't bound. Add it as a secret and bind it to the agent ([Step 6](#step-6--add-your-llm-provider-keys)). Note Gemini API keys must be *restricted to the Gemini API* in Google Cloud, or `gemini_local` runs are rejected.

## License

See [LICENSE.md](LICENSE.md). Paperclip itself is licensed separately — see the [upstream repository](https://github.com/paperclipai/paperclip).
