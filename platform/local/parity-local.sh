#!/usr/bin/env bash
# Item 5 — run the SAME Coolify parity gate against the local Colima Coolify.
# It deploys a throwaway probe app and leaves it up so Layer B (the unauthenticated
# → 403 auth-chain check) runs end-to-end against a real https tenant host.
#
#   ./local/parity-local.sh
#
# Reads platform/.env + local/.env.local (the gate loads both). Requires the
# Coolify install + COOLIFY_* filled in (see local/up.sh output).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # platform/
cd "$here"

domain="$(grep -E '^PLATFORM_DOMAIN=' local/.env.local 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')"
domain="${domain:-apps.127.0.0.1.nip.io}"

# Keep the probe app up and point Layer B at its host, so create→deploy AND the
# 403 auth-chain check both run against the local Coolify in one shot.
export PARITY_KEEP=1
export PARITY_APP_HOST="parity-probe.${domain}"

echo "== Local parity gate (Colima Coolify) =="
echo "  auth-chain 403 check → https://${PARITY_APP_HOST}"
exec ./coolify/parity-gate.sh
