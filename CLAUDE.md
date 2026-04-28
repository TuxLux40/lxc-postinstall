# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Single bash script (`lxc-postinstall.sh`) that bootstraps Proxmox LXC containers. Runs **as root inside the container** (not host-side). Supports Debian/Ubuntu/Mint, Arch/Manjaro, and Fedora.

## Running the script

```bash
# One-liner inside any supported container
bash <(curl -fsSL https://raw.githubusercontent.com/TuxLux40/lxc-postinstall/main/lxc-postinstall.sh)

# With credentials pre-filled
PROXMOX_HOST=192.168.1.1 PROXMOX_TOKEN_VALUE=xxx bash <(curl -fsSL ...)

# Or locally with .env
cp .env.example .env && micro .env
sudo bash lxc-postinstall.sh
```

The script sources `.env` from its own directory at startup — `set -a` handles export.

## Validation

```bash
bash -n lxc-postinstall.sh        # syntax check (run before every commit)
shellcheck lxc-postinstall.sh     # optional
```

Log output: `/var/log/lxc-postinstall.log`

## Architecture

- **Runs inside the container**: no `pct exec` wrappers, no host-side checks
- **Non-interactive**: no whiptail; all config via env vars or `.env`
- **Distro packages only**: no external PPAs or repos — nodejs, npm, and gh are available in Debian 12+/Ubuntu/Arch/Fedora official repos
- **Helpers**:
  - `q <cmd>` — run command, redirect stdout+stderr to logfile; print last 5 log lines on failure
  - `pkg <pkgs…>` — distro-agnostic install using `$DISTRO`
- **File writes**: configs written directly (no `pct push`)
- **Log upload**: at completion, log is uploaded to `0x0.st` automatically

## Config variables

| Var                   | Default     | Purpose                                   |
| --------------------- | ----------- | ----------------------------------------- |
| `PROXMOX_HOST`        | _(empty)_   | ProxmoxMCP-Plus config.json               |
| `PROXMOX_USER`        | `root@pam`  | ProxmoxMCP-Plus auth                      |
| `PROXMOX_TOKEN_NAME`  | `mcp-token` | ProxmoxMCP-Plus auth                      |
| `PROXMOX_TOKEN_VALUE` | _(empty)_   | ProxmoxMCP-Plus auth — fill after install |

## What the script installs (in order)

1. System update (`apt-get update && upgrade` / `pacman -Syu` / `dnf upgrade`) — no external repos
2. Base packages: curl, wget, git, micro, fish, fastfetch, htop, btop, bat, net-tools, build tools, python3/venv, nodejs
3. `uv` (Python package manager via astral.sh); `export PATH` updated immediately after
4. `linutil` (TuxLux40 fork, fallback to ChrisTitusTech)
5. npm globals: `skill-manager`
6. GitHub Copilot CLI
7. Claude Code
8. ProxmoxMCP-Plus → `/opt/ProxmoxMCP-Plus` with uv venv; writes `proxmox-config/config.json` and MCP config to `/root/.config/Claude/claude_desktop_config.json`
9. Bash environment (appended to `/root/.bashrc`)

## Adding new steps

Inside the script, add a new block using the section comment pattern:

```bash
# ── 10. MY STEP ──────────────────────────────────────────────────────────────
step "My new step"
if ! command -v mytool &>/dev/null; then
    { curl -fsSL … | bash; } >>"$LOGFILE" 2>&1
    info "mytool installed"
fi
```

Bump `TOTAL_STEPS` at the top. Use `pkg` for distro-agnostic installs; check `$DISTRO` only when package names differ.

## Conventions

- **Env defaults**: centralize all defaults in the `# ── CONFIG ──` block; never scatter them in the script body
- **Distro branches**: always use `debian|ubuntu|linuxmint`, `arch|manjaro`, `fedora` — keep all three consistent
- **Piped installs**: wrap in `{ curl … | bash; } >>"$LOGFILE" 2>&1` to capture both curl stderr and installer output
- **Non-critical steps**: append `|| warn "… (non-critical)"` — don't let optional tools abort the run
- **Bashrc idempotency**: `grep -Fq "# >>> lxc-postinstall >>>"` guard prevents duplicate appends
- **`.env.example`**: update alongside the script's CONFIG block when adding new vars; keep secrets empty

## .env tracking

`.env` is gitignored. `.env.example` is the tracked template. Never commit real credentials.

## ProxmoxMCP token

After running, fill in `PROXMOX_TOKEN_VALUE` at `/opt/ProxmoxMCP-Plus/proxmox-config/config.json`.  
Create the token in PVE → Datacenter → Permissions → API Tokens with **Privilege Separation OFF**.
