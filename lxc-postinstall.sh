#!/usr/bin/env bash
# Proxmox LXC post-install — host-side orchestrator
# Runs on the Proxmox host, configures selected LXC containers via pct exec.
set -euo pipefail
export LC_ALL=C

# ── LOAD .env (same dir as script) ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

# ── CONFIG (env vars override defaults) ──────────────────────────────────────
TS_AUTHKEY="${TS_AUTHKEY:-}"
PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_TOKEN_NAME="${PROXMOX_TOKEN_NAME:-mcp-token}"
PROXMOX_TOKEN_VALUE="${PROXMOX_TOKEN_VALUE:-}"

# Ensure TERM is usable for whiptail/ncurses
if ! infocmp "$TERM" &>/dev/null 2>&1; then
    export TERM=xterm-256color
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

LOGFILE="/var/log/lxc-postinstall.log"
: >"$LOGFILE"

info() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
die() {
    echo -e "  ${RED}✗${NC} $*" >&2
    exit 1
}

TOTAL_STEPS=11
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

# ── PRE-FLIGHT ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must run as root"
command -v pct &>/dev/null || die "pct not found — this script runs on a Proxmox host"
[[ -d /etc/pve ]] || die "/etc/pve not found — not a Proxmox host"

if ! command -v whiptail &>/dev/null; then
    apt-get update -qq >>"$LOGFILE" 2>&1 || true
    apt-get install -y whiptail >>"$LOGFILE" 2>&1 || die "Failed to install whiptail"
fi

# ── UI HELPERS ───────────────────────────────────────────────────────────────
ui_input() {
    local title="$1" prompt="$2" default_value="$3" secret="${4:-0}" value
    if [[ "$secret" -eq 1 ]]; then
        value=$(whiptail --title "$title" --passwordbox "$prompt" 12 78 "$default_value" 3>&1 1>&2 2>&3) || die "Cancelled"
    else
        value=$(whiptail --title "$title" --inputbox "$prompt" 12 78 "$default_value" 3>&1 1>&2 2>&3) || die "Cancelled"
    fi
    printf '%s' "$value"
}

ui_confirm() {
    local title="$1" prompt="$2" no_text="${3:-No}" yes_text="${4:-Yes}"
    whiptail --title "$title" --yes-button "$yes_text" --no-button "$no_text" --yesno "$prompt" 20 78
    return $?
}

