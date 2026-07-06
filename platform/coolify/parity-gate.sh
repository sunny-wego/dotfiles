#!/usr/bin/env bash
# Turnkey Coolify parity gate — run on the box after Coolify is installed, the
# tenant project/environment/destination/token exist, and platform/.env is
# filled in (COOLIFY_* + PLATFORM_DOMAIN). One command:
#
#   ./coolify/parity-gate.sh
#
# Layer A (always): drives the shipped CoolifyClient against the live Coolify —
#   proves every endpoint/payload the kiosk uses actually works on this version.
# Layer B (auto when PARITY_APP_HOST is set): the #1 security check — an
#   unauthenticated hit to a tenant app must return 403 (auth chain is the only
#   route). Point it at any deployed tenant host, or run the probe with
#   PARITY_KEEP=1 and use parity-probe.$PLATFORM_DOMAIN.
#
# Not set -e: run every check and summarise, exit nonzero if any failed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # platform/
cd "$here"
set -a; [ -f .env ] && . ./.env; set +a

rc=0
echo "== Coolify parity gate =="
echo "  base: ${COOLIFY_BASE_URL:-<unset>}   domain: ${PLATFORM_DOMAIN:-<unset>}"

# ── Layer A: client ↔ live Coolify contract ─────────────────────────────────
python3 coolify/parity_probe.py || rc=1

# ── Layer B: auth chain is the only route (unauthenticated → 403) ────────────
if [ -n "${PARITY_APP_HOST:-}" ]; then
  echo
  echo "── Auth-chain check (unauthenticated → 403) ───────────────"
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
         "https://${PARITY_APP_HOST}/" 2>/dev/null || echo "000")
  if [ "$code" = "403" ]; then
    echo "  [PASS] ${PARITY_APP_HOST} → 403 without a session"
  else
    echo "  [FAIL] ${PARITY_APP_HOST} → ${code} (expected 403). Coolify is likely"
    echo "         also exposing its own unauthenticated router — enable the app's"
    echo "         'Readonly labels' toggle, or drop its Coolify domain so only the"
    echo "         custom-label auth-chain router serves it."
    rc=1
  fi
else
  echo
  echo "  (set PARITY_APP_HOST=<slug>.${PLATFORM_DOMAIN:-apps.internal} to auto-run"
  echo "   the auth-chain 403 check; skipped for now)"
fi

# ── Remaining done-when items (drive via the running Kiosk) ──────────────────
cat <<EOF

── End-to-end done-when checklist (run against the live stack) ──
  make samples                       # build the Node + Python sample zips
  Upload dist/node-hello.zip   → reaches a live URL behind Google login
  Upload dist/python-hello.zip → same
  A non-company Google account is denied (403)
  A per-tenant Coolify Postgres resource is created; DATABASE_URL is injected
    (its internal_db_url) + a scoped connection from the app works
  Each tenant DB shows a native scheduled backup in Coolify (Database → Backups)
  A tenant DB backup restores from the Coolify dashboard (restore drill)
  A Scheduled Task runs (Coolify → app container; run history in the dashboard)
  Egress to a NON-allowlisted host is blocked; an allowlisted one succeeds
  Base image is UTC (Coolify has no scheduled-task timezone field)
EOF

if [ "$rc" -eq 0 ]; then
  echo
  echo "== contract + auth-chain checks passed =="
fi
exit "$rc"
