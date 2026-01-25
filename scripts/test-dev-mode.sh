#!/bin/bash
# scripts/test-dev-mode.sh

# Get Windows Temp path
WIN_TEMP=$(powershell.exe -NoProfile -Command "Write-Host \$env:TEMP" | tr -d '\r')
# Use a simple file as target instead of C:\ for better compatibility
TEST_TARGET="C:\\Windows\\win.ini"
TEST_LINK="$WIN_TEMP\\wezterm_dev_test_link"

echo "🔍 Checking Windows Developer Mode status..."

# Attempt to create a symlink on the Windows side
if powershell.exe -NoProfile -Command "New-Item -ItemType SymbolicLink -Path '$TEST_LINK' -Target '$TEST_TARGET' -Force" > /dev/null 2>&1; then
    echo "✅ SUCCESS: Developer Mode is ENABLED."
    echo "You can create symlinks from WSL to Windows without Administrator rights."
    
    # Cleanup
    powershell.exe -NoProfile -Command "Remove-Item '$TEST_LINK' -Force" > /dev/null 2>&1
else
    echo "❌ FAILURE: Developer Mode is DISABLED (or requires elevation)."
    echo "-----------------------------------------------------------"
    echo "To fix this, enable Developer Mode in Windows:"
    echo "1. Open Windows Settings"
    echo "2. Go to Privacy & security > For developers"
    echo "3. Toggle 'Developer Mode' to ON"
    echo "-----------------------------------------------------------"
    exit 1
fi
