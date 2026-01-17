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

# 1. Link Configuration Files
echo "\n--- Linking Configuration Files ---"
link_file "$DOTFILES_DIR/zsh/.zshrc" "$HOME/.zshrc"
link_file "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
link_file "$DOTFILES_DIR/wezterm/wezterm.lua" "$HOME/.wezterm.lua"
link_file "$DOTFILES_DIR/starship/starship.toml" "$HOME/.config/starship.toml"
link_file "$DOTFILES_DIR/nvim" "$HOME/.config/nvim"
# 2. Create Local Config Templates if missing
echo "\n--- Checking Local Configs ---"
if [ ! -f "$HOME/.zshrc_local" ]; then
    echo "⚠️  Creating template ~/.zshrc_local (Add your secrets here!)"
    echo "# Add your local secrets and API keys here" > "$HOME/.zshrc_local"
    echo "# export ANTHROPIC_API_KEY=..." >> "$HOME/.zshrc_local"
fi

if [ ! -f "$HOME/.gitconfig_local" ]; then
    echo "⚠️  Creating template ~/.gitconfig_local (Add your identity here!)"
    echo "[user]\n\tname = Your Name\n\temail = your@email.com" > "$HOME/.gitconfig_local"
fi

# 3. Install Dependencies
echo "\n--- Installing Dependencies ---"
if command -v brew >/dev/null 2>&1; then
    echo "🍺  Homebrew detected. Installing bundle..."
    brew bundle --file="$DOTFILES_DIR/Brewfile" || echo "⚠️  Some Brewfile dependencies failed to install (this is normal on Linux if using Mac-only casks)"
else
    echo "⚠️  Homebrew not found. Skipping dependency installation."
    echo "👉  Install Homebrew to use the Brewfile: https://brew.sh"
fi

echo "\n✨  Dotfiles setup complete! Restart your shell."
