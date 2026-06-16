# Dotfiles

**Write once, run everywhere.**

This repository manages my configuration for **macOS** and **Linux (WSL2)**, ensuring a consistent development environment across machines.

## 🪟 Windows (WSL2) Setup

This automation handles the **Linux/WSL2** environment and automatically bridges your configuration to the Windows host.

1.  **Install WezTerm:** Install the WezTerm terminal on Windows.
2.  **Enable Developer Mode (Recommended):** 
    *   Go to **Settings > Privacy & security > For developers**.
    *   Toggle **Developer Mode** to **ON**. This allows the installer to create symbolic links without Administrator privileges.
    *   *Note: If the installer fails with a permission error, run `wsl --shutdown` in a Windows PowerShell and try again.*
3.  **Install Fonts (Automated):** The installer now handles font installation for both WSL and Windows. You no longer need to install them manually.
4.  **Proceed with Installation:** Open WezTerm, launch WSL (`wsl`), and run `./install.sh`. The script will automatically link your config and install the required fonts.

## 🚀 Installation

### 1. Clone the repository
```bash
git clone https://github.com/YOUR_USERNAME/dotfiles.git ~/dotfiles
cd ~/dotfiles
```

### 2. Run the setup script
This script will backup your existing config, create symlinks, and install dependencies via Homebrew.
```bash
./install.sh
```

## 🛠️ Tooling Cheatsheet

Your terminal is supercharged with modern Rust-based tools. Here is how to use them.

### Navigation & Files
| Command | Tool | Description |
| :--- | :--- | :--- |
| `z <name>` | **zoxide** | Jump to any directory instantly (fuzzy match). |
| `zi` | **zoxide** | Interactive directory selection with FZF. |
| `ls` | **eza** | Modern, colorful directory listing with icons and git status. |
| `cat <file>` | **bat** | View file with syntax highlighting and line numbers. |
| `del <file>` | **trash-cli** | **Safely delete** files to the system trash (instead of `rm`). |
| `y` | **yazi** | Blazing fast terminal file manager (like Finder/Explorer). |

### Git & Docker
| Command | Tool | Description |
| :--- | :--- | :--- |
| `lg` | **lazygit** | Full terminal UI for Git. Never type `git add` again. |
| `ld` | **lazydocker** | Full terminal UI for Docker. View logs, restart containers easily. |
| `delta` | **git-delta** | Beautiful side-by-side git diffs (auto-configured). |

### Search
| Command | Tool | Description |
| :--- | :--- | :--- |
| `Ctrl+T` | **fzf** | Fuzzy find files in current dir (with **Live Preview**). |
| `Alt+C` | **fzf** | Fuzzy find directories and cd into them. |
| `Ctrl+R` | **mcfly** | Smart shell history search (uses AI ranking). |
| `help <cmd>` | **tealdeer** | Simplified man pages (e.g., `help tar`). |

### Monitoring
| Command | Tool | Description |
| :--- | :--- | :--- |
| `btop` | **btop** | System monitor (CPU, Mem, Network) with Tokyo Night theme. |

## 🔐 Post-Installation (Manual Steps)

These files are **ignored by git** to keep your secrets safe. You must create them manually on each new machine.

### 1. Identity (`~/.gitconfig_local`)
Set your git identity to ensure your commits are attributed correctly.
```ini
[user]
    name = Your Name
    email = you@example.com
```

### 2. Secrets (`~/.zshrc_local`)
Add your API keys, tokens, and machine-specific logic here.
```bash
# Secrets
export ANTHROPIC_API_KEY="sk-..."
export GITHUB_TOKEN="ghp_..."

# Machine-specific Aliases
alias work="cd ~/work/projects"
```

## 🔄 Workflow

*   **Sync:** To get the latest config on any machine:
    ```bash
    cd ~/dotfiles && git pull && ./install.sh
    ```
    *Note: Running `./install.sh` acts as a "repair" or "update" script. It is safe to run multiple times.*

*   **Update:** To save changes:
    1.  Edit your config files normally (e.g., `~/.zshrc`).
    2.  `cd ~/dotfiles`
    3.  `git commit -am "Update config"`
    4.  `git push`

## 🤖 MCP Manifest

Shared MCP definitions now live in [`mcp/manifest.yaml`](mcp/manifest.yaml). This is the canonical manifest for user-level MCPs that should follow you across machines and coding agents.

Apply it declaratively with:
```bash
node scripts/mcp-sync.mjs plan
node scripts/mcp-sync.mjs apply
```

Notes:
*   The sync script reconciles via each agent's native `mcp add` / `mcp remove` commands instead of editing agent config files directly.
*   This dotfiles manifest is for user-scoped shared MCPs. Project-scoped MCPs should live in the project repo that owns them.
*   Servers are enabled for all supported agents by default. Use `excludeAgents` only when a server should be skipped for specific clients.
*   Only environment variable names belong in the manifest. Keep actual secrets in `~/.zshrc_local` or another local secret source.
*   The manifest supports both OAuth-capable remote MCPs and env-based authentication for servers that require API keys.
*   Use the generic `auth` block for remote auth in a client-agnostic way.
*   Manifest shape is defined in `mcp/manifest.schema.json` and linked from `mcp/manifest.yaml` for editor validation.

