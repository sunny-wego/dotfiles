#!/usr/bin/env bash
# The macOS/Colima one-liner (Option C topology). Run it, do ONE 30-second
# browser step (Coolify first-run: create admin + an API token), run it again.
#
#   make local                 # == ./local/local.sh
#   make local -- --install-coolify   # also install Coolify in the VM (first time)
#
# It is IDEMPOTENT and self-directing:
#   pass 1 (no token yet)  → Colima + Coolify + certs + identity edge (oauth2-proxy
#                            + mock OIDC) up; prints the one manual step; stops.
#   pass 2 (token pasted)  → auto-provisions the project/env/server UUIDs, builds
#                            the kiosk, self-hosts the control plane on Coolify.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # platform/
cd "$here"
bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# 1–4: Colima + Coolify + env files + certs + the identity edge only (the app
# self-hosts on Coolify, so we do NOT run kiosk/litellm/etc. in compose here).
LOCAL_UP_SERVICES="oauth2-proxy mock-oidc" ./local/up.sh "$@" || exit 1
[ -f local/certs/wildcard.pem ] || ./local/mkcert.sh || true

# Load merged env to check whether the one manual step is done.
set -a; [ -f .env ] && . ./.env; [ -f local/.env.local ] && . ./local/.env.local; set +a

if [ -z "${COOLIFY_API_TOKEN:-}" ] || [ -z "${COOLIFY_BASE_URL:-}" ]; then
  bold "ONE manual step, then re-run 'make local'"
  cip="$(colima ssh -- sh -c 'hostname -I 2>/dev/null | awk "{print \$1}"' 2>/dev/null)"
  cat <<EOF
  1. Open Coolify:  http://${cip:-<colima-ip>}:8000   (first run: create the admin user)
  2. Keys & Tokens → create an API token (read/write)
  3. Put both into local/.env.local:
       COOLIFY_BASE_URL=http://${cip:-<colima-ip>}:8000
       COOLIFY_API_TOKEN=<the token>
  4. Re-run:  make local
EOF
  exit 0
fi

# Token present → auto-provision UUIDs, build, and self-host the control plane.
bold "Auto-provisioning Coolify project / environment / server"
PYTHONPATH=kiosk python3 coolify/provision.py || exit 1

bold "Building the kiosk image"
docker compose --env-file .env --env-file local/.env.local build kiosk || exit 1

bold "Self-hosting the control plane on Coolify (make bootstrap)"
./coolify/bootstrap.sh || exit 1

domain="$(grep -E '^PLATFORM_DOMAIN=' local/.env.local | tail -1 | cut -d= -f2- | tr -d '"')"
bold "Done"
cat <<EOF
  Kiosk (once Coolify finishes deploying): https://kiosk.${domain:-apps.127.0.0.1.nip.io}
  Verify the deploy engine end-to-end:     make parity-local
  Reminders: connect the service to COOLIFY_TENANT_NETWORK, load certs
             (./local/mkcert.sh --load), and don't let Coolify auto-publish the
             kiosk domain (coolify/platform-stack.yml header).
EOF
