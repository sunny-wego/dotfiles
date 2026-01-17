# Dotfiles

**Write once, run everywhere.**

This repository manages my configuration for **macOS** and **Linux (WSL2)**, ensuring a consistent development environment across machines.

## 🪟 Windows (WSL2) Setup

This automation handles the **Linux/WSL2** environment. The Windows host must be set up manually.

1.  **Install WezTerm:** Install the WezTerm terminal on Windows.
2.  **Install Fonts on Windows:**
    *   Download [JetBrainsMono Nerd Font](https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/JetBrainsMono.zip).
    *   Unzip and install the font files into Windows (Select all -> Right Click -> Install).
    *   *Note: WezTerm running on Windows cannot see fonts installed inside WSL.*
3.  **Proceed with Installation:** Open WezTerm, launch WSL (`wsl`), and follow the steps below.

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
    cd ~/dotfiles && git pull && brew bundle
    ```
*   **Update:** To save changes:
    1.  Edit your config files normally (e.g., `~/.zshrc`).
    2.  `cd ~/dotfiles`
    3.  `git commit -am "Update config"`
    4.  `git push`

## 📂 Structure

*   **`Brewfile`**: The manifest of installed tools (Git, Starship, FNM, etc.).
*   **`zsh/`**: Shell configuration.
*   **`wezterm/`**: WezTerm styling and keybindings.
*   **`git/`**: Global git configuration.
*   **`starship/`**: Prompt theme.
