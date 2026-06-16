#!/usr/bin/env bash
#
# claude-account-setup.sh — provision a SECOND Claude Code account that shares
# everything with the primary (~/.claude) EXCEPT account identity + credentials.
#
# Why this works
# --------------
# Each CLAUDE_CONFIG_DIR keeps its own credentials. On macOS they are stored in
# the Keychain under a per-config-dir service name (Claude Code-credentials for
# the default dir, Claude Code-credentials-<hash> for a custom one); on Linux each
# dir uses its own <dir>/.credentials.json. Either way the two accounts use
# separate credential stores and never collide — both can be logged in and running
# at the same time in separate terminals.
#
# What is SHARED (symlinked to a single source of truth):
#   CLAUDE.md, skills, agents, commands, plugins, rules, hooks, output-styles,
#   settings.json, and conversation history (projects/).
# What is PER-ACCOUNT (never shared):
#   credentials (own Keychain entry on macOS / .credentials.json on Linux),
#   identity + per-project state (.claude.json), settings.local.json, and caches.
#
# Usage:
#   scripts/claude-account-setup.sh [CONFIG_DIR]
#     CONFIG_DIR   config dir for the 2nd account (default: ~/.claude-alt)

set -euo pipefail

PRIMARY="$HOME/.claude"
AGENTS="$HOME/.agents"
CONFIG_DIR="${1:-$HOME/.claude-alt}"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"   # expand a leading ~

if [[ "$CONFIG_DIR" == "$PRIMARY" ]]; then
  echo "Refusing: $CONFIG_DIR is the primary config dir (uses the Keychain)." >&2
  exit 1
fi
if [[ ! -d "$PRIMARY" ]]; then
  echo "Primary config dir not found: $PRIMARY" >&2
  exit 1
fi

echo "Provisioning secondary Claude Code config: $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

# link <source> <name-in-config-dir> — idempotent, replaces stale links only
link() {
  local src="$1" name="$2" dst="$CONFIG_DIR/$2"
  if [[ ! -e "$src" ]]; then
    echo "  skip  $name (no source: $src)"
    return
  fi
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    echo "  ok    $name"
    return
  fi
  [[ -e "$dst" || -L "$dst" ]] && rm -rf "$dst"
  ln -s "$src" "$dst"
  echo "  link  $name -> $src"
}

# Shared, identity-free configuration (single source of truth)
link "$AGENTS/AGENTS.md"       "CLAUDE.md"
link "$AGENTS/skills"          "skills"
link "$PRIMARY/commands"       "commands"
link "$PRIMARY/agents"         "agents"
link "$PRIMARY/plugins"        "plugins"
link "$PRIMARY/rules"          "rules"
link "$PRIMARY/hooks"          "hooks"
link "$PRIMARY/output-styles"  "output-styles"
link "$PRIMARY/settings.json"  "settings.json"
# Shared conversation history. Transcripts are per-session files, so two running
# instances write different files — safe to share. (Per-project permission grants
# live in each account's own .claude.json and are intentionally NOT shared.)
link "$PRIMARY/projects"       "projects"

# settings.local.json is intentionally NOT created. It's an optional per-account
# override layer that Claude Code auto-creates only if/when it writes a machine-
# local setting (e.g. an "always allow" choice). settings.json (shared via the
# symlink above) is the real config; an empty local file is just a no-op.

# Seed MCP servers so the 2nd account starts identical. Copies the primary's
# global mcpServers without touching any identity keys. Ongoing parity is best
# managed with the declarative manifest — see `claude-alt-mcp` in README.
if [[ -f "$HOME/.claude.json" ]]; then
  python3 - "$HOME/.claude.json" "$CONFIG_DIR/.claude.json" <<'PY'
import json, os, sys
primary, target = sys.argv[1], sys.argv[2]
try:
    with open(primary) as f:
        mcp = json.load(f).get("mcpServers", {})
except (FileNotFoundError, ValueError):
    mcp = {}
data = {}
if os.path.exists(target):
    try:
        with open(target) as f:
            data = json.load(f)
    except (ValueError, OSError):
        data = {}
servers = data.setdefault("mcpServers", {})
added = 0
for name, cfg in mcp.items():
    if name not in servers:
        servers[name] = cfg
        added += 1
with open(target, "w") as f:
    json.dump(data, f, indent=2)
print(f"  mcp   seeded {added} server(s) into {os.path.basename(target)} "
      f"({len(mcp)} available in primary)")
PY
fi

cat <<EOF

Done.

Next steps:
  1. Launch the 2nd account and log in (stores creds in its own Keychain entry on macOS):
       claude-alt          # or: CLAUDE_CONFIG_DIR=$CONFIG_DIR claude
  2. Use the primary account as usual:
       claude
Both can run at the same time in separate terminals/panes.
EOF
