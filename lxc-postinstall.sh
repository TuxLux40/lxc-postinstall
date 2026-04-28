#!/usr/bin/env bash
# Proxmox LXC post-install — run as root inside the container
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then set -a; source "$SCRIPT_DIR/.env"; set +a; fi

# ── CONFIG ───────────────────────────────────────────────────────────────────
PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_TOKEN_NAME="${PROXMOX_TOKEN_NAME:-mcp-token}"
PROXMOX_TOKEN_VALUE="${PROXMOX_TOKEN_VALUE:-}"

# ── COLORS + LOGGING ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

LOGFILE="/var/log/lxc-postinstall.log"
: > "$LOGFILE"

info() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()  { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }

# q: run a command, log output, print last 5 lines on failure
q() {
    if ! "$@" >>"$LOGFILE" 2>&1; then
        echo -e "  ${RED}✗ Failed:${NC} $*"
        tail -5 "$LOGFILE" | sed 's/^/    /' >&2
        return 1
    fi
}

TOTAL_STEPS=10
CURRENT_STEP=0
step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local bar_len=30
    local filled=$((pct * bar_len / 100))
    local empty=$((bar_len - filled))
    local bar="${GREEN}"
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    bar+="${DIM}"
    for ((i = 0; i < empty; i++)); do bar+="░"; done
    bar+="${NC}"
    echo ""
    echo -e "  ${BOLD}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${BLUE}$*${NC}  ${bar} ${DIM}${pct}%${NC}"
}

has() { command -v "$1" &>/dev/null; }
ver() { "$@" 2>/dev/null || echo "not installed"; }

# ── PRE-FLIGHT ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must run as root"

. /etc/os-release
DISTRO="${ID:-}"
DISTRO_VER="${PRETTY_NAME:-$ID}"
[[ -z "$DISTRO" ]] && die "Cannot detect distro from /etc/os-release"
info "Distro: $DISTRO"

pkg() {
    case "$DISTRO" in
    debian|ubuntu|linuxmint) q apt-get install -y --no-install-recommends "$@" ;;
    arch|manjaro)             q pacman -S --noconfirm --needed "$@" ;;
    fedora)                   q dnf install -y "$@" ;;
    *) die "Unsupported distro: $DISTRO" ;;
    esac
}

# ── 1. REPOS + SYSTEM UPDATE ─────────────────────────────────────────────────
step "Repos and system update"
case "$DISTRO" in
debian|ubuntu|linuxmint)
    rm -f /etc/apt/sources.list.d/nodesource.list \
          /etc/apt/sources.list.d/github-cli.list \
          /etc/apt/keyrings/githubcli.gpg
    q apt-get update -qq
    q apt-get upgrade -y -o Dpkg::Options::="--force-confold"
    ;;
arch|manjaro)
    q pacman -Syu --noconfirm
    ;;
fedora)
    q dnf upgrade -y
    ;;
esac
info "System updated"

# ── 2. BASE PACKAGES ─────────────────────────────────────────────────────────
step "Base packages"
case "$DISTRO" in
debian|ubuntu|linuxmint)
    pkg curl wget git micro fish htop btop net-tools dnsutils tree bat \
        unzip tar ca-certificates gnupg lsb-release build-essential procps \
        trash-cli python3 python3-venv nodejs gh
    if ! has fastfetch; then
        { curl -sLo /tmp/ff.deb \
            https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-amd64.deb \
        && dpkg -i /tmp/ff.deb; } >>"$LOGFILE" 2>&1 || warn "fastfetch install failed (non-critical)"
        rm -f /tmp/ff.deb
    fi
    ;;
arch|manjaro)
    pkg curl wget git micro fish fastfetch htop btop \
        net-tools unzip tar base-devel tree bat trash-cli python nodejs npm github-cli
    ;;
fedora)
    pkg curl wget git micro fish fastfetch htop btop \
        net-tools unzip tar gcc tree bat trash-cli python3 nodejs npm gh
    ;;
esac
info "Base packages installed"

mkdir -p /root/.config/fastfetch
cat > /root/.config/fastfetch/config.jsonc << 'FFEOF'
{
    "modules": [
        "title",
        "separator",
        "os",
        "host",
        "kernel",
        "uptime",
        "packages",
        "shell",
        "terminal",
        "cpu",
        "memory",
        "disk",
        "localip",
        "break",
        "colors"
    ]
}
FFEOF

