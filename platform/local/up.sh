#!/usr/bin/env bash
# One entry point for the local Colima parity harness (items 1–5 of the
# "match EC2 locally" plan). Brings up the shared stack behind a REAL
# oauth2-proxy + a mock OIDC issuer, so the only thing that differs from prod is
# the issuer URL + its client creds + the TLS/cert issuer.
#
#   ./local/up.sh                 # start Colima (if needed) + the local stack
#   ./local/up.sh --install-coolify   # also run Coolify's installer in the VM
#
# Coolify itself + its dashboard project/token are created ONCE by you in the
# dashboard (the steps are printed). Everything scriptable is scripted.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # platform/
cd "$here"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

install_coolify=0
[ "${1:-}" = "--install-coolify" ] && install_coolify=1

# ── 0. env files ─────────────────────────────────────────────────────────────
step "Environment"
if [ ! -f .env ]; then
  cp .env.example .env
  note "created platform/.env from the example — review it (LLM key, secrets)"
else ok "platform/.env present"; fi
if [ ! -f local/.env.local ]; then
  cp local/.env.local.example local/.env.local
  note "created local/.env.local from the example"
else ok "local/.env.local present"; fi

# A local-only cookie secret (non-sensitive) if the user left it blank.
if ! grep -qE '^OAUTH2_PROXY_COOKIE_SECRET=.+' local/.env.local; then
  sec="$(openssl rand -base64 32)"
  # replace the blank line (portable in-place edit)
  tmp="$(mktemp)"; grep -v '^OAUTH2_PROXY_COOKIE_SECRET=' local/.env.local > "$tmp"
  echo "OAUTH2_PROXY_COOKIE_SECRET=$sec" >> "$tmp"; mv "$tmp" local/.env.local
  ok "generated a local OAUTH2_PROXY_COOKIE_SECRET"
else ok "OAUTH2_PROXY_COOKIE_SECRET set"; fi

domain="$(grep -E '^PLATFORM_DOMAIN=' local/.env.local | tail -1 | cut -d= -f2- | tr -d '"')"
domain="${domain:-apps.127.0.0.1.nip.io}"

# ── 1. Colima ────────────────────────────────────────────────────────────────
step "Colima (Linux VM for Docker + Coolify)"
if ! command -v colima >/dev/null 2>&1; then
  bad "colima not found — install with:  brew install colima docker"
  exit 1
fi
if colima status >/dev/null 2>&1; then
  ok "Colima already running"
else
  note "starting Colima (4 CPU / 8 GiB / 60 GiB) — Coolify needs headroom"
  colima start --cpu 4 --memory 8 --disk 60 || { bad "colima start failed"; exit 1; }
  ok "Colima started"
fi

if [ "$install_coolify" = "1" ]; then
  step "Installing Coolify inside the VM (one-time, ~minutes)"
  note "requires the VM to reach cdn.coollabs.io"
  colima ssh -- 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh && sudo bash /tmp/coolify-install.sh' \
    && ok "Coolify installer finished" || bad "Coolify install failed — see output above"
fi

# ── 2 + 3. DNS + TLS reminders ───────────────────────────────────────────────
step "DNS + TLS"
ok "DNS: *.$domain resolves to 127.0.0.1 via nip.io (no /etc/hosts needed)"
if [ -f local/certs/wildcard.pem ]; then ok "TLS: local/certs/wildcard.pem present"
else note "TLS: run ./local/mkcert.sh to mint a trusted wildcard cert for *.$domain"; fi

# ── 4. Bring up the shared stack with the mock OIDC issuer ───────────────────
step "Shared stack (real oauth2-proxy + mock OIDC, profile=local)"
docker compose --env-file .env --env-file local/.env.local \
  -f docker-compose.yml -f local/docker-compose.local.yml \
  --profile local up -d --build \
  && ok "stack up (kiosk, oauth2-proxy, mock-oidc, litellm, registry, egress, postgres)" \
  || { bad "compose up failed"; exit 1; }

# ── Coolify dashboard steps (manual, once) ───────────────────────────────────
cip="$(colima ssh -- sh -c 'hostname -I 2>/dev/null | awk "{print \$1}"' 2>/dev/null)"
step "Finish in the Coolify dashboard (once), then fill local/.env.local"
cat <<EOF
  1. Open Coolify:            http://${cip:-<colima-ip>}:8000   (first run: create admin)
  2. Add a Server:            localhost (the Colima VM's own Docker)
  3. Create a Project +       environment 'production'
  4. Create a Destination on the shared network: $(grep -E '^COOLIFY_TENANT_NETWORK=' local/.env.local | cut -d= -f2-)
  5. Keys & Tokens → new API token (read/write)
  6. Copy the UUIDs + token + base URL into local/.env.local:
       COOLIFY_BASE_URL=http://${cip:-<colima-ip>}:8000
       COOLIFY_API_TOKEN, COOLIFY_PROJECT_UUID, COOLIFY_ENVIRONMENT_UUID,
       COOLIFY_SERVER_UUID, COOLIFY_DESTINATION_UUID
  7. Load the wildcard cert into Coolify's proxy:   ./local/mkcert.sh  (then follow its steps)

Then run the parity gate against this local Coolify:
       ./local/parity-local.sh
EOF
