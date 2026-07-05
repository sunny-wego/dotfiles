#!/usr/bin/env bash
# Zip the sample apps into ./dist for drag-and-drop into the Kiosk.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$here/dist"
mkdir -p "$dist"

# Every directory under samples/ is a candidate tenant app. Deny-by-default
# excludes keep build junk AND any stray secrets/dotfiles out of the uploaded
# ZIP (a sample dir must never ship a real .env, .git, cloud creds, etc.).
EXCLUDES=(
  'node_modules/*' '*/node_modules/*'
  '__pycache__/*' '*/__pycache__/*' '*.pyc'
  '.git/*' '*/.git/*'
  '.*' '*/.*'                 # top-level and nested dotfiles/dirs
  '.env' '.env.*' '*/.env' '*/.env.*'
  '*/.aws/*' '*/.npmrc' '*/.netrc' '*/.DS_Store' '*/id_rsa*'
)
for src in "$here"/samples/*/; do
  app="$(basename "$src")"
  out="$dist/$app.zip"
  rm -f "$out"
  ( cd "$src" && zip -qr "$out" . -x "${EXCLUDES[@]}" )
  echo "wrote $out"
done

echo "done — upload these ZIPs at https://kiosk.<domain>/"