ui_select_containers() {
    local -a options=()
    local vmid status name
    while IFS='|' read -r vmid status name; do
        [[ -z "$vmid" ]] && continue
        options+=("$vmid" "$name [$status]" "OFF")
    done < <(pct list | awk 'NR>1 {print $1"|"$2"|"$NF}')

    [[ ${#options[@]} -eq 0 ]] && { warn "No containers found on this host"; return 1; }

    local selected
    selected=$(whiptail --title "Select Containers" --ok-button "Install" --cancel-button "Cancel" \
        --checklist "Select containers to configure (SPACE to toggle, ENTER to confirm):" 20 90 10 \
        "${options[@]}" 3>&1 1>&2 2>&3) || return 1
    selected=${selected//\"/}
    printf '%s\n' $selected
}

save_env() {
    cat >"$SCRIPT_DIR/.env" <<EOF
TS_AUTHKEY=$TS_AUTHKEY
PROXMOX_HOST=$PROXMOX_HOST
PROXMOX_USER=$PROXMOX_USER
PROXMOX_TOKEN_NAME=$PROXMOX_TOKEN_NAME
PROXMOX_TOKEN_VALUE=$PROXMOX_TOKEN_VALUE
EOF
    info "Saved settings to $SCRIPT_DIR/.env"
}

run_interactive_setup() {
    TS_AUTHKEY=$(ui_input "Tailscale" "Enter TS_AUTHKEY (leave empty to skip auto-join)" "$TS_AUTHKEY" 1)
    PROXMOX_HOST=$(ui_input "Proxmox" "Enter PROXMOX_HOST (IP or hostname)" "$PROXMOX_HOST")
    PROXMOX_USER=$(ui_input "Proxmox" "Enter PROXMOX_USER" "$PROXMOX_USER")
    PROXMOX_TOKEN_NAME=$(ui_input "Proxmox" "Enter PROXMOX_TOKEN_NAME" "$PROXMOX_TOKEN_NAME")
    PROXMOX_TOKEN_VALUE=$(ui_input "Proxmox" "Enter PROXMOX_TOKEN_VALUE" "$PROXMOX_TOKEN_VALUE" 1)

    if ui_confirm "Save Defaults" "Save these settings as defaults in .env for future runs?"; then
        save_env
    fi
}

# ── CONTAINER HELPERS (all run commands on $CTID via pct exec) ───────────────
CTID=""
DISTRO=""

in_ct() { pct exec "$CTID" -- "$@"; }

ct_quiet() {
    if ! pct exec "$CTID" -- "$@" >>"$LOGFILE" 2>&1; then
        echo -e "  ${RED}✗ Command failed in CTID $CTID:${NC} $1"
        tail -5 "$LOGFILE" | sed 's/^/    /' >&2
        return 1
    fi
}

ct_sh() { pct exec "$CTID" -- bash -c "$1" >>"$LOGFILE" 2>&1; }

ct_sh_quiet() {
    if ! pct exec "$CTID" -- bash -c "$1" >>"$LOGFILE" 2>&1; then
        echo -e "  ${RED}✗ Shell failed in CTID $CTID${NC}"
        tail -5 "$LOGFILE" | sed 's/^/    /' >&2
        return 1
    fi
}

ct_has() { pct exec "$CTID" -- sh -c "command -v $1 >/dev/null"; }
ct_test() { pct exec "$CTID" -- test "$@"; }

detect_ct_distro() {
    DISTRO=$(pct exec "$CTID" -- sh -c '. /etc/os-release && echo "$ID"')
    [[ -z "$DISTRO" ]] && die "Cannot detect distro in CTID $CTID"
}

ct_pkg_install() {
    case "$DISTRO" in
    debian | ubuntu | linuxmint) ct_quiet apt-get install -y "$@" ;;
    arch | manjaro) ct_quiet pacman -S --noconfirm "$@" ;;
    fedora) ct_quiet dnf install -y "$@" ;;
    *) die "Unsupported distro in CTID $CTID: $DISTRO" ;;
    esac
}

