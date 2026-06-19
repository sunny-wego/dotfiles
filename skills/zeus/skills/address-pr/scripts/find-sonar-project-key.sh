#!/usr/bin/env bash
# find-sonar-project-key.sh — resolve a project's SonarQube projectKey from
# the local config, matching the lookup order in the SonarQube MCP guidance.
#
# Lookup order:
#   1. .sonarlint/connectedMode.json — `.projectKey`
#   2. sonar-project.properties      — `sonar.projectKey=<value>`
#   3. pom.xml                       — `<sonar.projectKey>VALUE</sonar.projectKey>`
#   4. package.json (root)           — `.sonar.projectKey`
#
# Each location is checked from the worktree root upward only as far as
# `git rev-parse --show-toplevel`. CI/CD config files are intentionally NOT
# searched here — those are too platform-specific for a deterministic shell
# script. If none match, exit 2.
#
# Usage:  find-sonar-project-key.sh
# Output (on success): bare projectKey on stdout
# Exit:   0 on success; 2 when no key is configured (handler treats as
#         "SonarQube isn't wired up here; no-op").

set -euo pipefail

if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "find-sonar-project-key: not inside a git worktree" >&2
  exit 1
fi

# 1. .sonarlint/connectedMode.json
if [ -f "$root/.sonarlint/connectedMode.json" ]; then
  key=$(jq -r '.projectKey // empty' "$root/.sonarlint/connectedMode.json" 2>/dev/null || true)
  [ -n "$key" ] && { echo "$key"; exit 0; }
fi

# 2. sonar-project.properties
if [ -f "$root/sonar-project.properties" ]; then
  key=$(grep -E '^[[:space:]]*sonar\.projectKey[[:space:]]*=' "$root/sonar-project.properties" \
    | head -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//' || true)
  [ -n "$key" ] && { echo "$key"; exit 0; }
fi

# 3. pom.xml
if [ -f "$root/pom.xml" ]; then
  key=$(grep -oE '<sonar\.projectKey>[^<]+</sonar\.projectKey>' "$root/pom.xml" \
    | head -1 | sed -E 's#<[^>]+>##g' || true)
  [ -n "$key" ] && { echo "$key"; exit 0; }
fi

# 4. package.json (root). Match `"sonar": { "projectKey": "..." }`.
if [ -f "$root/package.json" ]; then
  key=$(jq -r '.sonar.projectKey // empty' "$root/package.json" 2>/dev/null || true)
  [ -n "$key" ] && { echo "$key"; exit 0; }
fi

exit 2
