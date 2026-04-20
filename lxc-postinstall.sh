#!/usr/bin/env bash
# Post-install script for PVE LXC containers (root)
set -euo pipefail

# ── LOAD .env (same dir as script) ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

# ── CONFIG (env vars override defaults) ──────────────────────────────────────
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
LOCALE="${LOCALE:-de_DE.UTF-8}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_TOKEN_NAME="${PROXMOX_TOKEN_NAME:-mcp-token}"
PROXMOX_TOKEN_VALUE="${PROXMOX_TOKEN_VALUE:-}"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
die()     { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Must run as root"

# ── DETECT DISTRO ─────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    DISTRO="${ID:-unknown}"
else
    die "Cannot detect distro"
fi

pkg_install() {
    case "$DISTRO" in
        debian|ubuntu|linuxmint) apt-get install -y "$@" ;;
        arch|manjaro)            pacman -S --noconfirm "$@" ;;
        fedora)                  dnf install -y "$@" ;;
        *)                       die "Unsupported distro: $DISTRO" ;;
    esac
}

# ── 1. SYSTEM UPDATE ──────────────────────────────────────────────────────────
info "Updating system packages..."
case "$DISTRO" in
    debian|ubuntu|linuxmint)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get upgrade -y -o Dpkg::Options::="--force-confold"
        ;;
    arch|manjaro) pacman -Syu --noconfirm ;;
    fedora)       dnf upgrade -y ;;
esac

# ── 2. BASE PACKAGES ──────────────────────────────────────────────────────────
info "Installing base packages..."
case "$DISTRO" in
    debian|ubuntu|linuxmint)
        pkg_install \
            curl wget git micro fish fastfetch \
            htop btop net-tools dnsutils tree \
            unzip tar ca-certificates gnupg lsb-release \
            build-essential procps locales \
            trash-cli python3 python3-pip python3-venv
        ;;
    arch|manjaro)
        pkg_install curl wget git micro fish fastfetch htop btop \
            net-tools unzip tar base-devel tree trash-cli python python-pip
        ;;
    fedora)
        pkg_install curl wget git micro fish fastfetch htop btop \
            net-tools unzip tar gcc tree trash-cli python3 python3-pip
        ;;
esac

# ── 3. UV (Python package manager) ───────────────────────────────────────────
info "Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# ── 4. NODE.JS (LTS) ──────────────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
    info "Installing Node.js LTS..."
    case "$DISTRO" in
        debian|ubuntu|linuxmint)
            curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
            apt-get install -y nodejs
            ;;
        arch|manjaro)  pkg_install nodejs npm ;;
        fedora)        dnf install -y nodejs npm ;;
    esac
else
    info "Node.js already present: $(node -v)"
fi

# ── 5. TAILSCALE ──────────────────────────────────────────────────────────────
info "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

if [[ -n "$TS_AUTHKEY" ]]; then
    info "Joining Tailnet..."
    tailscale up --authkey="$TS_AUTHKEY" --accept-routes
else
    warn "Tailscale installed but not joined. Run: tailscale up"
fi

# ── 6. NPM GLOBAL PACKAGES ────────────────────────────────────────────────────
info "Installing npm global packages..."
npm install -g skill-manager

# ── 7. LINUTIL ────────────────────────────────────────────────────────────────
info "Installing linutil..."
if ! command -v linutil &>/dev/null; then
    LINUTIL_TMP=$(mktemp -d)
    curl -fsSL "https://github.com/TuxLux40/linutil/releases/latest/download/linutil" \
        -o "$LINUTIL_TMP/linutil" 2>/dev/null \
    || curl -fsSL "https://github.com/ChrisTitusTech/linutil/releases/latest/download/linutil" \
        -o "$LINUTIL_TMP/linutil"
    install -m 755 "$LINUTIL_TMP/linutil" /usr/local/bin/linutil
    rm -rf "$LINUTIL_TMP"
fi

# ── 8. GITHUB COPILOT CLI ─────────────────────────────────────────────────────
info "Installing GitHub Copilot CLI..."
curl -fsSL https://gh.io/copilot-install | bash

# ── 9. CLAUDE CODE ────────────────────────────────────────────────────────────
info "Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash

# ── 10. PROXMOXMCP-PLUS ───────────────────────────────────────────────────────
info "Installing ProxmoxMCP-Plus..."
PMCP_DIR="/opt/ProxmoxMCP-Plus"
git clone https://github.com/rodaddy/ProxmoxMCP-Plus.git "$PMCP_DIR"
cd "$PMCP_DIR"
uv venv
uv pip install -e ".[dev]"
mkdir -p proxmox-config

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
cd /

# Claude Code MCP config
CLAUDE_MCP_DIR="/root/.config/Claude"
mkdir -p "$CLAUDE_MCP_DIR"
cat > "$CLAUDE_MCP_DIR/claude_desktop_config.json" << MCPEOF
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

warn "ProxmoxMCP: fill in token at ${PMCP_DIR}/proxmox-config/config.json"

# ── 11. TIMEZONE ──────────────────────────────────────────────────────────────
info "Setting timezone: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" 2>/dev/null \
    || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

# ── 12. LOCALE ────────────────────────────────────────────────────────────────
info "Configuring locale: $LOCALE"
case "$DISTRO" in
    debian|ubuntu|linuxmint)
        sed -i "s/^# *${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen 2>/dev/null || true
        echo "${LOCALE} UTF-8" >> /etc/locale.gen
        locale-gen
        update-locale LANG="$LOCALE"
        ;;
    arch|manjaro)
        sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
        locale-gen
        echo "LANG=${LOCALE}" > /etc/locale.conf
        ;;
    fedora)
        localectl set-locale "LANG=${LOCALE}"
        ;;
esac

# ── 13. BASH ENVIRONMENT ──────────────────────────────────────────────────────
info "Configuring bash environment..."
cat >> /root/.bashrc << 'EOF'

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
alias ts='tailscale'
alias sm='skill-manager'
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
EOF

# ── 14. SSH: KEY-ONLY AUTH ────────────────────────────────────────────────────
if [[ -f /etc/ssh/sshd_config ]]; then
    info "Hardening SSH (key-only auth)..."
    sed -i \
        -e 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' \
        -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || true
    warn "SSH password auth disabled — ensure pubkey is in /root/.ssh/authorized_keys first!"
fi

# ── DONE ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        LXC post-install complete             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  Tailscale:       tailscale up [--authkey=...]"
echo "  ProxmoxMCP cfg:  ${PMCP_DIR}/proxmox-config/config.json"
echo "  Claude Code:     claude"
echo "  Linutil:         linutil"
echo "  Skill mgr:       skill-manager"
echo ""
warn "Reopen shell to activate bash config + locale"
