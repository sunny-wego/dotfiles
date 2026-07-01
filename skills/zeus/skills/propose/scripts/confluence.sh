#!/usr/bin/env bash
# confluence.sh — the Confluence analogue of post-issue.sh. Wrap the Confluence
# Cloud REST API (curl) with `create` / `update` / `comment`, so the network I/O
# that /zeus:propose currently does through the Atlassian MCP lives inside ONE
# deterministic script chokepoint — exactly how post-issue.sh wraps `gh` for the
# GitHub destination. Building this is what lifts the Confluence path to parity
# with `gh issue`: a script (not the agent) makes the call, so ownership is
# HARD-enforced (we GET the page author and refuse a non-owned PUT) and drift is
# checked against the live version the script fetches itself.
#
# Verb/flag surface mirrors post-issue.sh 1:1:
#   Create:
#     confluence.sh --title "feat(x): …" --body-file body.(md|storage) --repo owner/name \
#       [--status current|draft] [--state f]
#   Update (amend in place — re-rendered body, drift+ownership gated):
#     confluence.sh --update <pageId> --title "…" --body-file body --repo owner/name \
#       [--expected-version N] [--state f] [--force-amend]
#   Comment (footer comment — used when the page isn't yours to amend):
#     confluence.sh --comment <pageId> --body-file body --repo owner/name
#
# Destination (cloudId/site, spaceKey, spaceId, parentId, defaultStatus) is resolved
# from --repo via confluence-target.sh — the same per-repo config the MCP path reads.
# No --repo, or an unconfigured repo, is a hard error (parity: you must say where).
#
# AUTH (env, never committed — the curl analogue of `gh auth`):
#   CONFLUENCE_EMAIL      Atlassian account email
#   CONFLUENCE_API_TOKEN  API token (id.atlassian.com → Security → API tokens)
#   API calls go through the Atlassian gateway (api.atlassian.com/ex/confluence/
#   <cloudId-UUID>/wiki/…), with the UUID resolved from the site's public tenant_info
#   endpoint — a scoped API token is REJECTED (401) on the direct site URL. Human page
#   links still use the site URL. Override the API base with CONFLUENCE_BASE_URL.
#   Ownership uses an accountId cached from a create/update (the v1 user/current
#   endpoint is unusable by a granular-scoped token); create bootstraps the cache.
#
# BODY FORMAT — the one real asymmetry vs gh (which ingests markdown natively):
# Confluence REST takes `storage` (XHTML), not markdown. Conversion is a pluggable
# seam (md_to_storage below): set CONFLUENCE_CONVERTER to a command that reads
# markdown on stdin and writes storage XHTML on stdout (e.g. a `mark --compile-only`
# wrapper or pandoc+filter). A *.storage / *.xml body-file is passed through
# untouched (detected by extension). The watermark is already baked into the
# markdown upstream by `render.sh --format confluence`, so it survives conversion —
# this script does NOT re-stamp it (you can't append markdown to XHTML).
#
# Prints the page URL on stdout. Exit 0 ok / 1 runtime / 2 usage — house contract.
set -euo pipefail

title=""; body_file=""; repo=""; update_id=""; comment_id=""; state_file=""
force_amend=""; status=""; expected_version=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)            title="$2";            shift 2 ;;
    --body-file)        body_file="$2";         shift 2 ;;
    --repo)             repo="$2";              shift 2 ;;
    --update)           update_id="$2";         shift 2 ;;
    --comment)          comment_id="$2";        shift 2 ;;
    --state)            state_file="$2";        shift 2 ;;
    --status)           status="$2";            shift 2 ;;
    --expected-version) expected_version="$2";  shift 2 ;;
    --force-amend)      force_amend="true";     shift ;;
    *) echo "confluence.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$body_file" ] || { [ -z "$title" ] && [ -z "$update_id" ] && [ -z "$comment_id" ]; }; then
  echo "usage: confluence.sh [--update <id> | --comment <id>] --title <t> --body-file <path> --repo <owner/name> [--state f]" >&2
  exit 2
fi
[ -f "$body_file" ] || { echo "confluence.sh: body file not found: $body_file" >&2; exit 1; }
[ -n "$repo" ] || { echo "confluence.sh: --repo <owner/name> is required (it resolves the Confluence destination)" >&2; exit 2; }
[ -n "${CONFLUENCE_EMAIL:-}" ] && [ -n "${CONFLUENCE_API_TOKEN:-}" ] || {
  echo "confluence.sh: set CONFLUENCE_EMAIL and CONFLUENCE_API_TOKEN (the curl analogue of gh auth)" >&2; exit 1; }

