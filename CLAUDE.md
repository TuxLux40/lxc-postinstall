# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Single bash script (`lxc-postinstall.sh`) for bootstrapping Proxmox LXC containers. Runs as root. Supports Debian/Ubuntu/Mint, Arch/Manjaro, Fedora.

## Running the script

```bash
# Copy and fill env template first
cp .env.example .env && micro .env

# Then run as root
sudo bash lxc-postinstall.sh
```

The script sources `.env` from its own directory at startup — no export needed, `set -a` handles it.

## Config variables

All config is env-driven with defaults baked into the script:

| Var                   | Default         | Purpose                                   |
| --------------------- | --------------- | ----------------------------------------- |
| `TIMEZONE`            | `Europe/Berlin` | timedatectl / symlink                     |
| `LOCALE`              | `de_DE.UTF-8`   | locale-gen                                |
| `TS_AUTHKEY`          | _(empty)_       | Tailscale auto-join; skip if unset        |
| `PROXMOX_HOST`        | _(empty)_       | ProxmoxMCP-Plus config.json               |
| `PROXMOX_USER`        | `root@pam`      | ProxmoxMCP-Plus auth                      |
| `PROXMOX_TOKEN_NAME`  | `mcp-token`     | ProxmoxMCP-Plus auth                      |
| `PROXMOX_TOKEN_VALUE` | _(empty)_       | ProxmoxMCP-Plus auth — must fill manually |

## What the script installs (in order)

1. System update
2. Base packages: curl, wget, git, micro, fish, fastfetch, htop, btop, net-tools, build tools, python3/pip/venv
3. `uv` (Python package manager via astral.sh)
4. Node.js LTS (nodesource for Debian/Ubuntu)
5. Tailscale (joins tailnet if `TS_AUTHKEY` set, enables Tailscale SSH)
6. npm globals: `skill-manager`
7. `linutil` (TuxLux40 fork, fallback to ChrisTitusTech)
8. GitHub Copilot CLI
9. Claude Code
10. ProxmoxMCP-Plus → `/opt/ProxmoxMCP-Plus` with uv venv; writes `proxmox-config/config.json` and Claude Code MCP config to `/root/.config/Claude/claude_desktop_config.json`
11. Timezone
12. Locale
13. Bash environment (appended to `/root/.bashrc`)

## Adding new steps

Follow the numbered section pattern (`# ── N. NAME ──`). Use `pkg_install` for distro-agnostic package installs. Check `$DISTRO` only when package names differ across distros.

## .env tracking

`.env` itself is gitignored (only `*.log` is explicitly ignored, but `.env` was removed from tracking intentionally — see commit `6066d0e`). `.env.example` is the tracked template. Never commit real `.env`.

## ProxmoxMCP token

After running, fill in `PROXMOX_TOKEN_VALUE` at `/opt/ProxmoxMCP-Plus/proxmox-config/config.json`. Create the token in PVE → Datacenter → Permissions → API Tokens with Privilege Separation OFF.
