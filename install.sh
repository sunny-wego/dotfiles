#!/bin/bash
set -e

# --- Configuration ---
DOTFILES_DIR="$HOME/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"

echo "🚀 Starting Dotfiles Setup..."

# --- Utility Functions ---

# Function to backup existing targets and create symlinks
link_file() {
  local src="$1"
  local dest="$2"

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    # Skip if already correctly linked
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
      echo "✅ $dest is already linked."
      return
    fi
    # Backup existing file/directory
    echo "📦 Backing up $dest to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    mv "$dest" "$BACKUP_DIR/"
  fi

  mkdir -p "$(dirname "$dest")"
  echo "🔗 Linking $dest -> $src"
  ln -s "$src" "$dest"
}

# Function to install a tool if it doesn't exist
ensure_installed() {
  local cmd="$1"
  local install_script="$2"
  local name="${3:-$cmd}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "⬇️  Installing $name..."
    eval "$install_script"
  else
    echo "✅ $name is already installed."
  fi
}

# --- 1. Dependencies ---

printf "\n--- Installing Dependencies ---\n"
if command -v brew >/dev/null 2>&1; then
  echo "🍺 Homebrew detected. Installing bundle..."
  brew bundle --file="$DOTFILES_DIR/Brewfile" || echo "⚠️ Some dependencies failed (Mac-only casks on Linux?)"

  if command -v fnm >/dev/null; then
    echo "📦 Bootstrapping Node.js via fnm..."
    eval "$(fnm env --shell bash)"
    fnm install --lts && fnm alias lts-latest default
  fi
else
  echo "⚠️ Homebrew not found. Skipping dependency installation."
fi

# --- 2. Configuration Links ---

printf "\n--- Linking Configuration Files ---\n"
# Format: "source_relative_path:target_absolute_path"
FILES=(
  "zsh/.zshrc:$HOME/.zshrc"
  "git/.gitconfig:$HOME/.gitconfig"
  "wezterm/wezterm.lua:$HOME/.wezterm.lua"
  "starship/starship.toml:$HOME/.config/starship.toml"
  "nvim:$HOME/.config/nvim"
  "btop:$HOME/.config/btop"
)

for entry in "${FILES[@]}"; do
  src_rel="${entry%%:*}"
  dest_abs="${entry#*:}"
  link_file "$DOTFILES_DIR/$src_rel" "$dest_abs"
done

# --- 3. Local Templates ---

printf "\n--- Checking Local Configs ---\n"
[ ! -f "$HOME/.zshrc_local" ] && echo "# Local secrets" > "$HOME/.zshrc_local" && echo "📝 Created ~/.zshrc_local"
if [ ! -f "$HOME/.gitconfig_local" ]; then
  printf "[user]\n\tname = Your Name\n\temail = your@email.com\n" > "$HOME/.gitconfig_local"
  echo "📝 Created ~/.gitconfig_local"
fi

# --- 4. Post-Install & Plugins ---

printf "\n--- Post-Install Configuration ---\n"

# Bat Theme (Tokyo Night Day)
if command -v bat >/dev/null; then
  THEME_FILE="$(bat --config-dir)/themes/tokyonight_day.tmTheme"
  if [ ! -f "$THEME_FILE" ]; then
    echo "🎨 Installing Bat Theme: Tokyo Night Day..."
    mkdir -p "$(dirname "$THEME_FILE")"
    curl -s -o "$THEME_FILE" "https://raw.githubusercontent.com/folke/tokyonight.nvim/main/extras/sublime/tokyonight_day.tmTheme"
    bat cache --build
  fi
fi

# TLDR & Plugins
command -v tldr >/dev/null && (tldr --update >/dev/null 2>&1 || echo "⚠️ tldr update skipped")
[ ! -d "$HOME/.config/fzf-tab" ] && echo "⬇️  Installing fzf-tab..." && git clone --depth 1 https://github.com/Aloxaf/fzf-tab "$HOME/.config/fzf-tab"

# AI Tools
ensure_installed "claude" "curl -fsSL https://claude.ai/install.sh | bash" "Claude Code"

# --- 5. WSL Integration ---

if grep -q "microsoft" /proc/version 2>/dev/null || [ -n "$WSL_DISTRO_NAME" ]; then
  if command -v powershell.exe >/dev/null; then
    printf "\n--- WSL Integration ---\n"
    WIN_HOME=$(powershell.exe -NoProfile -Command 'Write-Host -NoNewline $env:USERPROFILE' | tr -d '\r')
    WEZ_SRC=$(wslpath -w "$DOTFILES_DIR/wezterm/wezterm.lua")
    WEZ_DEST="$WIN_HOME\\.wezterm.lua"

    echo "🪟 Linking WezTerm to Windows..."
    powershell.exe -NoProfile -Command "if (Test-Path '$WEZ_DEST') { Remove-Item '$WEZ_DEST' }; New-Item -ItemType SymbolicLink -Path '$WEZ_DEST' -Target '$WEZ_SRC'" 2>/dev/null \
      && echo "✅ Windows Link Created" || echo "⚠️ Windows Link Failed (Dev Mode off?)"
  fi
fi

printf "\n✨ Dotfiles setup complete! Restart your shell.\n"
