#!/bin/bash
set -e

DOTFILES_DIR="$HOME/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"

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

# 1. Install Dependencies FIRST (so binaries exist for configuration)
echo "\n--- Installing Dependencies ---"
if command -v brew >/dev/null 2>&1; then
    echo "🍺  Homebrew detected. Installing bundle..."
    brew bundle --file="$DOTFILES_DIR/Brewfile" || echo "⚠️  Some Brewfile dependencies failed to install (this is normal on Linux if using Mac-only casks)"
else
    echo "⚠️  Homebrew not found. Skipping dependency installation."
    echo "👉  Install Homebrew to use the Brewfile: https://brew.sh"
fi

# 2. Link Configuration Files
echo "\n--- Linking Configuration Files ---"
link_file "$DOTFILES_DIR/zsh/.zshrc" "$HOME/.zshrc"
link_file "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
link_file "$DOTFILES_DIR/wezterm/wezterm.lua" "$HOME/.wezterm.lua"
link_file "$DOTFILES_DIR/starship/starship.toml" "$HOME/.config/starship.toml"
link_file "$DOTFILES_DIR/nvim" "$HOME/.config/nvim"

# 3. Create Local Config Templates if missing
echo "\n--- Checking Local Configs ---"
if [ ! -f "$HOME/.zshrc_local" ]; then
    echo "⚠️  Creating template ~/.zshrc_local (Add your secrets here!)"
    echo "# Add your local secrets and API keys here" > "$HOME/.zshrc_local"
fi

if [ ! -f "$HOME/.gitconfig_local" ]; then
    echo "⚠️  Creating template ~/.gitconfig_local (Add your identity here!)"
    echo "[user]\n\tname = Your Name\n\temail = your@email.com" > "$HOME/.gitconfig_local"
fi

# 4. Post-Install Configuration
echo "\n--- Post-Install Configuration ---"

# Bat Theme (TokyoNight)
if command -v bat >/dev/null; then
    BAT_CONFIG_DIR="$(bat --config-dir)"
    BAT_THEMES_DIR="$BAT_CONFIG_DIR/themes"
    THEME_NAME="tokyonight_storm"
    THEME_FILE="$BAT_THEMES_DIR/$THEME_NAME.tmTheme"
    
    if [ ! -f "$THEME_FILE" ]; then
        echo "🎨  Installing Bat Theme: TokyoNight Storm..."
        mkdir -p "$BAT_THEMES_DIR"
        curl -s -o "$THEME_FILE" "https://raw.githubusercontent.com/folke/tokyonight.nvim/main/extras/sublime/tokyonight_storm.tmTheme"
        echo "🔨  Building bat cache..."
        bat cache --build
    else
        echo "✅  Bat theme already installed."
    fi
fi

# TLDR Update
if command -v tldr >/dev/null; then
    echo "📚  Updating tldr cache..."
    tldr --update >/dev/null 2>&1 || echo "⚠️  tldr update skipped (network issue or already running)"
fi

# Btop Configuration (Tokyo Night)
if command -v btop >/dev/null; then
    mkdir -p "$HOME/.config/btop"
    if [ ! -f "$HOME/.config/btop/btop.conf" ]; then
        echo "📊  Configuring btop (Tokyo Night)..."
        # Create minimal config setting the theme
        echo 'color_theme = "tokyo-night"' > "$HOME/.config/btop/btop.conf"
        echo 'theme_background = False' >> "$HOME/.config/btop/btop.conf"
        echo 'vim_keys = True' >> "$HOME/.config/btop/btop.conf"
    fi
fi

echo "\n✨  Dotfiles setup complete! Restart your shell."