# ── INSTALL STEPS (operate on $CTID) ─────────────────────────────────────────
configure_container() {
    CTID="$1"
    CURRENT_STEP=0

    echo ""
    echo -e "${BOLD}${BLUE}══ Configuring CTID $CTID ══${NC}"
    if ! pct status "$CTID" 2>/dev/null | grep -q 'status: running'; then
        warn "CTID $CTID is not running, skipping."
        return 0
    fi

    detect_ct_distro
    info "Detected distro: $DISTRO"

    # 1. SYSTEM UPDATE
    step "Updating system packages"
    case "$DISTRO" in
    debian | ubuntu | linuxmint)
        ct_sh_quiet 'export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get upgrade -y -o Dpkg::Options::="--force-confold"'
        ;;
    arch | manjaro) ct_quiet pacman -Syu --noconfirm ;;
    fedora) ct_quiet dnf upgrade -y ;;
    esac
    info "System up to date"

    ct_has npm && { ct_sh 'npm update -g' && info "npm globals updated" || warn "npm update failed (non-critical)"; }
    ct_has uv && { ct_sh 'uv self update' && info "uv updated" || warn "uv update failed (non-critical)"; }
    ct_has pip3 && { ct_sh 'pip3 install --upgrade pip' && info "pip updated" || warn "pip update failed (non-critical)"; }

    # 2. BASE PACKAGES
    step "Installing base packages"
    case "$DISTRO" in
    debian | ubuntu | linuxmint)
        ct_pkg_install curl wget git micro fish htop btop net-tools dnsutils tree bat \
            unzip tar ca-certificates gnupg lsb-release build-essential procps \
            trash-cli python3 python3-pip python3-venv
        if ! ct_has fastfetch; then
            ct_sh 'add-apt-repository -y ppa:zhangsongcui3371/fastfetch' ||
                ct_sh_quiet 'curl -sLo /tmp/ff.deb https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-amd64.deb && dpkg -i /tmp/ff.deb && rm -f /tmp/ff.deb' || true
        fi
        ;;
    arch | manjaro)
        ct_pkg_install curl wget git micro fish fastfetch htop btop \
            net-tools unzip tar base-devel tree bat trash-cli python python-pip
        ;;
    fedora)
        ct_pkg_install curl wget git micro fish fastfetch htop btop \
            net-tools unzip tar gcc tree bat trash-cli python3 python3-pip
        ;;
    esac
    info "Base packages installed"

    # fastfetch config
    local ff_conf
    ff_conf=$(mktemp)
    cat >"$ff_conf" <<'FFEOF'
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
        {
            "type": "command",
            "key": "Tailscale IP",
            "text": "tailscale ip -4 2>/dev/null || echo 'not connected'"
        },
        {
            "type": "command",
            "key": "Tailscale",
            "text": "tailscale status --self=true 2>/dev/null | head -1 || echo 'not running'"
        },
        "break",
        "colors"
    ]
}
FFEOF
    in_ct mkdir -p /root/.config/fastfetch
    pct push "$CTID" "$ff_conf" /root/.config/fastfetch/config.jsonc
    rm -f "$ff_conf"

    # 3. UV
    step "Python package manager (uv)"
    if ! ct_has uv; then
        ct_sh_quiet 'curl -LsSf https://astral.sh/uv/install.sh | sh'
        info "uv installed"
    else
        info "uv already present"
    fi

    # 4. NODE.JS
    step "Node.js LTS"
    if ! ct_has node; then
        case "$DISTRO" in
        debian | ubuntu | linuxmint)
            ct_sh_quiet 'curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -'
            ct_quiet apt-get install -y nodejs
            ;;
        arch | manjaro) ct_pkg_install nodejs npm ;;
        fedora) ct_quiet dnf install -y nodejs npm ;;
        esac
        info "Node.js installed"
    else
        info "Node.js already present"
    fi

    # 5. TAILSCALE (host-side community script: configures /dev/net/tun + installs)
    step "Tailscale (via community script)"
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/addon/add-tailscale-lxc.sh)" ||
        warn "Tailscale addon failed or cancelled (non-critical)"

    # 6. NPM GLOBALS
    step "npm global packages"
    ct_quiet npm install -g skill-manager
    info "skill-manager (skm) installed"

    # 7. LINUTIL
    step "Linutil"
    if ! ct_has linutil; then
        ct_sh_quiet 'curl -fsSL "https://github.com/TuxLux40/linutil/releases/latest/download/linutil" -o /tmp/linutil 2>/dev/null || curl -fsSL "https://github.com/ChrisTitusTech/linutil/releases/latest/download/linutil" -o /tmp/linutil; install -m 755 /tmp/linutil /usr/local/bin/linutil && rm -f /tmp/linutil'
        info "linutil installed"
    else
        info "linutil already present"
    fi

    # 8. COPILOT CLI
    step "GitHub Copilot CLI"
    ct_sh 'curl -fsSL https://gh.io/copilot-install -o /tmp/copilot-install.sh && yes y | bash /tmp/copilot-install.sh; rm -f /tmp/copilot-install.sh' || true
    info "Copilot CLI installed"

    # 9. CLAUDE CODE
    step "Claude Code"
    ct_sh_quiet 'curl -fsSL https://claude.ai/install.sh | bash'
    info "Claude Code installed"

    # 10. PROXMOXMCP-PLUS
    step "ProxmoxMCP-Plus"
    local pmcp_dir="/opt/ProxmoxMCP-Plus"
    if ct_test -d "$pmcp_dir/.git"; then
        ct_quiet git -C "$pmcp_dir" pull --ff-only
        info "ProxmoxMCP-Plus updated"
    elif ct_test -d "$pmcp_dir"; then
        warn "$pmcp_dir exists but is not a git repository — skipping"
    else
        ct_quiet git clone https://github.com/rodaddy/ProxmoxMCP-Plus.git "$pmcp_dir"
        info "ProxmoxMCP-Plus cloned"
    fi
    ct_sh_quiet "cd $pmcp_dir && export PATH=\$HOME/.local/bin:\$PATH && uv venv && uv pip install -e '.[dev]'"
    in_ct mkdir -p "$pmcp_dir/proxmox-config"

    if ! ct_test -f "$pmcp_dir/proxmox-config/config.json"; then
        local mcp_conf
        mcp_conf=$(mktemp)
        cat >"$mcp_conf" <<PMCPEOF
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
        pct push "$CTID" "$mcp_conf" "$pmcp_dir/proxmox-config/config.json"
        rm -f "$mcp_conf"
    else
        info "ProxmoxMCP config.json already exists, preserving."
    fi

    # Claude Code MCP config
    in_ct mkdir -p /root/.config/Claude
    local claude_mcp
    claude_mcp=$(mktemp)
    cat >"$claude_mcp" <<MCPEOF
{
    "mcpServers": {
        "ProxmoxMCP-Plus": {
            "command": "${pmcp_dir}/.venv/bin/python",
            "args": ["-m", "proxmox_mcp.server"],
            "env": {
                "PYTHONPATH": "${pmcp_dir}/src",
                "PROXMOX_MCP_CONFIG": "${pmcp_dir}/proxmox-config/config.json"
            }
        }
    }
}
MCPEOF
    pct push "$CTID" "$claude_mcp" /root/.config/Claude/claude_desktop_config.json
    rm -f "$claude_mcp"
    warn "ProxmoxMCP: fill in token at $pmcp_dir/proxmox-config/config.json"

    # 11. BASH ENVIRONMENT
    step "Bash environment"
    if ! ct_sh 'grep -Fq "# >>> lxc-postinstall >>>" /root/.bashrc 2>/dev/null'; then
        local bashrc_addon
        bashrc_addon=$(mktemp)
        cat >"$bashrc_addon" <<'EOF'

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
        pct push "$CTID" "$bashrc_addon" /tmp/lxc-bashrc-addon
        ct_sh_quiet 'cat /tmp/lxc-bashrc-addon >> /root/.bashrc && rm -f /tmp/lxc-bashrc-addon'
        rm -f "$bashrc_addon"
        info "Bash environment added"
    else
        info "Bash environment already present, skipping."
    fi

    info "CTID $CTID configuration complete"
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
whiptail --title "LXC Post-Install" --msgbox \
    "Configure selected LXC containers with:\n\n\
 • System update\n\
 • Base packages (fish, micro, fastfetch, bat, btop, …)\n\
 • uv, Node.js LTS\n\
 • Tailscale (via community script)\n\
 • linutil, Copilot CLI, Claude Code\n\
 • ProxmoxMCP-Plus\n\
 • Bash environment tuning\n\n\
Log: $LOGFILE" 20 70

