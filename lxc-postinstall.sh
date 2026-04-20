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

# Ensure TERM is usable for whiptail/ncurses (e.g. xterm-ghostty has no terminfo in most containers)
if ! infocmp "$TERM" &>/dev/null 2>&1; then
    export TERM=xterm-256color
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die() {
    echo -e "${RED}[✗]${NC} $*" >&2
    exit 1
}

NON_INTERACTIVE=0
FORCE_INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --interactive) FORCE_INTERACTIVE=1 ;;
    esac
done

ui_has_whiptail() {
    command -v whiptail &>/dev/null && [[ -t 0 ]] && [[ -t 1 ]]
}

ui_enabled() {
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        return 1
    fi
    if [[ "$FORCE_INTERACTIVE" -eq 1 ]]; then
        return 0
    fi
    [[ -t 0 ]] && [[ -t 1 ]]
}

ui_input() {
    local title="$1" prompt="$2" default_value="$3" secret="${4:-0}" value
    if ui_has_whiptail; then
        if [[ "$secret" -eq 1 ]]; then
            value=$(whiptail --title "$title" --passwordbox "$prompt" 12 78 "$default_value" 3>&1 1>&2 2>&3) || die "Cancelled"
        else
            value=$(whiptail --title "$title" --inputbox "$prompt" 12 78 "$default_value" 3>&1 1>&2 2>&3) || die "Cancelled"
        fi
    else
        echo "$title"
        if [[ "$secret" -eq 1 ]]; then
            read -r -s -p "$prompt [$default_value]: " value
            echo ""
        else
            read -r -p "$prompt [$default_value]: " value
        fi
        [[ -z "$value" ]] && value="$default_value"
    fi
    printf '%s' "$value"
}

ui_confirm() {
    local title="$1" prompt="$2"
    if ui_has_whiptail; then
        whiptail --title "$title" --yesno "$prompt" 12 78
        return $?
    fi
    local answer
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

ui_select_containers() {
    local -a options=()
    local vmid status name
    while IFS='|' read -r vmid status name; do
        [[ -z "$vmid" ]] && continue
        options+=("$vmid" "$name [$status]" "OFF")
    done < <(pct list | awk 'NR>1 {print $1"|"$2"|"$4}')

    [[ ${#options[@]} -eq 0 ]] && return 0

    if ui_has_whiptail; then
        local selected
        selected=$(whiptail --title "Select Containers" --checklist "Select target CTIDs" 20 90 10 "${options[@]}" 3>&1 1>&2 2>&3) || return 0
        selected=${selected//\"/}
        printf '%s\n' $selected
    else
        warn "Available containers:"
        pct list
        local ids
        read -r -p "Enter CTIDs separated by spaces: " ids
        printf '%s\n' $ids
    fi
}

run_for_selected_containers() {
    local -a selected_ctids=("$@")
    local script_src="$SCRIPT_DIR/lxc-postinstall.sh"
    local tmp_script=""
    local tmp_env

    if [[ ! -f "$script_src" ]]; then
        tmp_script=$(mktemp)
        cat "${BASH_SOURCE[0]}" >"$tmp_script"
        script_src="$tmp_script"
    fi

    tmp_env=$(mktemp)

    cat >"$tmp_env" <<EOF
TIMEZONE=$TIMEZONE
LOCALE=$LOCALE
TS_AUTHKEY=$TS_AUTHKEY
PROXMOX_HOST=$PROXMOX_HOST
PROXMOX_USER=$PROXMOX_USER
PROXMOX_TOKEN_NAME=$PROXMOX_TOKEN_NAME
PROXMOX_TOKEN_VALUE=$PROXMOX_TOKEN_VALUE
EOF

    for ctid in "${selected_ctids[@]}"; do
        [[ -z "$ctid" ]] && continue
        info "Configuring container CTID $ctid..."
        if ! pct status "$ctid" 2>/dev/null | grep -q 'status: running'; then
            warn "CTID $ctid is not running, skipping."
            continue
        fi

        pct push "$ctid" "$script_src" /root/lxc-postinstall.sh
        pct push "$ctid" "$tmp_env" /root/.env
        pct exec "$ctid" -- bash /root/lxc-postinstall.sh --non-interactive ||
            warn "Setup failed in CTID $ctid"
    done

    rm -f "$tmp_env"
    [[ -n "$tmp_script" ]] && rm -f "$tmp_script"
}

save_env() {
    cat >"$SCRIPT_DIR/.env" <<EOF
TIMEZONE=$TIMEZONE
LOCALE=$LOCALE
TS_AUTHKEY=$TS_AUTHKEY
PROXMOX_HOST=$PROXMOX_HOST
PROXMOX_USER=$PROXMOX_USER
PROXMOX_TOKEN_NAME=$PROXMOX_TOKEN_NAME
PROXMOX_TOKEN_VALUE=$PROXMOX_TOKEN_VALUE
EOF
    info "Saved settings to $SCRIPT_DIR/.env"
}

run_interactive_setup() {
    TIMEZONE=$(ui_input "Timezone" "Enter timezone" "$TIMEZONE")
    LOCALE=$(ui_input "Locale" "Enter locale" "$LOCALE")
    TS_AUTHKEY=$(ui_input "Tailscale" "Enter TS_AUTHKEY (leave empty to skip join)" "$TS_AUTHKEY" 1)
    PROXMOX_HOST=$(ui_input "Proxmox" "Enter PROXMOX_HOST" "$PROXMOX_HOST")
    PROXMOX_USER=$(ui_input "Proxmox" "Enter PROXMOX_USER" "$PROXMOX_USER")
    PROXMOX_TOKEN_NAME=$(ui_input "Proxmox" "Enter PROXMOX_TOKEN_NAME" "$PROXMOX_TOKEN_NAME")
    PROXMOX_TOKEN_VALUE=$(ui_input "Proxmox" "Enter PROXMOX_TOKEN_VALUE" "$PROXMOX_TOKEN_VALUE" 1)

    if ui_confirm "Save Defaults" "Save these settings as defaults in .env for future runs?"; then
        save_env
    fi
}

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
    debian | ubuntu | linuxmint) apt-get install -y "$@" ;;
    arch | manjaro) pacman -S --noconfirm "$@" ;;
    fedora) dnf install -y "$@" ;;
    *) die "Unsupported distro: $DISTRO" ;;
    esac
}

