#!/usr/bin/env bash
# preflight.sh — verify this skill's dependencies and (with --fix) offer to install them.
#
# VENDORED IDENTICALLY across the skill family (create-pr, propose,
# address-pr, request-review, investigate) — same doctrine as journey.sh:
# no skill depends on another being installed, and a fix in one copy is a
# byte-copy to the others (verify with `md5 -q */scripts/preflight.sh`).
# Per-skill variation lives in DATA, not code: ../deps.json (next to SKILL.md)
# declares extras; this engine always checks the family base — git (in a work
# tree), gh (installed + authenticated), jq.
#
# deps.json (every key optional; missing file ⇒ base checks only):
#   {
#     "require":      [{"name","brew","apt","url","missing"}],       # extra required commands
#     "optional_any": [{"name","cmds":[…],"install","present","missing"}],  # any-of groups
#     "gh_scopes":    [{"scope","pattern","fix","missing"}],         # warning-level token scopes
#     "notes":        ["doc-only lines, e.g. MCP deps only the harness can check"]
#   }
#
# Output: a single JSON object on stdout —
#   { ok, deps, errors, warnings, remediation, notes, gh, git, report }
#     ok          — true when every REQUIRED dep is satisfied
#     deps         — [{name, kind, present, auto, install_cmd, detail}]
#     errors       — human-readable strings for missing REQUIRED deps (empty when ok)
#     warnings     — human-readable strings for missing OPTIONAL deps
#     remediation  — [{label, cmd, auto}] for each missing dep
#                    (auto=true ⇒ `--fix` runs it; auto=false ⇒ surface for the user)
#     notes        — doc-only lines from deps.json (MCP availability stays
#                    documentation: only the harness sees the tool list)
#     gh / git     — compatibility objects ({installed,authenticated} / {in_repo})
#     report       — verbatim-printable ✓/✗/⚠/ℹ block
#
# `preflight.sh --fix` runs every remediation entry with auto=true (package
# installs via the detected package manager), then re-evaluates and re-emits.
# Interactive steps (e.g. `gh auth login`) are never auto-run.
#
# Exit code: 0 when ok, 1 otherwise.

set -uo pipefail   # NOT -e: we collect every failure before reporting.

FIX=false
[ "${1:-}" = "--fix" ] && FIX=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/../deps.json"

have() { command -v "$1" >/dev/null 2>&1; }

# ---- package-manager detection (once) ---------------------------------------
PM=""
if have brew; then PM=brew
elif have apt-get || have apt; then PM=apt
fi
# pm_cmd <brew-pkg> <apt-pkg> <docs-url>
pm_cmd() {
  case "$PM" in
    brew) echo "brew install $1" ;;
    apt)  echo "sudo apt-get install -y $2" ;;
    *)    echo "see $3" ;;
  esac
}

