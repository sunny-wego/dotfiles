#!/usr/bin/env bash
# Local TLS for the parity stack (item 3) — a real, browser-trusted wildcard cert
# via mkcert, so Coolify's Traefik serves https://*.<domain> exactly like prod.
# The ONLY difference from prod is the issuer (mkcert local CA vs Let's Encrypt).
#
#   ./local/mkcert.sh
#
# Produces local/certs/{wildcard.pem,wildcard-key.pem} + local/certs/coolify-tls.yml
# and prints how to load them into Coolify's proxy. Certs are gitignored.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # platform/local
cd "$here"

# Domain from local/.env.local if present, else the nip.io default.
domain="apps.127.0.0.1.nip.io"
[ -f .env.local ] && domain="$(grep -E '^PLATFORM_DOMAIN=' .env.local | tail -1 | cut -d= -f2- | tr -d '"')"
domain="${domain:-apps.127.0.0.1.nip.io}"

if ! command -v mkcert >/dev/null 2>&1; then
  echo "mkcert not found. Install it first:  brew install mkcert nss" >&2
  exit 1
fi

mkdir -p certs
echo "== Local TLS via mkcert =="
echo "  domain: *.$domain"

# Trust the mkcert CA in the system + browsers (idempotent).
mkcert -install

# One wildcard covers kiosk.<domain>, auth.<domain>, and every <slug>.<domain>.
mkcert -cert-file certs/wildcard.pem -key-file certs/wildcard-key.pem \
  "*.$domain" "$domain"

# Traefik dynamic config Coolify's proxy will load. The /traefik/... paths are
# where Coolify's traefik container sees its proxy dir (/data/coolify/proxy).
cat > certs/coolify-tls.yml <<'YML'
# Copy this file to /data/coolify/proxy/dynamic/local-tls.yml on the Coolify host
# (or paste via Coolify → Server → Proxy → Dynamic Configuration), and copy
# wildcard.pem + wildcard-key.pem to /data/coolify/proxy/certs/.
tls:
  certificates:
    - certFile: /traefik/certs/wildcard.pem
      keyFile: /traefik/certs/wildcard-key.pem
  stores:
    default:
      defaultCertificate:
        certFile: /traefik/certs/wildcard.pem
        keyFile: /traefik/certs/wildcard-key.pem
YML

cat <<EOF

Wrote:
  certs/wildcard.pem  certs/wildcard-key.pem  certs/coolify-tls.yml

Load into Coolify's proxy (on the Colima VM):
  colima ssh -- sudo mkdir -p /data/coolify/proxy/certs /data/coolify/proxy/dynamic
  # copy the two cert files to /data/coolify/proxy/certs/
  # copy certs/coolify-tls.yml to /data/coolify/proxy/dynamic/local-tls.yml
  # then restart Coolify's proxy (dashboard → Server → Proxy → Restart)

Then set each app/kiosk to use its own domain (https://<slug>.$domain) and
DISABLE Let's Encrypt for it — the wildcard above already covers it.
EOF