# ── INTERACTIVE SETUP (optional) ─────────────────────────────────────────────
if ui_enabled; then
    # Ensure whiptail is available for TUI dialogs
    if ! command -v whiptail &>/dev/null; then
        case "$DISTRO" in
        debian | ubuntu | linuxmint) apt-get update -qq && apt-get install -y whiptail ;;
        arch | manjaro) pacman -S --noconfirm libnewt ;;
        fedora) dnf install -y newt ;;
        esac
    fi

    run_interactive_setup

    if command -v pct &>/dev/null && [[ -d /etc/pve ]]; then
        if ui_confirm "Target Mode" "Detected Proxmox host. Configure selected containers now?"; then
            mapfile -t TARGET_CTIDS < <(ui_select_containers)
            if [[ ${#TARGET_CTIDS[@]} -gt 0 ]]; then
                run_for_selected_containers "${TARGET_CTIDS[@]}"
                info "Container batch setup complete."
                exit 0
            fi
            warn "No containers selected, continuing on current system."
        fi
    fi
fi

# ── 1. SYSTEM UPDATE ──────────────────────────────────────────────────────────
info "Updating system packages..."
case "$DISTRO" in
debian | ubuntu | linuxmint)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -o Dpkg::Options::="--force-confold"
    ;;
arch | manjaro) pacman -Syu --noconfirm ;;
fedora) dnf upgrade -y ;;
esac

# ── 2. BASE PACKAGES ──────────────────────────────────────────────────────────
info "Installing base packages..."
case "$DISTRO" in
debian | ubuntu | linuxmint)
    pkg_install \
        curl wget git micro fish fastfetch \
        htop btop net-tools dnsutils tree \
        unzip tar ca-certificates gnupg lsb-release \
        build-essential procps locales \
        trash-cli python3 python3-pip python3-venv
    ;;
arch | manjaro)
    pkg_install curl wget git micro fish fastfetch htop btop \
        net-tools unzip tar base-devel tree trash-cli python python-pip
    ;;
fedora)
    pkg_install curl wget git micro fish fastfetch htop btop \
        net-tools unzip tar gcc tree trash-cli python3 python3-pip
    ;;
esac

# ── 3. UV (Python package manager) ───────────────────────────────────────────
if ! command -v uv &>/dev/null; then
    info "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
else
    info "uv already present: $(uv --version)"
fi
export PATH="$HOME/.local/bin:$PATH"

# ── 4. NODE.JS (LTS) ──────────────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
    info "Installing Node.js LTS..."
    case "$DISTRO" in
    debian | ubuntu | linuxmint)
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y nodejs
        ;;
    arch | manjaro) pkg_install nodejs npm ;;
    fedora) dnf install -y nodejs npm ;;
    esac
