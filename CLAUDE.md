# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Host-only bash script (`lxc-postinstall.sh`) for bootstrapping Proxmox LXC containers. Runs on the Proxmox host as root. Selects containers via whiptail and configures each one via `pct exec` / `pct push`. Containers can be Debian/Ubuntu/Mint, Arch/Manjaro, or Fedora.

## Running the script

```bash
# Copy and fill env template first (optional — the script also prompts via whiptail)
cp .env.example .env && micro .env

# Then run as root on the Proxmox host
sudo bash lxc-postinstall.sh
```

The script sources `.env` from its own directory at startup — no export needed, `set -a` handles it. Same values can also be entered interactively via whiptail and saved to `.env`.

## Architecture

- **Host-only**: script refuses to run if `pct` or `/etc/pve` are missing
- **Per-container loop**: for each selected CTID, `configure_container()` runs all 11 install steps via `pct exec` helpers
- **Helpers** (inside `configure_container`, operate on `$CTID`):
  - `in_ct <cmd>` — run a command
  - `ct_quiet <cmd>` — run and log, fail container setup on error (skips to next CTID)
  - `ct_sh '<shell snippet>'` / `ct_sh_quiet` — for pipelines/heredocs
  - `ct_has <bin>` — check if a command exists
  - `ct_test <test-args>` — `test` wrapper for file/dir checks
  - `ct_pkg_install <pkgs…>` — distro-agnostic install using `$DISTRO`
- **File pushes**: build configs on host to a tmpfile, then `pct push "$CTID" tmpfile /target/path`
- **Tailscale**: delegated to `community-scripts/ProxmoxVE` addon (runs host-side, configures `/dev/net/tun` in the container's LXC config)

## Config variables

| Var                   | Default     | Purpose                                   |
| --------------------- | ----------- | ----------------------------------------- |
| `TS_AUTHKEY`          | _(empty)_   | Tailscale auto-join; skip if unset        |
| `PROXMOX_HOST`        | _(empty)_   | ProxmoxMCP-Plus config.json               |
| `PROXMOX_USER`        | `root@pam`  | ProxmoxMCP-Plus auth                      |
| `PROXMOX_TOKEN_NAME`  | `mcp-token` | ProxmoxMCP-Plus auth                      |
| `PROXMOX_TOKEN_VALUE` | _(empty)_   | ProxmoxMCP-Plus auth — must fill manually |

## What the script installs (per container, in order)

1. System update
2. Base packages: curl, wget, git, micro, fish, fastfetch, htop, btop, bat, net-tools, build tools, python3/pip/venv
3. `uv` (Python package manager via astral.sh)
4. Node.js LTS (nodesource for Debian/Ubuntu)
5. Tailscale via community-scripts addon (host-side, adds `/dev/net/tun`)
6. npm globals: `skill-manager`
7. `linutil` (TuxLux40 fork, fallback to ChrisTitusTech)
8. GitHub Copilot CLI
9. Claude Code
10. ProxmoxMCP-Plus → `/opt/ProxmoxMCP-Plus` with uv venv; writes `proxmox-config/config.json` and Claude Code MCP config to `/root/.config/Claude/claude_desktop_config.json`
11. Bash environment (appended to `/root/.bashrc`)

## Adding new steps

Inside `configure_container()`, add a new block between the existing steps:

```bash
step "My new step"
if ! ct_has mytool; then
    ct_sh_quiet 'curl -fsSL … | bash'
    info "mytool installed"
fi
```

Use `ct_pkg_install` for distro-agnostic package installs. Check `$DISTRO` only when package names differ. Bump `TOTAL_STEPS` at the top of the file to keep the progress bar accurate.

## .env tracking

`.env` itself is gitignored (only `*.log` is explicitly ignored, but `.env` was removed from tracking intentionally — see commit `6066d0e`). `.env.example` is the tracked template. Never commit real `.env`.

## ProxmoxMCP token

After running, fill in `PROXMOX_TOKEN_VALUE` inside each container at `/opt/ProxmoxMCP-Plus/proxmox-config/config.json`. Create the token in PVE → Datacenter → Permissions → API Tokens with Privilege Separation OFF.
