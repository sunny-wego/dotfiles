#!/bin/bash
set -e

DOTFILES_DIR="$HOME/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"

# Detect Windows (WSL). Some tools (e.g. Ghostty) are unsupported there.
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=true
else
  IS_WSL=false
fi

echo "🚀 Starting Dotfiles Setup..."

# Function to backup and link
link_file() {
  local source_file="$1"
  local target_file="$2"

  # Check if target exists and is not a symlink pointing to the correct location
  if [ -e "$target_file" ] || [ -L "$target_file" ]; then
    if [ -L "$target_file" ] && [ "$(readlink "$target_file")" = "$source_file" ]; then
      echo "✅  $target_file is already linked."
      return
    fi

    echo "📦  Backing up $target_file to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    mv "$target_file" "$BACKUP_DIR/"
  fi

  # Create directory if it doesn't exist
  mkdir -p "$(dirname "$target_file")"

  echo "🔗  Linking $target_file -> $source_file"
  ln -s "$source_file" "$target_file"
}

# 1. Install Dependencies FIRST
echo -e "\n--- Installing Dependencies ---"
if command -v brew >/dev/null 2>&1; then
  echo "🍺  Homebrew detected. Installing bundle..."
  brew bundle --file="$DOTFILES_DIR/Brewfile" || echo "⚠️  Some Brewfile dependencies failed to install (this is normal on Linux if using Mac-only casks)"

  # Bootstrap Node.js via fnm
  if command -v fnm >/dev/null; then
    echo "📦  Ensuring Node.js (LTS) is installed via fnm..."
    # We need to initialize fnm in the subshell to use it immediately
    eval "$(fnm env --shell bash)"
    fnm install --lts
    fnm alias lts-latest default
  fi
else
  echo "⚠️  Homebrew not found. Skipping dependency installation."
  echo "👉  Install Homebrew to use the Brewfile: https://brew.sh"
fi

# 2. Link Configuration Files
echo -e "\n--- Linking Configuration Files ---"
link_file "$DOTFILES_DIR/zsh/.zshrc" "$HOME/.zshrc"
link_file "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
link_file "$DOTFILES_DIR/wezterm/wezterm.lua" "$HOME/.wezterm.lua"
# Ghostty is unsupported on Windows — skip its config link under WSL.
if [ "$IS_WSL" != true ]; then
  link_file "$DOTFILES_DIR/ghostty/config" "$HOME/.config/ghostty/config"
fi
link_file "$DOTFILES_DIR/starship/starship.toml" "$HOME/.config/starship.toml"
link_file "$DOTFILES_DIR/nvim" "$HOME/.config/nvim"
link_file "$DOTFILES_DIR/btop" "$HOME/.config/btop"
link_file "$DOTFILES_DIR/lazygit/config.yml" "$HOME/.config/lazygit/config.yml"
link_file "$DOTFILES_DIR/herdr/config.toml" "$HOME/.config/herdr/config.toml"
# Zeus moved to its own repo (github.com/wego/zeus); it manages its own symlink there.

# 3. Create Local Config Templates
echo -e "\n--- Checking Local Configs ---"
if [ ! -f "$HOME/.zshrc_local" ]; then
  echo "⚠️  Creating template ~/.zshrc_local"
  echo "# Add your local secrets and API keys here" >"$HOME/.zshrc_local"
fi

if [ ! -f "$HOME/.gitconfig_local" ]; then
  echo "⚠️  Creating template ~/.gitconfig_local"
  cat >"$HOME/.gitconfig_local" <<'EOF'
[user]
	name = Your Name
	email = your@email.com
EOF
fi

# 4. Post-Install Configuration
echo -e "\n--- Post-Install Configuration ---"

# Bat Theme (TokyoNight Day)
if command -v bat >/dev/null; then
  BAT_CONFIG_DIR="$(bat --config-dir)"
  BAT_THEMES_DIR="$BAT_CONFIG_DIR/themes"
  THEME_NAME="tokyonight_day"
  THEME_FILE="$BAT_THEMES_DIR/$THEME_NAME.tmTheme"

  if [ ! -f "$THEME_FILE" ]; then
    echo "🎨  Installing Bat Theme: TokyoNight Day..."
    mkdir -p "$BAT_THEMES_DIR"
    curl -s -o "$THEME_FILE" "https://raw.githubusercontent.com/folke/tokyonight.nvim/main/extras/sublime/tokyonight_day.tmTheme"
    echo "🔨  Building bat cache..."
    bat cache --build
  else
    echo "✅  Bat theme already installed."
  fi
fi

# TLDR Update
if command -v tldr >/dev/null; then
  echo "📚  Updating tldr cache..."
  tldr --update >/dev/null 2>&1 || echo "⚠️  tldr update skipped"
fi

# Zsh Plugins
if [ ! -d "$HOME/.config/fzf-tab" ]; then
  echo "⬇️  Installing fzf-tab..."
  git clone --depth 1 https://github.com/Aloxaf/fzf-tab "$HOME/.config/fzf-tab"
fi

# --- AI Tools (Declarative Setup) ---
ensure_installed() {
  local cmd="$1"
  local install_cmd="$2"
  local name="${3:-$cmd}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "⬇️  Installing $name..."
    eval "$install_cmd"
  else
    echo "✅  $name is already installed."
  fi
}

# Define tools here
ensure_installed "claude" "curl -fsSL https://claude.ai/install.sh | bash" "Claude Code"

# SonarQube MCP server (long-lived HTTP service on :8765, shared across AI clients).
# Idempotent: recreates the container. Skips cleanly if Docker or secrets are absent.
if command -v docker >/dev/null 2>&1 && [ -n "${SONARQUBE_TOKEN:-}" ] && [ -n "${SONARQUBE_URL:-}" ]; then
  "$DOTFILES_DIR/scripts/sonarqube-mcp.sh" || echo "⚠️  SonarQube MCP server failed to start (continuing)"
else
  echo "⏭️  Skipping SonarQube MCP server (needs Docker + SONARQUBE_TOKEN/SONARQUBE_URL in ~/.zshrc_local)."
  echo "    Start it later with: $DOTFILES_DIR/scripts/sonarqube-mcp.sh"
fi

# 5. Cross-Platform Sync & Assets (WSL)
if [ "$IS_WSL" = true ]; then
  "$DOTFILES_DIR/scripts/install-fonts.sh"
  "$DOTFILES_DIR/scripts/sync-wezterm.sh"
fi

echo -e "\n✨  Dotfiles setup complete! Restart your shell."
