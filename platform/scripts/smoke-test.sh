#!/usr/bin/env bash
# M1 done-when checks, run against a platform started with `make up` (dev auth).
#
#   ✓ trivial Node ZIP  → live URL behind login
#   ✓ trivial Python ZIP → live URL behind login
#   ✓ a non-company identity is denied (403)
#   ✓ v1: a per-tenant DATABASE_URL is injected into the app
#   ✓ v1: a restore-from-backup drill passes
#   ✓ (optional, RUN_HEAL=1) the heal loop recovers ≥1 induced failure
#
# TLS is self-signed and hosts live under *.apps.localhost, so every curl pins
# the host to 127.0.0.1 and skips cert verification.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
set -a; [ -f .env ] && . ./.env; set +a
DOMAIN="${PLATFORM_DOMAIN:-apps.localhost}"
COMPOSE="docker compose"
pass=0; fail=0

c() {  # c <host> <path> [curl args...]  -> prints "HTTP_CODE\nBODY"
  local host="$1" path="$2"; shift 2
  curl -sk --resolve "${host}:443:127.0.0.1" -w '\n%{http_code}' \
       "$@" "https://${host}${path}"
}
ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }

echo "== M1 smoke test (domain=$DOMAIN) =="

# ── T1: kiosk reachable + authenticated (dev stub grants a company identity) ──
code=$(c "kiosk.$DOMAIN" /healthz | tail -1)
[ "$code" = "200" ] && ok "kiosk /healthz 200" || bad "kiosk /healthz => $code"

# ── T2 + T3: deploy Node and Python samples, assert each goes live ───────────
[ -f dist/node-hello.zip ] || ./scripts/make-samples.sh

deploy_and_wait() {  # <name> <zip>
  local name="$1" zip="$2" slug="$1"
  echo "-- deploying $name --"
  c "kiosk.$DOMAIN" /apps -F "name=${name}" -F "zipfile=@${zip}" >/dev/null
  for _ in $(seq 1 90); do
    local body status
    body=$(c "kiosk.$DOMAIN" "/apps/${slug}/status")
    status=$(echo "$body" | sed '$d' | grep -o '"status":[^,]*' | cut -d'"' -f4)
    case "$status" in
      running) return 0 ;;
      failed)  echo "$body" | sed '$d'; return 1 ;;
    esac
    sleep 3
  done
  return 2
}

for pair in "node-hello:dist/node-hello.zip" "python-hello:dist/python-hello.zip"; do
  name="${pair%%:*}"; zip="${pair##*:}"
  if deploy_and_wait "$name" "$zip"; then
    ok "$name provisioned (status=running)"
    code=$(c "${name}.$DOMAIN" / | tail -1)
    # 2xx = app served through auth; 401/302 = behind login but reachable.
    case "$code" in
      2*) ok "$name serves behind login (HTTP $code)" ;;
      *)  bad "$name URL returned $code" ;;
    esac
  else
    bad "$name did not reach running"
  fi
done

# ── T4: non-company identity is denied ───────────────────────────────────────
echo "-- non-company denial --"
DEV_USER_EMAIL="intruder@gmail.com" $COMPOSE --profile dev up -d authstub >/dev/null 2>&1
sleep 3
code=$(c "kiosk.$DOMAIN" / | tail -1)
[ "$code" = "403" ] && ok "non-company account denied (403)" \
                     || bad "expected 403 for non-company, got $code"
# restore the company dev identity
DEV_USER_EMAIL="${DEV_USER_EMAIL:-dev@${COMPANY_EMAIL_DOMAIN:-wego.com}}" \
  $COMPOSE --profile dev up -d authstub >/dev/null 2>&1

# ── T5: v1 — per-tenant DB injected into a deployed app ──────────────────────
echo "-- per-tenant DATABASE_URL --"
if docker exec app-node-hello sh -c 'echo "$DATABASE_URL"' 2>/dev/null | grep -q '^postgresql://'; then
  ok "per-tenant DATABASE_URL injected"
else
  bad "no DATABASE_URL in the deployed app container"
fi

# ── T6: v1 — restore-from-backup drill passes ────────────────────────────────
echo "-- backup + restore drill --"
c "kiosk.$DOMAIN" /ops/backup -X POST >/dev/null
drill=$(c "kiosk.$DOMAIN" /ops/restore-drill | sed '$d')
echo "$drill" | grep -q '"ok": *true' \
  && ok "restore-from-backup drill passed" \
  || { echo "$drill"; bad "restore drill did not pass"; }

# ── T7 (optional): heal loop recovers an induced failure ─────────────────────
if [ "${RUN_HEAL:-0}" = "1" ]; then
  echo "-- heal loop (induced failure) --"
  KIOSK_INDUCE_BUILD_FAILURE=1 $COMPOSE up -d kiosk >/dev/null 2>&1
  sleep 4
  if deploy_and_wait "heal-demo" "dist/node-hello.zip"; then
    body=$(c "kiosk.$DOMAIN" /apps/heal-demo/status | sed '$d')
    echo "$body" | grep -q "attempt 2" \
      && ok "heal loop recovered on a later attempt" \
      || bad "no evidence of a second attempt in the log"
  else
    bad "heal-demo did not reach running"
  fi
  $COMPOSE up -d kiosk >/dev/null 2>&1   # restore (induce off)
fi

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