# ── 3. UV ─────────────────────────────────────────────────────────────────────
step "uv (Python package manager)"
if ! has uv; then
    { curl -LsSf https://astral.sh/uv/install.sh | sh; } >>"$LOGFILE" 2>&1
    info "uv installed"
else
    info "uv already present"
fi
export PATH="$HOME/.local/bin:$PATH"

# ── 4. LINUTIL ────────────────────────────────────────────────────────────────
step "Linutil"
if ! has linutil; then
    { curl -fsSL "https://github.com/TuxLux40/linutil/releases/latest/download/linutil" \
        -o /tmp/linutil 2>/dev/null \
    || curl -fsSL "https://github.com/ChrisTitusTech/linutil/releases/latest/download/linutil" \
        -o /tmp/linutil; } >>"$LOGFILE" 2>&1
    install -m 755 /tmp/linutil /usr/local/bin/linutil
    rm -f /tmp/linutil
    info "linutil installed"
else
    info "linutil already present"
fi

# ── 5. NPM GLOBALS ────────────────────────────────────────────────────────────
step "npm global packages"
q npm install -g skill-manager
info "skill-manager (skm) installed"

# ── 6. COPILOT CLI ────────────────────────────────────────────────────────────
step "GitHub Copilot CLI"
q gh extension install github/gh-copilot --force
info "GitHub Copilot CLI installed"

# ── 7. CLAUDE CODE ────────────────────────────────────────────────────────────
step "Claude Code"
{ curl -fsSL https://claude.ai/install.sh | bash; } >>"$LOGFILE" 2>&1
info "Claude Code installed"

# ── 8. PROXMOXMCP-PLUS ────────────────────────────────────────────────────────
step "ProxmoxMCP-Plus"
PMCP_DIR="/opt/ProxmoxMCP-Plus"
if [[ -d "$PMCP_DIR/.git" ]]; then
    q git -C "$PMCP_DIR" pull --ff-only
    info "ProxmoxMCP-Plus updated"
elif [[ -d "$PMCP_DIR" ]]; then
    warn "$PMCP_DIR exists but is not a git repo — skipping"
else
    q git clone https://github.com/rodaddy/ProxmoxMCP-Plus.git "$PMCP_DIR"
    info "ProxmoxMCP-Plus cloned"
fi
(cd "$PMCP_DIR" && { [[ -d .venv ]] || q uv venv; } && q uv pip install -e .)
mkdir -p "$PMCP_DIR/proxmox-config"

if [[ ! -f "$PMCP_DIR/proxmox-config/config.json" ]]; then
    cat > "$PMCP_DIR/proxmox-config/config.json" << PMCPEOF
{
    "proxmox": {
        "host": "${PROXMOX_HOST:-YOUR_PROXMOX_HOST}",
        "port": 8006,
        "verify_ssl": false,
        "service": "PVE"
    },
    "auth": {
        "user": "${PROXMOX_USER:-root@pam}",
        "token_name": "${PROXMOX_TOKEN_NAME:-mcp-token}",
        "token_value": "${PROXMOX_TOKEN_VALUE:-FILL_IN_TOKEN_VALUE}"
    },
    "logging": {
        "level": "INFO",
        "file": "/var/log/proxmox-mcp.log"
    },
    "mcp": {
        "host": "127.0.0.1",
        "port": 8000,
        "transport": "STDIO"
    }
}
PMCPEOF
fi

mkdir -p /root/.config/Claude
if [[ ! -f /root/.config/Claude/claude_desktop_config.json ]]; then
cat > /root/.config/Claude/claude_desktop_config.json << MCPEOF
{
    "mcpServers": {
        "ProxmoxMCP-Plus": {
            "command": "${PMCP_DIR}/.venv/bin/python",
            "args": ["-m", "proxmox_mcp.server"],
            "env": {
                "PYTHONPATH": "${PMCP_DIR}/src",
                "PROXMOX_MCP_CONFIG": "${PMCP_DIR}/proxmox-config/config.json"
            }
        }
    }
}
MCPEOF
fi
warn "ProxmoxMCP: fill in token at $PMCP_DIR/proxmox-config/config.json"

# ── 9. AGENT INSTRUCTIONS ────────────────────────────────────────────────────
step "Agent instructions"
CT_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
CT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
NODE_VER=$(ver node --version)
UV_VER=$(ver uv --version)
NPM_VER=$(ver npm --version)
CLAUDE_VER=$(claude --version 2>/dev/null | head -1 || echo "not installed")

mkdir -p /root/.claude

cat > /root/.claude/CLAUDE.md << AGENTEOF
# Container Context

This is an LXC container running on Proxmox VE. Use this file for context when working inside this container.

## Identity

| Key      | Value                   |
| -------- | ----------------------- |
| Hostname | $CT_HOSTNAME            |
| IP       | $CT_IP                  |
| OS       | $DISTRO_VER             |
| Node.js  | $NODE_VER               |
| npm      | $NPM_VER                |
| uv       | $UV_VER                 |
| Claude   | $CLAUDE_VER             |

## Proxmox Host

| Key        | Value                          |
| ---------- | ------------------------------ |
| Host       | ${PROXMOX_HOST:-not configured} |
| User       | $PROXMOX_USER                  |
| Token name | $PROXMOX_TOKEN_NAME            |

## MCP Servers

### ProxmoxMCP-Plus
Manages the Proxmox VE host via API from inside this container.

- Repo: \`/opt/ProxmoxMCP-Plus\`
- Config: \`/opt/ProxmoxMCP-Plus/proxmox-config/config.json\`
- Venv: \`/opt/ProxmoxMCP-Plus/.venv\`
- Registered in: \`/root/.config/Claude/claude_desktop_config.json\`

## Installed Tools

| Tool           | Notes                                          |
| -------------- | ---------------------------------------------- |
| \`fish\`         | Interactive shell (type \`fish\` to enter)       |
| \`micro\`        | Default editor; aliased as \`vim\` and \`nano\`    |
| \`uv\`           | Python package manager (\`~/.local/bin/uv\`)     |
| \`claude\`       | Claude Code CLI (\`~/.local/bin/claude\`)        |
| \`skm\`          | Skill manager for Claude Code                  |
| \`gh copilot\`   | GitHub Copilot CLI                             |
| \`linutil\`      | Linux utility TUI (\`/usr/local/bin/linutil\`)  |
| \`fastfetch\`    | System info on login                           |
| \`btop\` / \`htop\`| Resource monitors                              |
| \`bat\`          | Syntax-highlighted cat (may be \`batcat\` here)  |
| \`trash\`        | Safe delete — \`rm\` is aliased to \`trash -v\`    |

## Key Paths

- Agent context (this file): \`/root/.claude/CLAUDE.md\` and \`/root/AGENTS.md\`
- Claude MCP config: \`/root/.config/Claude/claude_desktop_config.json\`
- ProxmoxMCP config: \`/opt/ProxmoxMCP-Plus/proxmox-config/config.json\`
- Bash config block: \`/root/.bashrc\` (guarded by \`# >>> lxc-postinstall >>>\`)
- Install log: \`/var/log/lxc-postinstall.log\`
- PATH includes \`~/.local/bin\`

## Project Initialization Guidance

When setting up project context for any new task, **investigate this container first** to
understand what it actually does. Do not assume from the hostname alone:

1. \`systemctl list-units --type=service --state=running 2>/dev/null\` — running services
2. \`ss -tlnp\` — open ports and what's listening
3. Contents of the working directory and any obvious config files
4. \`pip list\`, \`npm list -g\`, \`uv pip list\` — installed packages
5. \`crontab -l 2>/dev/null\` — scheduled jobs

Based on what you find, **recommend additional tools, MCP servers, and agent skills that are
NOT already installed** and are relevant to this container's actual workload. Do not repeat
tools already listed in the Installed Tools table above.

To discover agent skills: \`skm search <topic>\` (e.g. \`skm search email\`, \`skm search database\`).
Also search npm (\`npm search mcp <topic>\`) and GitHub for relevant MCP servers.

Always include in any generated project context file:
- What this container does (from your investigation, not the hostname)
- ProxmoxMCP-Plus MCP server is already registered and usable
- Python: use \`uv\`, not pip or virtualenv
- \`rm\` is aliased to \`trash -v\` — files go to \`~/.local/share/Trash\`, not deleted
- Default editor: \`micro\` (also aliased as \`vim\` / \`nano\`)
AGENTEOF

cp /root/.claude/CLAUDE.md /root/AGENTS.md
info "Agent instructions written to /root/.claude/CLAUDE.md and /root/AGENTS.md"

# ── 10. BASH ENVIRONMENT ──────────────────────────────────────────────────────
step "Bash environment"
if ! grep -Fq "# >>> lxc-postinstall >>>" /root/.bashrc 2>/dev/null; then
    cat >> /root/.bashrc << 'BASHEOF'

# >>> lxc-postinstall >>>

# ── colors & prompt ───────────────────────────────────────────────────────────
export TERM=xterm-256color
export CLICOLOR=1
PS1='\[\e[1;31m\]\u\[\e[0m\]@\[\e[1;34m\]\h\[\e[0m\]:\[\e[1;33m\]\w\[\e[0m\]\$ '

# ── history ───────────────────────────────────────────────────────────────────
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT="%F %T  "
shopt -s histappend
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# ── shell options ─────────────────────────────────────────────────────────────
shopt -s autocd cdspell checkwinsize globstar

# ── editor ────────────────────────────────────────────────────────────────────
export EDITOR=micro
export VISUAL=micro
alias vim='micro'
alias nano='micro'

# ── LS_COLORS ─────────────────────────────────────────────────────────────────
export LS_COLORS='no=00:fi=00:di=00;34:ln=01;36:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:ex=01;32:*.tar=01;31:*.tgz=01;31:*.zip=01;31:*.gz=01;31:*.bz2=01;31:*.deb=01;31:*.rpm=01;31:*.jpg=01;35:*.jpeg=01;35:*.gif=01;35:*.bmp=01;35:*.png=01;35:*.mp3=01;35:*.ogg=01;35:*.wav=01;35:*.xml=00;31:'

# ── man page colors ───────────────────────────────────────────────────────────
export LESS_TERMCAP_mb=$'\e[01;31m'
export LESS_TERMCAP_md=$'\e[01;31m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_so=$'\e[01;44;33m'
export LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_us=$'\e[01;32m'
export LESS='-R'

# ── ls variants ───────────────────────────────────────────────────────────────
alias ls='ls --color=always -Fh'
alias ll='ls -lah'
alias la='ls -A'
alias lx='ls -lXBh'
alias lk='ls -lSrh'
alias lt='ls -ltrh'
alias lr='ls -lRh'

# ── bat alias (Debian/Ubuntu install binary as batcat) ────────────────────────
command -v batcat &>/dev/null && alias bat='batcat'

# ── safe defaults ─────────────────────────────────────────────────────────────
alias rm='trash -v'
alias cp='cp -i'
alias mv='mv -i'
alias mkdir='mkdir -p'

# ── system ────────────────────────────────────────────────────────────────────
alias ps='ps auxf'
alias ping='ping -c 10'
alias openports='netstat -nape --inet'
alias mountedinfo='df -hT'
alias folders='du -h --max-depth=1'
alias tree='tree -CAhF --dirsfirst'
alias da='date "+%Y-%m-%d %A %T %Z"'

# ── navigation ────────────────────────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# ── archives ──────────────────────────────────────────────────────────────────
alias mktar='tar -cvf'
alias mkgz='tar -cvzf'
alias mkbz2='tar -cvjf'
alias untar='tar -xvf'
alias ungz='tar -xvzf'
alias unbz2='tar -xvjf'

# ── chmod ─────────────────────────────────────────────────────────────────────
alias mx='chmod a+x'
alias 755='chmod -R 755'
alias 644='chmod -R 644'

# ── tools ─────────────────────────────────────────────────────────────────────
alias g='git'
alias sm='skm'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ip='ip --color=auto'

# ── cd + auto-ls ──────────────────────────────────────────────────────────────
cd() { builtin cd "$@" && ls; }

# ── search helpers ────────────────────────────────────────────────────────────
h() { history | grep "$*"; }
p() { ps aux | grep "$*"; }
f() { find . | grep "$*"; }

# ── fastfetch on login ────────────────────────────────────────────────────────
command -v fastfetch &>/dev/null && fastfetch

# ── PATH additions ────────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"

# ── bash completion ───────────────────────────────────────────────────────────
[[ -f /usr/share/bash-completion/bash_completion ]] \
    && source /usr/share/bash-completion/bash_completion

# <<< lxc-postinstall <<<
BASHEOF
    info "Bash environment added"
else
    info "Bash environment already present, skipping"
fi

# ── DONE ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║         LXC post-install complete            ║${NC}"
echo -e "${GREEN}  ╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}Log:${NC} $LOGFILE"
echo ""
warn "Reopen shell to activate bash config"
warn "Fill in PROXMOX_TOKEN_VALUE at $PMCP_DIR/proxmox-config/config.json"

if [[ -s "$LOGFILE" ]]; then
    PASTE_URL=$(curl -fsSL -F "file=@${LOGFILE}" https://0x0.st 2>/dev/null) || true
    if [[ -n "${PASTE_URL:-}" ]]; then info "Log: ${PASTE_URL}"; else warn "Log upload failed"; fi
fi