# History file path
HISTFILE=~/.zsh_history

# Keep plenty of history in memory and on disk
HISTSIZE=50000
SAVEHIST=50000

# Options to sync history across shells immediately
setopt INC_APPEND_HISTORY    # append commands as they’re executed
setopt SHARE_HISTORY         # share commands between all sessions
setopt HIST_IGNORE_ALL_DUPS  # don’t keep duplicate commands
setopt HIST_REDUCE_BLANKS    # trim unnecessary spaces
setopt HIST_VERIFY           # show command before running from history

# Initialize Tools (with safety checks)
if command -v starship >/dev/null; then eval "$(starship init zsh)"; fi
if command -v mcfly >/dev/null; then eval "$(mcfly init zsh)"; fi
if command -v fnm >/dev/null; then eval "$(fnm env --use-on-cd --shell zsh)"; fi

# Custom Completions Path
fpath=(~/.zsh/completions $fpath)
autoload -U compinit; compinit

# Smart Source for FZF (if installed)
if command -v fzf >/dev/null; then source <(fzf --zsh); fi

# Auto-Clone & Source fzf-tab
if [[ ! -d ~/.config/fzf-tab ]]; then
  echo "Cloning fzf-tab..."
  git clone https://github.com/Aloxaf/fzf-tab ~/.config/fzf-tab
fi
[ -f ~/.config/fzf-tab/fzf-tab.plugin.zsh ] && source ~/.config/fzf-tab/fzf-tab.plugin.zsh

# Smart Source for Syntax Highlighting (Mac vs Linux)
if [[ -f "$(brew --prefix 2>/dev/null)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
  source "$(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
elif [[ -f "/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
  source "/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi

# Load WezTerm Window Title Logic
set_wezterm_title() {
    if [[ "$TERM_PROGRAM" != "WezTerm" ]]; then return; fi
    local title
    if git rev-parse --git-dir >/dev/null 2>&1; then
        local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
        if [[ -n "$git_root" ]]; then
            local repo_name=$(basename "$git_root")
            local git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            title="$repo_name${git_branch:+ ($git_branch)}"
        fi
    fi
    title=${title:-$(basename "$PWD")}
    printf '\033]0;%s\007' "$title"
}

if [[ -n "$ZSH_VERSION" ]]; then
    autoload -U add-zsh-hook
    add-zsh-hook chpwd set_wezterm_title
    add-zsh-hook precmd set_wezterm_title
else
    PROMPT_COMMAND="set_wezterm_title; $PROMPT_COMMAND"
fi
set_wezterm_title

# Load Local Secrets & Machine Specifics (Last to allow overrides)
[ -f ~/.zshrc_local ] && source ~/.zshrc_local

# --- Modern Tools Configuration ---

# Zoxide (Smart cd)
if command -v zoxide >/dev/null; then
  eval "$(zoxide init zsh)"
  alias cd="z"
fi

# Eza (Modern ls)
if command -v eza >/dev/null; then
  alias ls="eza --icons --git"
  alias ll="eza -l --icons --git --no-user"
  alias la="eza -la --icons --git"
  alias lt="eza --tree --level=2 --icons"
fi

# Bat (Modern cat)
if command -v bat >/dev/null; then
  export BAT_THEME="tokyonight_day"
  alias cat="bat"
fi

# Tealdeer (tldr)
if command -v tldr >/dev/null; then
  alias help="tldr"
fi

# --- Yazi (File Manager) ---
# Wrapper to change directory on exit
function y() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
	yazi "$@" --cwd-file="$tmp"
	if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
		builtin cd -- "$cwd"
	fi
	rm -f -- "$tmp"
}

# --- FZF (Fuzzy Finder) Configuration ---
# Use fd instead of find (respects .gitignore, faster)
export FZF_DEFAULT_COMMAND="fd --type f --strip-cwd-prefix --hidden --follow --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fd --type d --strip-cwd-prefix --hidden --follow --exclude .git"

# Previews (requires bat and eza)
# Ctrl+T: Preview file content
export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always {}' --bind 'ctrl-/:change-preview-window(down|hidden|)'"
# Alt+C: Preview directory tree
export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"

# --- Safety ---
# Use trash-cli to delete files safely
if command -v trash >/dev/null; then
  alias del="trash"
fi
