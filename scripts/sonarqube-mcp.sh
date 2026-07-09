#!/bin/bash
# Launch (or refresh) the SonarQube MCP server as a long-lived HTTP service on
# http://localhost:8765/mcp, shared across all local AI clients.
#
# The client config lives in mcp/manifest.yaml (transport: http). This script
# owns the *server* lifecycle. `--restart unless-stopped` keeps the container
# alive across reboots once Docker Desktop starts on login, so this normally
# only needs to run once (install.sh calls it during setup).
#
# Requires SONARQUBE_TOKEN and SONARQUBE_URL in the environment (see
# ~/.zshrc_local). The server uses SONARQUBE_TOKEN to authenticate to
# SONARQUBE_URL; clients present the same token as a bearer header.
set -euo pipefail

CONTAINER_NAME="sonarqube-mcp"
PORT="${SONARQUBE_HTTP_PORT:-8765}"
IMAGE="mcp/sonarqube"

if ! command -v docker >/dev/null 2>&1; then
  echo "❌  Docker not found. Install Docker Desktop first." >&2
  exit 1
fi

if [ -z "${SONARQUBE_TOKEN:-}" ] || [ -z "${SONARQUBE_URL:-}" ]; then
  echo "❌  SONARQUBE_TOKEN and SONARQUBE_URL must be set (add them to ~/.zshrc_local)." >&2
  exit 1
fi

echo "🔍  (Re)starting SonarQube MCP server on http://localhost:${PORT}/mcp ..."
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER_NAME" --restart unless-stopped --init \
  --pull=always \
  -p "127.0.0.1:${PORT}:${PORT}" \
  -e SONARQUBE_TRANSPORT=http \
  -e SONARQUBE_HTTP_HOST=0.0.0.0 \
  -e "SONARQUBE_HTTP_PORT=${PORT}" \
  -e "SONARQUBE_URL=${SONARQUBE_URL}" \
  -e "SONARQUBE_TOKEN=${SONARQUBE_TOKEN}" \
  -e STORAGE_PATH=/tmp/sonar-storage \
  "$IMAGE" >/dev/null

# Wait for the unauthenticated /health endpoint to come up.
for _ in $(seq 1 20); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/health" 2>/dev/null)" = "200" ]; then
    echo "✅  SonarQube MCP server is up ($(curl -s "http://localhost:${PORT}/info"))."
    exit 0
  fi
  sleep 2
done

echo "⚠️  Server did not report healthy in time. Check: docker logs ${CONTAINER_NAME}" >&2
exit 1
