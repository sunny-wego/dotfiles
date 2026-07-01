#!/usr/bin/env bash
# "Merged is not in production." Decide whether a commit/branch tip actually
# reached the base branch, using the GitHub compare API so it works in a fresh
# clone (orphaned commits aren't fetched locally, so `git show`/`cat-file` lie).
#
# Usage: verify-shipped.sh <sha-or-ref> [<base-branch>]
# Exit 0 = shipped (ancestor of base), 1 = NOT shipped (diverged/ahead), 2 = error.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require gh; require jq

sha="${1:?usage: verify-shipped.sh <sha-or-ref> [base]}"
base="${2:-$(repo_default_branch)}"
slug="$(repo_slug)"

# compare/BASE...SHA: status "behind"/"identical" => SHA is reachable from BASE
# (shipped). "diverged"/"ahead" => SHA has commits not on BASE (orphaned / not
# merged). ahead_by counts SHA-only commits.
read -r status ahead < <(gh api "repos/$slug/compare/$base...$sha" \
  --jq '"\(.status) \(.ahead_by)"' 2>/dev/null) \
  || die "compare failed — is '$sha' a commit the repo still knows? (gh api repos/$slug/commits/$sha)"

case "$status" in
  identical|behind)
    echo "SHIPPED: $sha is an ancestor of $base (compare status=$status)"
    exit 0 ;;
  ahead|diverged)
    echo "NOT SHIPPED: $sha is $status from $base (ahead_by=$ahead) — merged-but-orphaned or never merged."
    echo "  GitHub may still report its PR as 'merged'; do not trust the badge."
    exit 1 ;;
  *)
    die "unexpected compare status: $status" ;;
esac
