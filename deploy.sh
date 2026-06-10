#!/usr/bin/env bash
#
# Deploy script for the Paperclip stack.
#
# Forge runs this from the site's deploy-script field. The recommended Forge
# deploy script is:
#
#     cd $FORGE_SITE_PATH
#     git pull origin $FORGE_SITE_BRANCH
#     bash deploy.sh
#
# git pull stays in the Forge field (not here) so changes to this script take
# effect on the same deploy rather than the next one. Past that bootstrap, the
# script is self-contained: a routine deploy never needs SSH.

set -euo pipefail

# ── Guardrail: Docker must be installed ──────────────────────────────────────
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed or not on PATH. See the README prerequisites." >&2
    exit 1
fi

# ── Deploy context (Forge injects these; the :- defaults keep the script
# runnable by hand outside Forge without tripping `set -u`). ──────────────────
echo "Deploying commit ${FORGE_DEPLOY_COMMIT:-unknown} -- ${FORGE_DEPLOY_MESSAGE:-}"
if [[ "${FORGE_MANUAL_DEPLOY:-0}" -eq 1 ]]; then
    echo "This deploy was triggered manually."
fi

# ── Bring up the stack ───────────────────────────────────────────────────────
# Pull the pinned image, then (re)create only changed containers in place.
# --remove-orphans cleans up renamed/removed services. Database migrations run
# automatically on startup via the Paperclip entrypoint.
echo "Pulling images and starting containers..."
docker compose pull
docker compose up -d --remove-orphans

# ── Publish over Tailscale ───────────────────────────────────────────────────
# Map the server's MagicDNS name (HTTPS :443) to Paperclip's loopback port.
# Idempotent: re-applying the same mapping is a no-op, so this is safe to run on
# every deploy. Requires the host to already be on your tailnet with MagicDNS +
# HTTPS enabled — see the Install Tailscale recipe:
#   https://github.com/jalendport/laravel-forge-recipes/tree/HEAD/recipes/install-tailscale
# We warn (not fail) if tailscale is missing so the Docker deploy still
# succeeds; Paperclip is then reachable on 127.0.0.1:3100 but not over the
# tailnet until Tailscale is set up.
if command -v tailscale &> /dev/null; then
    echo "Ensuring 'tailscale serve' maps :443 -> 127.0.0.1:3100..."
    # The install-tailscale recipe sets operator=forge, so the deploy user can
    # run `tailscale serve` WITHOUT sudo — Forge runs this script with no TTY,
    # so an interactive `sudo` password prompt can't be answered here. We try
    # the operator (no-sudo) path first, then fall back to non-interactive sudo
    # (`-n`, so it fails fast instead of hanging) for hosts where the operator
    # isn't set but the deploy user has passwordless sudo.
    SERVE_ARGS=(serve --bg --https=443 http://127.0.0.1:3100)
    if tailscale "${SERVE_ARGS[@]}" 2>/dev/null; then
        echo "  mapped (via Tailscale operator)."
    elif sudo -n tailscale "${SERVE_ARGS[@]}" 2>/dev/null; then
        echo "  mapped (via passwordless sudo)."
    else
        echo "WARNING: couldn't configure 'tailscale serve' automatically." >&2
        echo "         Make the deploy user the Tailscale operator — the install-tailscale" >&2
        echo "         recipe does this — or run this once over SSH, then re-deploy:" >&2
        echo "           sudo tailscale set --operator=\$(whoami)" >&2
        echo "         (If certs fail instead, enable MagicDNS + HTTPS in the admin console.)" >&2
    fi
else
    echo "WARNING: tailscale not found on PATH. Paperclip is up on 127.0.0.1:3100" >&2
    echo "         but not reachable over your tailnet yet. See README prerequisites." >&2
fi

docker compose ps
echo "Deployment complete."