script_dir="$(cd "$(dirname "$0")" && pwd)"

# ── Resolve the destination from --repo (same config the MCP path reads) ──────
dest=$(bash "$script_dir/confluence-target.sh" "$repo" 2>/dev/null || echo '{"configured":false}')
[ "$(printf '%s' "$dest" | jq -r '.configured')" = "true" ] || {
  echo "confluence.sh: $repo is not configured for Confluence (confluence-target.sh enable …)" >&2; exit 1; }
cloud_id=$(printf '%s' "$dest"  | jq -r '.cloudId // empty')
space_key=$(printf '%s' "$dest" | jq -r '.spaceKey // empty')
space_id=$(printf '%s' "$dest"  | jq -r '.spaceId // empty')
parent_id=$(printf '%s' "$dest" | jq -r '.parentId // empty')
[ -n "$status" ] || status=$(printf '%s' "$dest" | jq -r '.defaultStatus // "current"')

# Two URLs: the API base (where curl talks) and the site base (human page links).
# Scoped API tokens — the current ATATT format — are REJECTED on the direct site URL
# (HTTP 401); they must go through the Atlassian gateway, keyed by the tenant's
# cloudId UUID. We resolve that UUID from the public, unauthenticated tenant_info
# endpoint and target the gateway. (Classic unscoped tokens also work via the gateway.
# Override the API base with CONFLUENCE_BASE_URL if needed.)
case "$cloud_id" in
  *.atlassian.net) site_base="https://$cloud_id/wiki" ;;
  *) echo "confluence.sh: cloudId '$cloud_id' is not a site host; set CONFLUENCE_BASE_URL" >&2; exit 1 ;;
esac
base="${CONFLUENCE_BASE_URL:-}"
if [ -z "$base" ]; then
  cid=$(curl -sS "https://$cloud_id/_edge/tenant_info" 2>/dev/null | jq -r '.cloudId // empty')
  if [ -n "$cid" ]; then base="https://api.atlassian.com/ex/confluence/$cid/wiki"
  else base="$site_base"; fi   # tenant_info unreachable → fall back to the site URL
fi

# Thin curl helper: authenticated JSON call, body on stdin. Echoes the response
# body; non-2xx is a hard failure with the status + payload on stderr (house: a
# failed network call is {"error":…} on stderr, exit 1).
api() { # api <METHOD> <path> [<stdin-json>]
  local method="$1" path="$2" out code
  out=$(curl -sS -w '\n%{http_code}' -u "$CONFLUENCE_EMAIL:$CONFLUENCE_API_TOKEN" \
        -X "$method" -H 'Content-Type: application/json' \
        ${3:+--data-binary @-} "$base$path" <<<"${3:-}") || { echo '{"error":"curl failed"}' >&2; return 1; }
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  case "$code" in 2*) printf '%s' "$out" ;; *) echo "confluence.sh: $method $path → HTTP $code: $out" >&2; return 1 ;; esac
}

# Markdown → storage XHTML conversion seam (the one thing gh gives free). A body
# already in storage (by *.storage/*.xml/*.xhtml extension) passes through.
# Converter resolution: explicit CONFLUENCE_CONVERTER wins; else the bundled
# md2storage.sh adapter when `mark` is on PATH (the zero-config default — install
# mark and it just works); else a loud error rather than a wrong-format post.
md_to_storage() { # reads $1 (file) → storage XHTML on stdout
  if case "$1" in *.storage|*.xml|*.xhtml) true;; *) false;; esac; then
    cat "$1"; return 0
  fi
  if [ -n "${CONFLUENCE_CONVERTER:-}" ]; then
    "$CONFLUENCE_CONVERTER" < "$1"; return $?
  fi
  if [ -f "$script_dir/md2storage.sh" ] && command -v mark >/dev/null 2>&1; then
    bash "$script_dir/md2storage.sh" < "$1"; return $?
  fi
  echo "confluence.sh: body is markdown but no converter is available. Either install" >&2
  echo "  mark (brew install mark) so the bundled md2storage.sh adapter is used, or set" >&2
  echo "  CONFLUENCE_CONVERTER to a 'markdown-on-stdin → storage-on-stdout' command, or" >&2
  echo "  pass storage XHTML directly (a *.storage / *.xml / *.xhtml file)." >&2
  return 1
}

