tap "homebrew/bundle"

# Core Binaries (Cross-Platform)
brew "git"
brew "starship"                # Prompt
brew "fnm"                     # Node manager
brew "mcfly"                   # History search
brew "fzf"                     # Fuzzy finder
brew "lazygit"                 # Git UI
brew "zsh-syntax-highlighting" # Shell syntax highlighting

# macOS Specifics
if OS.mac?
  cask "wezterm"
  cask "font-jetbrains-mono-nerd-font"
end

# Editor & Dependencies (LazyVim)
brew "neovim"
brew "ripgrep"                 # Fast grep (required by Telescope)
brew "fd"                      # Fast find (required by Telescope)

# Modern CLI Tools
brew "tealdeer"                # Fast tldr (man pages)
brew "zoxide"                  # Smarter cd
brew "eza"                     # Modern ls
brew "bat"                     # Modern cat
brew "git-delta"               # Modern git diff

if OS.linux?
  brew "wslu"                  # WSL Utilities
end