# Config wizard
if [[ -f "$SCRIPT_DIR/.env" ]] && [[ -s "$SCRIPT_DIR/.env" ]]; then
    if ui_confirm "Stored Config" "Found existing .env with saved settings.\n\nReconfigure values?" "Keep current values"; then
        run_interactive_setup
    else
        info "Using stored .env values"
    fi
else
    run_interactive_setup
fi

# Container selection
mapfile -t TARGET_CTIDS < <(ui_select_containers)
[[ ${#TARGET_CTIDS[@]} -eq 0 ]] && die "No containers selected"

# Configure each selected container
for ctid in "${TARGET_CTIDS[@]}"; do
    [[ -z "$ctid" ]] && continue
    if ! configure_container "$ctid"; then
        warn "Setup failed in CTID $ctid (continuing with next)"
    fi
done

# ── DONE ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║         LXC post-install complete            ║${NC}"
echo -e "${GREEN}  ╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Configured ${#TARGET_CTIDS[@]} container(s)${NC}"
echo -e "  ${DIM}Log${NC}  $LOGFILE"
echo ""
warn "Reopen shells in containers to activate bash config"
warn "Fill in PROXMOX_TOKEN_VALUE in each container at /opt/ProxmoxMCP-Plus/proxmox-config/config.json"

# Optional: upload log to 0x0.st
if [[ -s "$LOGFILE" ]] && ui_confirm "Upload log" "Upload install log to 0x0.st?\n\nThe log contains only package manager output — no passwords or tokens.\nThe paste URL is unlisted and auto-expires."; then
    PASTE_URL=$(curl -fsSL -F "file=@${LOGFILE}" https://0x0.st 2>/dev/null) || true
    if [[ -n "${PASTE_URL:-}" ]]; then
        info "Log uploaded: ${PASTE_URL}"
    else
        warn "Log upload failed"
    fi
fi