# JSON string of the converted body, for embedding in a request payload.
body_value_json() { md_to_storage "$body_file" | jq -Rs .; }

page_url() { printf '%s/spaces/%s/pages/%s\n' "$site_base" "$space_key" "$1"; }

# My Confluence accountId, cached from a prior create/update response's authorId
# (which is me, since I just wrote it). This sidesteps the v1 user/current endpoint,
# which a granular-scoped token can't use. Cache is email-keyed via confluence-target.sh
# so a credential change invalidates a stale id.
my_account_id() {
  local rec id em
  rec="$(bash "$script_dir/confluence-target.sh" account-get 2>/dev/null || echo '{}')"
  id="$(printf '%s' "$rec" | jq -r '.account_id // empty')"
  em="$(printf '%s' "$rec" | jq -r '.account_email // empty')"
  [ -n "$id" ] && [ "$em" = "${CONFLUENCE_EMAIL:-}" ] && printf '%s' "$id"
}
cache_account_id() {  # $1 = authorId from a response I just authored
  local id="$1"
  [ -n "$id" ] || return 0
  [ -n "$(my_account_id)" ] && return 0   # already cached for this email
  bash "$script_dir/confluence-target.sh" account-set "$id" "${CONFLUENCE_EMAIL:-}" >/dev/null 2>&1 || true
}

# ── Reader-test gate — the shared review-gate.sh (publish-contract.md clause 3),
# the SAME gate post-issue.sh calls (destination-neutral; reads only the state).
# Skipped in --comment mode. ─────────────────────────────────────────────────────
if [ -z "$comment_id" ] && [ -n "$state_file" ]; then
  bash "$script_dir/review-gate.sh" "$state_file" || exit 1
fi

# ── Comment mode: footer comment (the not-mine path) ─────────────────────────
if [ -n "$comment_id" ]; then
  payload=$(jq -nc --arg pid "$comment_id" --argjson v "$(body_value_json)" \
    '{pageId:$pid, body:{representation:"storage", value:$v}}')
  resp=$(api POST "/api/v2/footer-comments" "$payload") || exit 1
  echo "$(page_url "$comment_id")#comment-$(printf '%s' "$resp" | jq -r '.id')"
  echo "commented on page $comment_id (body untouched)" >&2
  exit 0
fi

if [ -n "$update_id" ]; then
  # ── GET live state (version + author) — the script fetches it now, not the
  #    agent. This is what makes ownership HARD and drift self-contained. ──────
  live=$(api GET "/api/v2/pages/$update_id") || exit 1
  live_version=$(printf '%s' "$live" | jq -r '.version.number')
  page_author=$(printf '%s' "$live" | jq -r '.authorId // .ownerId // empty')
  # My accountId, v2-native: the v1 user/current endpoint 401s ("scope does not
  # match") for a granular-scoped token, so we use the accountId cached from a prior
  # create/update (cache_account_id). Uncached ⇒ ownership is undetermined ⇒ the
  # fail-safe below refuses.
  me="$(my_account_id)"

  # ── Ownership gate — reuses ownership.sh compare-mode, exactly like post-issue
  #    reuses it for GitHub. Fail-safe: undetermined ⇒ refuse unless --force-amend.
  own=$(bash "$script_dir/ownership.sh" --author "$page_author" --viewer "$me" 2>/dev/null || echo '{"mine":false,"determined":false}')
  if [ "$(printf '%s' "$own" | jq -r '.mine // false')" != "true" ] && [ "$force_amend" != "true" ]; then
    if [ "$(printf '%s' "$own" | jq -r '.determined // false')" = "true" ]; then
      echo "confluence: page $update_id was authored by $page_author, not you ($me) — refusing to overwrite it." >&2
    else
      echo "confluence: can't confirm ownership of page $update_id — your accountId isn't cached yet (fail-safe)." >&2
      echo "  It's cached automatically the first time you create a page; or set it once:" >&2
      echo "    confluence-target.sh account-set <your-accountId> \"\$CONFLUENCE_EMAIL\"" >&2
    fi
    echo "  Comment instead:  confluence.sh --comment $update_id --body-file <path> --repo $repo" >&2
    echo "  Or, if you truly own this edit, re-run with --force-amend." >&2
    exit 1
  fi

  # ── Drift gate — version-based (Confluence reformats markdown on round-trip, so
  #    a text diff false-positives; the version number is the reliable signal).
  #    The expected version comes from --expected-version or the persisted state.
  stored="$expected_version"
  [ -z "$stored" ] && [ -n "$state_file" ] && [ -f "$state_file" ] && \
    stored=$(jq -r '.confluence_version // empty' "$state_file" 2>/dev/null || echo "")
  if [ -n "$stored" ]; then
    # Capture the gate's stderr in a variable (no temp file — the script dir may be
    # read-only when installed). 2>&1 >/dev/null keeps only stderr.
    if ! drift_err=$(bash "$script_dir/confluence-drift.sh" --stored "$stored" --current "$live_version" 2>&1 >/dev/null); then
      [ "$force_amend" = "true" ] || { printf '%s\n' "$drift_err" >&2; exit 1; }
    fi
  fi

  # ── PUT — version number. A published (current) page requires the NEXT number
  #    (live+1, Confluence's optimistic-concurrency check). A DRAFT page does NOT
  #    version — it stays at its current number, and Confluence rejects live+1 with
  #    "DRAFT pages do not support multiple versions" — so send the current number.
  if [ "$status" = "draft" ]; then next="$live_version"; else next=$((live_version + 1)); fi
  msg=""; [ -n "$state_file" ] && [ -f "$state_file" ] && \
    msg=$(jq -r '(.amendment_log // []) | last // ""' "$state_file" 2>/dev/null || echo "")
  payload=$(jq -nc --arg id "$update_id" --arg st "$status" --arg t "$title" \
    --argjson v "$(body_value_json)" --argjson n "$next" --arg m "$msg" \
    '{id:$id, status:$st, title:$t, body:{representation:"storage", value:$v},
      version:({number:$n} + (if $m=="" then {} else {message:$m} end))}')
  resp=$(api PUT "/api/v2/pages/$update_id" "$payload") || exit 1
  page_id="$update_id"; new_version=$(printf '%s' "$resp" | jq -r '.version.number')
  echo "$(page_url "$page_id")"
  echo "updated page $page_id → version $new_version: $title" >&2
