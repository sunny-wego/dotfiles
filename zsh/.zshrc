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

    # fzf-tab smart previews
    if [[ -n "$ZSH_VERSION" ]]; then
        # Git preview: branch history or file diffs
        zstyle ':fzf-tab:complete:git*:*' fzf-preview \
            'if [ -f "$word" ]; then
                git diff --color=always "$word" | delta || bat --color=always "$word"
            else
                git log --oneline --graph --color=always "$word" 2>/dev/null || git show --color=always "$word" 2>/dev/null | delta
            fi'
        zstyle ':fzf-tab:complete:git*:*' fzf-flags --preview-window=right:60%

        # Directory preview: eza tree (for cd and zoxide)
        zstyle ':fzf-tab:complete:(cd|z|zi):*' fzf-preview 'eza --tree --level=2 --icons --color=always $realpath | head -200'
        zstyle ':fzf-tab:complete:(cd|z|zi):*' fzf-flags --preview-window=right:50%

        # Process preview: ps details
        zstyle ':fzf-tab:complete:(kill|ps):*' fzf-preview \
            '[[ $word =~ ^[0-9]+$ ]] && ps -p $word -o comm,pcpu,pmem,args'
        zstyle ':fzf-tab:complete:(kill|ps):*' fzf-flags --preview-window=down:3:wrap
    fi

    [ -f ~/.config/fzf-tab/fzf-tab.plugin.zsh ] && source ~/.config/fzf-tab/fzf-tab.plugin.zsh
fi

# FNM (Fast Node Manager)
command -v fnm >/dev/null && eval "$(fnm env --use-on-cd --shell zsh)"

# Zoxide (Smart cd)
if command -v zoxide >/dev/null; then
    export _ZO_DOCTOR=0
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

# Previews for CTRL-T
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

    # OSC 0: Set window title
    printf '\033]0;%s\007' "$title"

    # OSC 7: Report current working directory (required for CWD preservation on splits)
    printf '\033]7;file://%s%s\007' "${HOST:-$(hostname)}" "$PWD"
}

# Transient Prompt (Shrink previous prompt after Enter)
if command -v starship >/dev/null; then
  function starship_accept-line() {
    # If buffer is empty, just accept
    if [[ -z "$BUFFER" ]]; then
      zle .accept-line
      return
    fi

    # Save current prompt to restore it for the next line
    local saved_prompt=$PROMPT
    local saved_rprompt=$RPROMPT

    # Set minimal prompt for the line being accepted
    PROMPT=$(starship module character)
    RPROMPT=""
    zle reset-prompt

    # Restore prompt variables so the NEXT line starts with full info
    PROMPT=$saved_prompt
    RPROMPT=$saved_rprompt

    # Execute the command
    zle .accept-line
  }
  zle -N accept-line starship_accept-line
fi


autoload -U add-zsh-hook
add-zsh-hook chpwd set_wezterm_title
add-zsh-hook precmd set_wezterm_title

# wgd (cached for speed - regenerate with: wgd init > ~/.cache/wgd-init.zsh)
_wgd_cache="$HOME/.cache/wgd-init.zsh"
if [[ ! -f "$_wgd_cache" ]] || [[ $(command -v wgd) -nt "$_wgd_cache" ]]; then
    mkdir -p "$HOME/.cache"
    wgd init > "$_wgd_cache"
fi
source "$_wgd_cache"

# --- Claude Code: second account ------------------------------------------
# The primary account uses ~/.claude (credentials in the macOS Keychain). The
# secondary account uses an isolated config dir whose credentials live in a file
# (<dir>/.credentials.json), so both accounts can be logged in and run at the
# same time. One-time setup: ~/dotfiles/scripts/claude-account-setup.sh
export CLAUDE_ALT_DIR="${CLAUDE_ALT_DIR:-$HOME/.claude-alt}"
# Run Claude Code as the secondary account.
claude-alt() { CLAUDE_CONFIG_DIR="$CLAUDE_ALT_DIR" command claude "$@"; }
# Sync the secondary account's MCP servers from the declarative manifest.
claude-alt-mcp() {
  CLAUDE_CONFIG_DIR="$CLAUDE_ALT_DIR" node "$HOME/dotfiles/scripts/mcp-sync.mjs" \
    "${1:-apply}" --agent claude --state "$CLAUDE_ALT_DIR/.mcp-sync-state.json" "${@:2}"
}

# --- Claude Code: least-loaded account picker --------------------------------
# `claude` auto-selects the freer account so you never pick by hand. The two
# accounts both report to herdr as "claude" and can't be told apart there, so
# the picker keeps its own tally of live sessions (one marker per shell, named
# by PID and reaped when that PID dies). It routes to whichever account has
# fewer live sessions; ties prefer the primary, so a lone session lands on
# primary (home base) and only overflow spreads to the alt account.
#   Force an account:  CLAUDE_ACCOUNT=primary|alt claude ...   (or use `claude-alt`)
#   Auto-pinned to primary: non-interactive (-p / piped / $CI) and resume
#   (-c/--continue/--resume), so background work and the fleet stay on one account.
#   Marker dir override (tests): CLAUDE_PICKER_DIR
# >>> claude-picker >>>
_claude_balance() {                 # -> primary|alt, by live-session count
  emulate -L zsh
  local picker_dir="${CLAUDE_PICKER_DIR:-$HOME/.cache/claude-picker}"
  mkdir -p "$picker_dir"
  local f pid n; typeset -A counts=( primary 0 alt 0 )
  for f in "$picker_dir"/*(N.); do
    pid="${f:t}"
    if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
      n="$(<"$f")"; [[ -n "$n" ]] && (( counts[$n]++ ))
    else
      rm -f "$f"                    # reap dead session marker
    fi
  done
  (( counts[alt] < counts[primary] )) && { print -r -- alt; return; }
  print -r -- primary
}

_claude_pick_account() {            # -> primary|alt, honouring overrides + guards
  emulate -L zsh
  [[ -n "$CLAUDE_ACCOUNT" ]]                && { print -r -- "$CLAUDE_ACCOUNT"; return; }
  [[ -d "$CLAUDE_ALT_DIR" ]]                || { print -r -- primary; return; }
  [[ -t 0 && -t 1 && -z "$CI" ]]            || { print -r -- primary; return; }
  local a; for a in "$@"; do
    case "$a" in -p|--print|-c|--continue|--resume) print -r -- primary; return ;; esac
  done
  _claude_balance
}

claude() {
  emulate -L zsh
  local picker_dir="${CLAUDE_PICKER_DIR:-$HOME/.cache/claude-picker}"
  local acct; acct="$(_claude_pick_account "$@")"
  [[ "$acct" == alt ]] || acct=primary          # normalise unknown -> primary
  mkdir -p "$picker_dir"; print -r -- "$acct" > "$picker_dir/$$"
  [[ -t 2 ]] && print -u2 -r -- "claude → account: $acct"
  if [[ "$acct" == alt ]]; then
    CLAUDE_CONFIG_DIR="$CLAUDE_ALT_DIR" command claude "$@"
  else
    env -u CLAUDE_CONFIG_DIR claude "$@"         # unset -> primary uses the Keychain
  fi
  local rc=$?
  rm -f "$picker_dir/$$" 2>/dev/null
  return $rc
}
# <<< claude-picker <<<

# Load local overrides (Secrets, machine-specific)
[ -f ~/.zshrc_local ] && source ~/.zshrc_local
