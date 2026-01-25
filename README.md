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
3.  **Install Fonts on Windows:**
    *   Download [JetBrainsMono Nerd Font](https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/JetBrainsMono.zip).
    *   Unzip and install the font files into Windows (Select all -> Right Click -> Install).
    *   *Note: WezTerm running on Windows cannot see fonts installed inside WSL.*
4.  **Proceed with Installation:** Open WezTerm, launch WSL (`wsl`), and run `./install.sh`. The script will automatically link your config to `C:\Users\<User>\.wezterm.lua`.

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

## 📂 Structure

*   **`install.sh`**: The master idempotent setup script.
*   **`scripts/`**: Automation utilities (Windows-WSL bridge, diagnostic tests).
*   **`Brewfile`**: The manifest of installed tools.
*   **`zsh/`**: Shell configuration (Aliases, FZF, Tools init).
*   **`wezterm/`**: Cross-platform configuration (Dynamic titlebars, Tokyo Night theme).
*   **`git/`**: Global git configuration (Delta, Excludes).
*   **`nvim/`**: LazyVim configuration.
*   **`btop/`**: System monitor config.