else
  # ── Create mode ──────────────────────────────────────────────────────────────
  # Resolve spaceKey → numeric spaceId if config only had the key (mirrors the
  # MCP getConfluenceSpaces step); persist it back best-effort for next time.
  if [ -z "$space_id" ]; then
    space_id=$(api GET "/api/v2/spaces?keys=$space_key" | jq -r '.results[0].id // empty') || true
    [ -n "$space_id" ] || { echo "confluence: could not resolve spaceId for key $space_key" >&2; exit 1; }
    bash "$script_dir/confluence-target.sh" enable "$repo" --cloud "$cloud_id" --space "$space_key" \
      --space-id "$space_id" ${parent_id:+--parent "$parent_id"} --status "$status" 2>/dev/null || true
  fi
  payload=$(jq -nc --arg sid "$space_id" --arg st "$status" --arg t "$title" \
    --argjson v "$(body_value_json)" --arg pid "$parent_id" \
    '{spaceId:$sid, status:$st, title:$t, body:{representation:"storage", value:$v}}
     + (if $pid=="" then {} else {parentId:$pid} end)')
  resp=$(api POST "/api/v2/pages" "$payload") || exit 1
  page_id=$(printf '%s' "$resp" | jq -r '.id'); new_version=$(printf '%s' "$resp" | jq -r '.version.number')
  # Bootstrap my accountId for future ownership checks — the create response's
  # authorId is me (I just created it). No-op if already cached for this email.
  cache_account_id "$(printf '%s' "$resp" | jq -r '.authorId // empty')"
  echo "$(page_url "$page_id")"
  echo "created page $page_id (version $new_version): $title" >&2
fi

# ── Persist identity + version, and pin as the worktree's active proposal ──────
# (mirrors post-issue's state save/pin; keyed on confluence:<id> per SKILL.md 6b).
if [ -n "$state_file" ] && [ -f "$state_file" ] && [ -n "${page_id:-}" ]; then
  tmp="$state_file.tmp.$$"
  jq --arg id "$page_id" --argjson v "${new_version:-1}" \
    '.confluence_page_id=$id | .confluence_version=$v' "$state_file" > "$tmp" && mv "$tmp" "$state_file" || true
  if [ -f "$script_dir/state.sh" ]; then
    bash "$script_dir/state.sh" save "confluence:$page_id" "$state_file" >/dev/null 2>&1 || true
    bash "$script_dir/state.sh" pin  "confluence:$page_id" >/dev/null 2>&1 || true
  fi
fi
