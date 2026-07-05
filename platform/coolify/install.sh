#!/usr/bin/env bash
# Host-as-code: install Coolify on the box, pinned to a known-good version.
#
# The README (§ "Minimal start") describes the Coolify path as "its installer +
# host-as-code". This is that step, kept in the repo so a box is reproducible
# and a version bump is a reviewed diff — not an ad-hoc `curl | bash` (Coolify
# moves fast; README §"Disk & capacity" calls for a pinning policy).
#
# After this runs, finish bring-up from the dashboard per ./README.md.
set -euo pipefail

# Pin the Coolify release. Bump deliberately (review the changelog first); do not
# float to latest — an unattended engine upgrade can break tenant apps.
COOLIFY_VERSION="${COOLIFY_VERSION:-4.0.0-beta.420}"

if [[ $EUID -ne 0 ]]; then
  echo "run as root (Coolify installs system services): sudo $0" >&2
  exit 1
fi

echo "Installing Coolify ${COOLIFY_VERSION} …"
# Coolify's official installer honors VERSION to pin the release.
curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
VERSION="${COOLIFY_VERSION}" bash /tmp/coolify-install.sh
rm -f /tmp/coolify-install.sh

cat <<'EOF'

Coolify installed. Next (see ./README.md "Bring-up"):
  1. Open the dashboard, create the tenant Project + Environment + Destination.
  2. Create a least-privilege API token.
  3. Install ./traefik-dynamic.yml into the proxy dynamic config.
  4. Set KIOSK_DEPLOY_BACKEND=coolify + the COOLIFY_* vars for the Kiosk.
  5. Run the parity gate: `make smoke` against the Coolify backend.
EOF
