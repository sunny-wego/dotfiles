#!/usr/bin/env bash
# Classify failed PR checks into handler buckets.
# Reads pr-status.sh JSON on stdin.
#
# Classification rules:
#   - mergeable == "CONFLICTING" or behind_base == true → "merge-conflicts"
#   - Failed check name matches /sonarqube|sonarcloud/i → "sonarqube"
#   - Failed check name matches /vercel|preview/i → "vercel"
#   - Any other failed check → "ci-check"
#
# Comment-based handlers (coderabbit, team-reviews) always run — no need to
# plumb them through classification. SKILL.md documents this directly.
#
# Handler array is in priority order: merge-conflicts, sonarqube, ci-check, vercel.
#
# Outputs JSON: { "handlers": ["merge-conflicts", "sonarqube", "ci-check"] }
#
# Usage: bash pr-status.sh <PR> | bash classify-checks.sh

set -euo pipefail

jq '
  (.failed // []) as $failed |
  ($failed | map(
    if test("sonarqube|sonarcloud"; "i") then "sonarqube"
    elif test("vercel|preview"; "i") then "vercel"
    else "ci-check"
    end
  ) | unique) as $check_handlers |

  (if .mergeable == "CONFLICTING" or .behind_base == true then ["merge-conflicts"] else [] end) as $conflict |

  ["merge-conflicts", "sonarqube", "ci-check", "vercel"] as $priority |
  ($conflict + $check_handlers) as $all |
  [$priority[] | select(. as $h | $all | index($h))] as $ordered |

  {handlers: $ordered}
'
