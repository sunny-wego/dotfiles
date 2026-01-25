#!/bin/bash
set -e

# Configuration
FONT_NAME="JetBrainsMono"
NERD_FONTS_VERSION="v3.3.0" # Latest stable version
FONT_ZIP="${FONT_NAME}.zip"
DOWNLOAD_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_VERSION}/${FONT_ZIP}"
LOCAL_FONT_DIR="$HOME/.local/share/fonts"

# Function: Install on macOS
install_macos() {
    echo "🍺  macOS detected. Ensuring font is installed via Homebrew..."
    # Brewfile already handles this, but we can trigger it just in case
    brew bundle --file="$HOME/dotfiles/Brewfile"
}

# Function: Install on WSL (Linux side)
install_linux() {
    echo "🐧  Linux/WSL detected. Checking fonts..."
    mkdir -p "$LOCAL_FONT_DIR"

    if ls "$LOCAL_FONT_DIR"/${FONT_NAME}*Nerd*Font*.ttf >/dev/null 2>&1; then
        echo "✅  $FONT_NAME Nerd Font already exists in WSL."
    else
        echo "⬇️  Downloading $FONT_NAME Nerd Font..."
        TMP_DIR=$(mktemp -d)
        curl -fLo "$TMP_DIR/$FONT_ZIP" "$DOWNLOAD_URL"
        unzip -o "$TMP_DIR/$FONT_ZIP" -d "$TMP_DIR"
        
        echo "📦  Installing fonts to $LOCAL_FONT_DIR..."
        cp "$TMP_DIR"/*.ttf "$LOCAL_FONT_DIR/"
        fc-cache -f "$LOCAL_FONT_DIR"
        rm -rf "$TMP_DIR"
        echo "✅  Fonts installed in WSL."
    fi
}

# Function: Bridge to Windows
bridge_to_windows() {
    if ! grep -qi microsoft /proc/version; then
        return
    fi

    echo -e "\n🪟  Bridging fonts to Windows..."
    
    # Get Windows Font directory for current user
    WIN_HOME=$(powershell.exe -NoProfile -Command "Write-Host \$env:USERPROFILE" | tr -d '\r')
    WIN_FONT_DIR="$WIN_HOME\\AppData\\Local\\Microsoft\\Windows\\Fonts"
    
    # Ensure Windows font directory exists
    powershell.exe -NoProfile -Command "if (!(Test-Path '$WIN_FONT_DIR')) { New-Item -ItemType Directory -Path '$WIN_FONT_DIR' -Force }" > /dev/null

    # Get WSL path for the fonts
    WSL_FONT_PATH=$(wslpath -w "$LOCAL_FONT_DIR")

    # Copy and register fonts using PowerShell
    # We use a script block to find all JetBrains Mono TTFs and register them
    powershell.exe -NoProfile -Command "
        \$fonts = Get-ChildItem -Path '$WSL_FONT_PATH' -Filter '*JetBrainsMono*Nerd*Font*.ttf'
        foreach (\$font in \$fonts) {
            \$target = Join-Path '$WIN_FONT_DIR' \$font.Name
            if (!(Test-Path \$target)) {
                Write-Host \"🔗 Copying \$(\$font.Name) to Windows...\"
                Copy-Item \$font.FullName -Destination \$target -Force
                
                # Register the font in HKCU registry
                \$reg_name = \"\$(\$font.BaseName) (TrueType)\"
                \$reg_path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
                New-ItemProperty -Path \$reg_path -Name \$reg_name -Value \$font.Name -PropertyType String -Force | Out-Null
            }
        }
    "
    echo "✅  Fonts bridged and registered in Windows."
}

# Main Execution
if [[ "$OSTYPE" == "darwin"* ]]; then
    install_macos
else
    install_linux
    bridge_to_windows
fi

echo "✨  Font setup complete!"
