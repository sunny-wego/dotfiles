# --- 1. Environment & Path ---

# Homebrew Initialization (Cached for speed)
if [[ -z "$BREW_PREFIX" ]]; then
    if [[ -d "/opt/homebrew" ]]; then
        export BREW_PREFIX="/opt/homebrew"
    elif [[ -d "/home/linuxbrew/.linuxbrew" ]]; then
        export BREW_PREFIX="/home/linuxbrew/.linuxbrew"
    fi
fi

if [[ -n "$BREW_PREFIX" ]]; then
    eval "$($BREW_PREFIX/bin/brew shellenv)"
fi

# Path management
export PATH="$HOME/.local/bin:$PATH"

# --- 2. Zsh Core Settings ---

# History
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000

# Options
setopt INC_APPEND_HISTORY    # append commands as they’re executed
setopt SHARE_HISTORY         # share commands between all sessions
setopt HIST_IGNORE_ALL_DUPS  # don’t keep duplicate commands
setopt HIST_REDUCE_BLANKS    # trim unnecessary spaces
setopt HIST_VERIFY           # show command before running from history

# Completions (Optimized with caching)
fpath=(~/.zsh/completions $fpath)
autoload -U compinit
if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qN.m-1) ]]; then
    compinit -C
else
    compinit
fi

# --- 3. Plugin & Tool Initialization ---

# Syntax Highlighting
if [[ -n "$BREW_PREFIX" && -f "$BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
    source "$BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
elif [[ -f "/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
    source "/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi

# FZF initialization
if command -v fzf >/dev/null; then
    source <(fzf --zsh)
    [ -f ~/.config/fzf-tab/fzf-tab.plugin.zsh ] && source ~/.config/fzf-tab/fzf-tab.plugin.zsh
fi

# FNM (Fast Node Manager)
command -v fnm >/dev/null && eval "$(fnm env --use-on-cd --shell zsh)"

# Zoxide (Smart cd)
if command -v zoxide >/dev/null; then
    eval "$(zoxide init zsh)"
    alias cd="z"
fi

# McFly (Better history search)
command -v mcfly >/dev/null && eval "$(mcfly init zsh)"

# Starship (Prompt) - Load last to ensure clean UI
command -v starship >/dev/null && eval "$(starship init zsh)"

# --- 4. Theme Integration (Tokyo Night Day) ---

# Eza Colors
export EZA_COLORS="di=34:ln=35:so=32:pi=33:ex=31:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=30;42:st=37;44:ur=34:uw=35:ux=31:ue=31:gr=32:gw=35:gx=31:tr=33:tw=35:tx=31:te=31:da=34"

# FZF Colors
export FZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS \
  --color=fg:#3760bf,bg:-1,hl:#b15c00 \
  --color=fg+:#3760bf,bg+:#cfd0d7,hl+:#b15c00 \
  --color=info:#8c6c3e,prompt:#2e7de9,pointer:#9854f1 \
  --color=marker:#587539,spinner:#9854f1,header:#2e7de9"

# --- 5. Aliases & Functions ---

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
command -v tldr >/dev/null && alias help="tldr"

# Trash-cli
command -v trash >/dev/null && alias del="trash"

# Yazi (File Manager)
function y() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}

# --- 6. FZF Advanced Configuration ---

if command -v fd >/dev/null; then
    export FZF_DEFAULT_COMMAND="fd --type f --strip-cwd-prefix --hidden --follow --exclude .git"
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND="fd --type d --strip-cwd-prefix --hidden --follow --exclude .git"
fi

# Previews
export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always {}' --bind 'ctrl-/:change-preview-window(down|hidden|)'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"

# --- 7. Terminal & System Integration ---

# WezTerm Title Logic
set_wezterm_title() {
    [[ "$TERM_PROGRAM" != "WezTerm" ]] && return
    local title
    if git rev-parse --git-dir >/dev/null 2>&1; then
        local repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
        local git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        title="$repo_name${git_branch:+ ($git_branch)}"
    fi
    title=${title:-$(basename "$PWD")}
    printf '\033]0;%s\007' "$title"
}

autoload -U add-zsh-hook
add-zsh-hook chpwd set_wezterm_title
add-zsh-hook precmd set_wezterm_title

# Load local overrides (Secrets, machine-specific)
[ -f ~/.zshrc_local ] && source ~/.zshrc_local
