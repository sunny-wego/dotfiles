#!/bin/bash
set -e

# 1. Detection: Only run if inside WSL
if ! grep -qi microsoft /proc/version; then
    exit 0
fi

echo -e "\n--- Syncing WezTerm Config to Windows ---"

# 2. Path Discovery
# Get Windows User Profile path (e.g., C:\Users\Admin)
WIN_HOME=$(powershell.exe -NoProfile -Command "Write-Host \$env:USERPROFILE" | tr -d '\r')
WIN_TARGET="$WIN_HOME\\.wezterm.lua"

# Get WSL path in Windows format (e.g., \\wsl.localhost\Ubuntu-24.04\...)
WSL_SOURCE=$(wslpath -w "$HOME/dotfiles/wezterm/wezterm.lua")

# 3. Link Management
# Check if the link already exists and points to the right place
# We'll just force recreate it to be safe and idempotent
echo "🔗 Creating Windows symlink: $WIN_TARGET -> $WSL_SOURCE"

# Remove existing file/link to ensure mklink succeeds
powershell.exe -NoProfile -Command "if (Test-Path '$WIN_TARGET') { Remove-Item '$WIN_TARGET' -Force }"

# Create the link using cmd.exe /c mklink (works with Developer Mode)
if powershell.exe -NoProfile -Command "cmd.exe /c mklink '$WIN_TARGET' '$WSL_SOURCE'" > /dev/null; then
    echo "✅ WezTerm config successfully synced to Windows."
else
    echo "❌ Failed to create Windows symlink."
    echo "👉 Ensure 'Developer Mode' is enabled in Windows Settings."
    echo "👉 If it is already enabled, try running 'wsl --shutdown' from PowerShell and restart your terminal."
    exit 1
fi