# ---- jq guard: needed to emit JSON; report its own absence without jq -------
if ! have jq; then
  jq_fix=$(pm_cmd jq jq https://jqlang.github.io/jq/)
  auto=false; [ -n "$PM" ] && auto=true
  if [ "$FIX" = true ] && [ "$auto" = true ]; then eval "$jq_fix" >&2 || true; fi
  if ! have jq; then
    printf '{"ok":false,"deps":[{"name":"jq","kind":"required","present":false,"auto":%s,"install_cmd":"%s","detail":"jq is required to run preflight"}],"errors":["jq is not installed — %s"],"warnings":[],"remediation":[{"label":"install jq","cmd":"%s","auto":%s}],"report":"Preflight failed.\\n  jq: missing (required) — %s"}\n' \
      "$auto" "$jq_fix" "$jq_fix" "$jq_fix" "$auto" "$jq_fix"
    exit 1
  fi
fi

# ---- per-skill manifest (data, not code) -------------------------------------
manifest='{}'
if [ -f "$MANIFEST" ]; then
  manifest=$(jq -c . "$MANIFEST" 2>/dev/null || echo '{}')
fi
notes=$(echo "$manifest" | jq -c '.notes // []')

# ---- dependency collection --------------------------------------------------
# Each row: name \t kind \t present \t auto \t install_cmd \t detail
ROWS=()
# Strip ANSI escapes + C0 control chars (incl. tab) from the free-text one-line
# fields. Defends two things: (1) a control char from any tool's output can't
# break `jq -r .report` ("control characters must be escaped") downstream, and
# (2) a stray tab can't corrupt the tab-delimited row format.
_clean() { printf '%s' "${1:-}" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | LC_ALL=C tr -d '\000-\037\177'; }
add() { ROWS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$(_clean "$5")"$'\t'"$(_clean "$6")"); }

# Compatibility fields (kept for any caller reading the old shape).
gh_installed=false; gh_authed=false; git_in_repo=false

collect() {
  ROWS=()
  gh_installed=false; gh_authed=false; git_in_repo=false

  if have git; then add git required true true "" ""
  else add git required false true "$(pm_cmd git git https://git-scm.com)" "git is not installed"; fi

  if have git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_in_repo=true
    add repo required true false "" "inside a git work tree"
  else
    add repo required false false "cd <your-git-repo>" "not inside a git repository"
  fi

  if have gh; then
    gh_installed=true
    if gh auth status >/dev/null 2>&1; then
      gh_authed=true
      add gh required true false "" "authenticated"
    else
      add gh required false false "gh auth login" "gh is installed but not authenticated"
    fi
  else
    add gh required false true "$(pm_cmd gh gh https://cli.github.com)" "gh is not installed"
  fi

  add jq required true true "" "available"

  # Extra required commands declared by the manifest.
  while IFS=$'\t' read -r name brew_pkg apt_pkg url missing; do
    [ -n "$name" ] || continue
    if have "$name"; then add "$name" required true true "" "available"
    else add "$name" required false true "$(pm_cmd "$brew_pkg" "$apt_pkg" "$url")" "$missing"; fi
  done < <(echo "$manifest" | jq -r '(.require // [])[]
    | [.name, (.brew // .name), (.apt // .name), (.url // ""), (.missing // (.name + " is required"))] | @tsv')

  # Optional any-of groups (e.g. a markdown→storage converter for Confluence).
  while IFS=$'\t' read -r name cmds install present missing; do
    [ -n "$name" ] || continue
    found=false
    # shellcheck disable=SC2086  # word-splitting the space-joined cmd list is intended
    for c in $cmds; do have "$c" && { found=true; break; }; done
    if [ "$found" = true ]; then add "$name" optional true false "" "$present"
    else add "$name" optional false false "$install" "$missing"; fi
  done < <(echo "$manifest" | jq -r '(.optional_any // [])[]
    | [.name, ((.cmds // []) | join(" ")), (.install // ""), (.present // "present"), (.missing // (.name + " missing"))] | @tsv')

  # gh token scopes (warning-level; only meaningful once gh is authenticated).
  if [ "$gh_authed" = true ]; then
    while IFS=$'\t' read -r scope pattern fix missing; do
      [ -n "$scope" ] || continue
      if gh auth status 2>&1 | grep -qE "$pattern"; then
        add "gh-scope-$scope" optional true false "" "token has $scope scope"
      else
        add "gh-scope-$scope" optional false false "$fix" "$missing"
      fi
    done < <(echo "$manifest" | jq -r '(.gh_scopes // [])[]
      | [.scope, (.pattern // .scope), (.fix // ("gh auth refresh -s " + .scope)), (.missing // ("token lacks " + .scope + " scope"))] | @tsv')
  fi
}

collect

# ---- --fix: install missing auto-installable deps, then re-collect ----------
if [ "$FIX" = true ]; then
  for row in "${ROWS[@]}"; do
    # shellcheck disable=SC2034  # name/kind/detail are positional fields we intentionally skip
    IFS=$'\t' read -r name kind present auto cmd detail <<<"$row"
    if [ "$present" = false ] && [ "$auto" = true ] && [ -n "$cmd" ]; then
      echo "preflight --fix: $cmd" >&2
      eval "$cmd" >&2 || echo "preflight --fix: failed to run: $cmd" >&2
    fi
  done
  collect
fi

# ---- assemble JSON ----------------------------------------------------------
deps_json=$(printf '%s\n' "${ROWS[@]}" | jq -R -s '
  split("\n") | map(select(length > 0)) | map(split("\t")) |
  map({name:.[0], kind:.[1], present:(.[2]=="true"), auto:(.[3]=="true"),
       install_cmd:.[4], detail:.[5]})')

ok=$(echo "$deps_json"          | jq 'all(.[]; .kind != "required" or .present)')
errors=$(echo "$deps_json"      | jq '[.[] | select(.kind=="required" and (.present|not)) | .detail]')
warnings=$(echo "$deps_json"    | jq '[.[] | select(.kind=="optional" and (.present|not)) | .detail]')
remediation=$(echo "$deps_json" | jq '[.[] | select(.present|not)
                                          | {label:("install "+.name), cmd:.install_cmd, auto:.auto}]')

report=$(echo "$deps_json" | jq -r '
  (if all(.[]; .kind != "required" or .present) then "Preflight passed." else "Preflight failed." end),
  (.[] | "  \(.name): " +
     (if .present then "✓"
      elif .kind=="optional" then "⚠ optional"
      else "✗ missing" end) +
     (if .present then (if (.detail|length>0) then " (\(.detail))" else "" end)
      elif (.detail|length>0) then " — \(.detail)"
      else "" end))')

notes_report=$(echo "$notes" | jq -r '.[] | "  ℹ " + .')
if [ -n "$notes_report" ]; then
  report="$report
$notes_report"
fi

jq -nc \
  --argjson ok "$ok" \
  --argjson deps "$deps_json" \
  --argjson errors "$errors" \
  --argjson warnings "$warnings" \
  --argjson remediation "$remediation" \
  --argjson notes "$notes" \
  --argjson gh_installed "$gh_installed" \
  --argjson gh_authed "$gh_authed" \
  --argjson git_in_repo "$git_in_repo" \
  --arg report "$report" \
  '{ok:$ok, deps:$deps, errors:$errors, warnings:$warnings, remediation:$remediation,
    notes:$notes,
    gh:{installed:$gh_installed, authenticated:$gh_authed},
    git:{in_repo:$git_in_repo},
    report:$report}'

[ "$ok" = true ] && exit 0 || exit 1
