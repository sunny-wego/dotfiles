# Agent Guide for Dotfiles

This repository contains personal configuration files (dotfiles) for **macOS** and **Windows (via WSL2)**. 
Agents operating here must respect the existing structure, symlink logic, and aesthetic choices (**Tokyo Night Day**).

## 1. Project Principles (CRITICAL)

1.  **Idempotency**: The `install.sh` script must be safe to run multiple times without side effects. It should verify state before acting (e.g., check if a link exists and points to the correct target before linking).
2.  **Declarative Configuration**: Prefer defining the "desired state" in a config file over imperative setup steps. If a feature can be configured via a tool's native config (e.g., Starship's `add_newline`), do not write a shell hook for it.
3.  **Cross-Platform Parity**: All changes must work on both **macOS** and **WSL2**. 
    *   **Unified Package Management**: Use **Homebrew** (macOS) and **Linuxbrew** (WSL). **DO NOT use `apt`, `yum`, or `pacman`.**
    *   **WSL2 Bridge**: WezTerm typically runs on Windows but reads its configuration from WSL. Path translation (via `wslpath`) may be required in setup scripts.

## 2. Project Structure

- **`install.sh`**: The master setup script. Handles symlinking, directory creation, and dependency bootstrapping.
- **`Brewfile`**: The source of truth for all binary dependencies. Cross-platform via `if OS.mac?` and `if OS.linux?` blocks.
- **`zsh/`**: Zsh configuration. `.zshrc` is the primary entry point.
- **`wezterm/`**: Terminal configuration. Uses `wezterm.lua`.
- **`nvim/`**: Neovim configuration. Based on **LazyVim**.
- **`starship/`**: Prompt configuration via `starship.toml`.
- **`lazygit/`**: Git TUI configuration.

## 3. Build & Installation

### Full Setup
To apply all configurations and synchronize dependencies:
```bash
./install.sh
```
*Note: This script is designed to be idempotent. It creates backups of existing files in `~/.dotfiles_backup/` only if they are not already managed by this repository.*

### Dependency Management
*   **Adding Tools**: Add new packages to `Brewfile`.
*   **Removing Tools**: Remove from `Brewfile`.
*   **Updating**: Run `brew bundle install` or `brew bundle cleanup`.

## 4. Testing & Verification

Automated testing is not currently implemented. Verification must be performed manually after every change.

### Shell (Zsh)
1.  **Syntax Check**: `zsh -n zsh/.zshrc`
2.  **Apply**: Run `source ~/.zshrc` or `exec zsh`.
3.  **Functional Check**: Test the specific feature (e.g., `cd <TAB>` for tree-view, `kill <TAB>` for process details).

### Terminal (WezTerm)
1.  **Reload**: WezTerm auto-reloads on save.
2.  **Validation**: Use the Debug Overlay (`CTRL+SHIFT+L`) to check for Lua runtime errors or log messages.
3.  **Cross-Check**: If a change affects windowing, verify it doesn't break the `is_windows` logic.

### Editor (Neovim)
1.  **Health**: Run `:checkhealth` inside Neovim.
2.  **Sync**: Run `:Lazy sync` if new plugins were added to the configuration.

## 5. Code Style & Conventions

### General
*   **Path Management**: Use `$HOME` or `~` for path references. Never hardcode usernames or `/Users/` paths.
*   **Cross-Platform Logic**: 
    *   **Shell**: `if [[ "$OSTYPE" == "darwin"* ]]; then ... fi`
    *   **WezTerm (Lua)**: `local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"`

### Lua (WezTerm & Neovim)
*   **Formatter**: Stylua.
*   **Indent**: 2 Spaces.
*   **Max Line Length**: 120 Columns.
*   **Conventions**: 
    *   Prefer `local` variables over global ones.
    *   Use tables for configuration organization.
    *   Minimize imperative logic in config files.
*   **Error Handling**:
    *   Use `pcall` or `xpcall` when requiring optional plugins or running risky logic.
    *   Log errors using `wezterm.log_error` or `vim.notify`.

### Zsh (Shell)
*   **Abstraction**: Prefer functions over aliases for anything involving more than one command or complex flags.
*   **Hooks**: Use `add-zsh-hook` for event-driven logic (e.g., `precmd`, `chpwd`) to avoid overwriting existing hooks.
*   **Completions**: Use `zstyle` for all `fzf-tab` and completion system tuning.
*   **Safety**: Use `command -v` to check for tool existence before initializing related config.
*   **Pathing**: Always quote paths to handle spaces correctly.

### Shell Scripts (Bash)
*   **Safety**: Use `set -e` at the top of scripts to exit on error.
*   **Portability**: Use `/usr/bin/env bash` for the shebang.
*   **Dry Run**: When making destructive changes (like `rm`), prefer moving to a backup directory first.

### TOML (Starship)
*   **Grouping**: Group modules logically.
*   **Native Features**: Always use Starship's built-in variables and modules before attempting to write a custom shell prompt element.

## 6. Agent Constraints

1.  **Respect Local Overrides**: NEVER modify `~/.zshrc_local` or `~/.gitconfig_local`. These are reserved for user-specific secrets and machine-dependent logic.
2.  **Symlink Safety**: When editing configurations, ensure you are editing the source file in the `dotfiles/` directory and not the symlink target in `$HOME`.
3.  **Aesthetic Continuity**: Maintain the **Tokyo Night Day** theme. Any new UI elements (like `fzf` previews or `lazygit` panels) must match this light-mode palette.
    *   **Primary Blue**: `#3760bf`
    *   **Focus/Selection**: `#cfd0d7`
    *   **Prompt/Success**: `#2e7de9`
4.  **No Apt/Yum**: If a dependency is missing on a Linux/WSL system, add it to the `Brewfile` under `OS.linux?` rather than using the system package manager.