else
    info "Node.js already present: $(node -v)"
fi

# ── 5. TAILSCALE ──────────────────────────────────────────────────────────────
info "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

if [[ -n "$TS_AUTHKEY" ]]; then
    if tailscale ip -4 &>/dev/null || tailscale ip -6 &>/dev/null; then
        info "Already connected to Tailnet, skipping join."
    else
        info "Joining Tailnet..."
        tailscale up --authkey="$TS_AUTHKEY" --accept-routes
    fi
    info "Enabling Tailscale SSH..."
    tailscale set --ssh
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
        -o "$LINUTIL_TMP/linutil" 2>/dev/null ||
        curl -fsSL "https://github.com/ChrisTitusTech/linutil/releases/latest/download/linutil" \
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
if [[ -d "$PMCP_DIR/.git" ]]; then
    info "ProxmoxMCP-Plus already present, updating..."
    git -C "$PMCP_DIR" pull --ff-only
elif [[ -d "$PMCP_DIR" ]]; then
    die "$PMCP_DIR exists but is not a git repository"
else
    git clone https://github.com/rodaddy/ProxmoxMCP-Plus.git "$PMCP_DIR"
fi
cd "$PMCP_DIR"
uv venv
uv pip install -e ".[dev]"
mkdir -p proxmox-config

if [[ ! -f "$PMCP_DIR/proxmox-config/config.json" ]]; then
    cat >"$PMCP_DIR/proxmox-config/config.json" <<PMCPEOF
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
else
    info "ProxmoxMCP config.json already exists, preserving."
fi
cd /

# Claude Code MCP config (merge, don't overwrite)
CLAUDE_MCP_DIR="/root/.config/Claude"
CLAUDE_MCP_FILE="$CLAUDE_MCP_DIR/claude_desktop_config.json"
mkdir -p "$CLAUDE_MCP_DIR"
PMCP_ENTRY=$(
    cat <<MCPEOF
{
    "command": "${PMCP_DIR}/.venv/bin/python",
    "args": ["-m", "proxmox_mcp.server"],
    "env": {
        "PYTHONPATH": "${PMCP_DIR}/src",
        "PROXMOX_MCP_CONFIG": "${PMCP_DIR}/proxmox-config/config.json"
    }
}
MCPEOF
)
if [[ -f "$CLAUDE_MCP_FILE" ]] && command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
entry = json.loads(sys.argv[1])
try:
    with open(sys.argv[2]) as f:
        cfg = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    cfg = {}
cfg.setdefault('mcpServers', {})['ProxmoxMCP-Plus'] = entry
with open(sys.argv[2], 'w') as f:
    json.dump(cfg, f, indent=4)
" "$PMCP_ENTRY" "$CLAUDE_MCP_FILE"
else
    cat >"$CLAUDE_MCP_FILE" <<MCPEOF2
{
    "mcpServers": {
        "ProxmoxMCP-Plus": $PMCP_ENTRY
    }
}
MCPEOF2
fi

warn "ProxmoxMCP: fill in token at ${PMCP_DIR}/proxmox-config/config.json"

# ── 11. TIMEZONE ──────────────────────────────────────────────────────────────
info "Setting timezone: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" 2>/dev/null ||
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

# ── 12. LOCALE ────────────────────────────────────────────────────────────────
info "Configuring locale: $LOCALE"
case "$DISTRO" in
debian | ubuntu | linuxmint)
    sed -i "s/^# *${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen 2>/dev/null || true
    grep -Fqx "${LOCALE} UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >>/etc/locale.gen
    locale-gen
    update-locale LANG="$LOCALE"
    ;;
arch | manjaro)
    sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
    locale-gen
    echo "LANG=${LOCALE}" >/etc/locale.conf
    ;;
fedora)
    localectl set-locale "LANG=${LOCALE}"
    ;;
esac

# ── 13. BASH ENVIRONMENT ──────────────────────────────────────────────────────
info "Configuring bash environment..."
BASHRC_MARKER_START="# >>> lxc-postinstall >>>"
BASHRC_CONTENT_PROBE="export EDITOR=micro"
if ! grep -Fqx "$BASHRC_MARKER_START" /root/.bashrc && ! grep -Fq "$BASHRC_CONTENT_PROBE" /root/.bashrc; then
    cat >>/root/.bashrc <<'EOF'

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
EOF
else
    info "Bash environment block already present, skipping append."
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
echo "  Skill mgr:       skm"
echo ""
warn "Reopen shell to activate bash config + locale"
