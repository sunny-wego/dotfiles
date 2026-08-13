#!/usr/bin/env bash
# Preflight for `make up` — verify the box is ready before starting the stack.
# `set -e` is intentionally OFF: this is a checklist that runs every check and
# summarises, rather than aborting on the first failure. Blockers set a non-zero
# exit at the end so `make up` won't proceed into a known-bad state.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
fail=0
warn=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; warn=$((warn + 1)); }

echo "Preflight — Internal App Platform"

# ── Docker ──────────────────────────────────────────────────────────────────
if docker info >/dev/null 2>&1; then ok "Docker daemon reachable"
else bad "Docker daemon not reachable — is Docker running?"; fi
if docker compose version >/dev/null 2>&1; then ok "docker compose plugin available"
else bad "docker compose plugin missing"; fi

# ── .env ────────────────────────────────────────────────────────────────────
if [ -f .env ]; then
  ok ".env present"
  set -a; . ./.env 2>/dev/null || true; set +a
else
  bad ".env missing — run: cp .env.example .env"
fi

# ── host ports Traefik needs ──────────────────────────────────────────────────
for p in 80 443; do
  inuse=""
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q . && inuse=1
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && inuse=1
  fi
  if [ -n "$inuse" ]; then note "port $p is in use — Traefik needs it; stop the other listener"
  else ok "port $p free"; fi
done

# ── disk headroom on the Docker root ──────────────────────────────────────────
root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
avail="$(df -Pm "$root" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "${avail:-}" ]; then
  if [ "$avail" -lt 5000 ]; then note "low disk: ${avail}MB free on $root (<5GB) — builds + images may fill it"
  else ok "disk headroom ok (${avail}MB free on $root)"; fi
else note "could not read disk usage for $root"; fi

# ── LLM path ──────────────────────────────────────────────────────────────────
mode="${KIOSK_LLM_MODE:-llm}"
if [ "$mode" = "llm" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
  note "KIOSK_LLM_MODE=llm but OPENROUTER_API_KEY is empty — app builds fail at Dockerfile generation. Set the key, or KIOSK_LLM_MODE=stub for a keyless run."
else ok "LLM mode = $mode"; fi

# ── auth / production secret key ──────────────────────────────────────────────
if [ "${AUTH_MODE:-dev}" = "google" ]; then
  case "${KIOSK_SECRET_KEY:-}" in
    "" | kiosk-insecure-dev-key-change-me)
      bad "AUTH_MODE=google but KIOSK_SECRET_KEY is the insecure default — the kiosk will refuse to start. Set: openssl rand -base64 32" ;;
    *) ok "production secret key set" ;;
  esac
  if [ -n "${OAUTH2_PROXY_CLIENT_ID:-}" ] && [ -n "${OAUTH2_PROXY_CLIENT_SECRET:-}" ]; then
    ok "Google OAuth credentials set"
  else
    note "AUTH_MODE=google but OAUTH2_PROXY_CLIENT_ID/SECRET are empty (see docs/AUTH.md)"
  fi
else
  ok "auth mode = ${AUTH_MODE:-dev} (dev stub — no Google needed)"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "Preflight: $fail blocker(s), $warn warning(s) — fix blockers before 'make up'."
  exit 1
fi
echo "Preflight: ready. ($warn warning(s))"