### MCP Workflow

Use this flow when adding, removing, or updating servers in `mcp/manifest.yaml`.

*   Add/update a server from a client instruction (no manual YAML edits):
    1. Preview translation:
       `node scripts/mcp-import.mjs parse --instruction 'codex mcp add vercel --url https://mcp.vercel.com'`
    2. Write into manifest:
       `node scripts/mcp-import.mjs apply --instruction 'codex mcp add vercel --url https://mcp.vercel.com'`
       Optional key override: append `--key <serverKey>`.
    3. Preview sync changes:
       `node scripts/mcp-sync.mjs plan`
    4. Apply to agents:
       `node scripts/mcp-sync.mjs apply`
*   Remove a server:
    1. Remove from manifest:
       `node scripts/mcp-import.mjs remove --key <serverKey>`
    2. Run `node scripts/mcp-sync.mjs plan` to verify remove actions.
    3. Run `node scripts/mcp-sync.mjs apply` to remove it from all agents.
*   Roll out to one agent first (for example, Gemini):
    1. Preview only Gemini changes: `node scripts/mcp-sync.mjs plan --agent gemini`
    2. Apply only Gemini changes: `node scripts/mcp-sync.mjs apply --agent gemini`
    3. After validation, preview all agents: `node scripts/mcp-sync.mjs plan --agent all`
    4. Then propagate to all agents: `node scripts/mcp-sync.mjs apply --agent all`

`plan` is read-only. `apply` executes changes and updates `mcp/.sync-state.json`.
`mcp-import` currently parses common `mcp add` instructions from `codex`, `claude`, and `gemini`.
`mcp-import apply` writes only to `mcp/manifest.yaml` (source of truth).
`mcp-sync apply` then updates agent-native configs (for example: Codex `~/.codex/config.toml`, Gemini `~/.gemini/settings.json`).

## 👥 Two Claude Code Accounts

Run two Claude accounts at the same time, in separate terminals, sharing one
setup (skills, agents, commands, plugins, settings, hooks, and conversation
history) — only identity and credentials differ.

**How it works:** Claude Code reads the macOS Keychain for credentials *only*
when `CLAUDE_CONFIG_DIR` is unset. Point `CLAUDE_CONFIG_DIR` at a custom dir and
it reads/writes `<dir>/.credentials.json` instead, never touching the Keychain.
So the primary account stays in the Keychain and the secondary lives in a file —
no collision, both usable simultaneously.

One-time setup:
```bash
scripts/claude-account-setup.sh          # provisions ~/.claude-alt (symlinks shared config)
claude-alt                               # launch 2nd account, then log in (creates .credentials.json)
```

Daily use (defined in `zsh/.zshrc`):
*   `claude` — auto-picks the least-loaded account (see *Automatic account selection*).
*   `claude-alt` — force the secondary account (`$CLAUDE_ALT_DIR`, default `~/.claude-alt`).
*   `claude-alt-mcp [plan|apply]` — sync the 2nd account's MCP from `mcp/manifest.yaml`.

What is shared vs. per-account:
*   **Shared** (symlinked to one source of truth): `CLAUDE.md`, `skills`, `agents`,
    `commands`, `plugins`, `rules`, `hooks`, `settings.json`, and history (`projects/`).
*   **Per-account** (never shared): credentials, identity + per-project state
    (`.claude.json`), `settings.local.json`, and runtime caches.

The setup script seeds the 2nd account's MCP servers from the primary so it starts
identical; `claude-alt-mcp apply` keeps it in sync with the manifest thereafter.

### Automatic account selection

`claude` is a wrapper (in `zsh/.zshrc`) that routes each launch to whichever
account has fewer live sessions, so you never choose by hand. It keeps a small
per-shell marker tally (the two accounts are indistinguishable to herdr), prefers
the **primary** on a tie — so a lone session lands on primary and only overflow
spreads to the alt account. Non-interactive launches (`-p` / piped / `$CI`) and
resume (`-c` / `--continue` / `--resume`) are pinned to the primary so background
work and the fleet stay on one account. Force one with `CLAUDE_ACCOUNT=primary|alt`,
or use `claude-alt`.

## 📂 Structure

*   **`install.sh`**: The master idempotent setup script.
*   **`scripts/`**: Automation utilities (Windows-WSL bridge, diagnostic tests).
*   **`Brewfile`**: The manifest of installed tools.
*   **`zsh/`**: Shell configuration (Aliases, FZF, Tools init).
*   **`wezterm/`**: Cross-platform configuration (Dynamic titlebars, Tokyo Night theme).
*   **`ghostty/`**: Ghostty terminal configuration (Tokyo Night Day theme).
*   **`git/`**: Global git configuration (Delta, Excludes).
*   **`nvim/`**: LazyVim configuration.
*   **`btop/`**: System monitor config.
*   **`herdr/`**: Herdr agent workspace manager config (Tokyo Night Day, terminal-delivered notifications).
