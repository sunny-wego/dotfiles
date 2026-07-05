#!/usr/bin/env bash
# Zip the sample apps into ./dist for drag-and-drop into the Kiosk.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$here/dist"
mkdir -p "$dist"

# Every directory under samples/ is a candidate tenant app.
for src in "$here"/samples/*/; do
  app="$(basename "$src")"
  out="$dist/$app.zip"
  rm -f "$out"
  ( cd "$src" && zip -qr "$out" . -x '*/node_modules/*' '*/__pycache__/*' )
  echo "wrote $out"
done

echo "done — upload these ZIPs at https://kiosk.<domain>/"
