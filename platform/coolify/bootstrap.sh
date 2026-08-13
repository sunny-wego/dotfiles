#!/usr/bin/env bash
# Self-host the control plane on Coolify (Option B). Sources platform/.env (and
# local/.env.local when present) and runs the bootstrap against the live Coolify.
#
#   ./coolify/bootstrap.sh            # create/refresh the control-plane service
#   ./coolify/bootstrap.sh --delete   # tear it down
#
# Requires Coolify installed + the tenant project/destination/token in .env.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # platform/
cd "$here"
set -a
[ -f .env ] && . ./.env
[ -f local/.env.local ] && { . ./local/.env.local; echo "  (loaded local/.env.local overrides)"; }
set +a
exec python3 coolify/bootstrap.py "$@"
