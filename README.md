# lxc-postinstall

Bootstrap script for Proxmox LXC containers. Run as root **inside** the container.

## One-Liner

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/TuxLux40/lxc-postinstall/main/lxc-postinstall.sh)
```

With Proxmox MCP credentials pre-filled:

```bash
PROXMOX_HOST=192.168.1.1 PROXMOX_TOKEN_VALUE=xxx bash <(curl -fsSL https://raw.githubusercontent.com/TuxLux40/lxc-postinstall/main/lxc-postinstall.sh)
```

## What it installs

System update → base packages → uv → linutil → skill-manager → Copilot CLI → Claude Code → ProxmoxMCP-Plus → bash environment

## Prerequisites

- Root access inside the container
- Internet access
- Supported distros: Debian, Ubuntu, Linux Mint, Arch, Manjaro, Fedora

## Configuration

Pass env vars inline (see one-liner above) or create `.env` beside the script:

```bash
cp .env.example .env
# edit .env, then:
sudo bash lxc-postinstall.sh
```

After running, fill in `PROXMOX_TOKEN_VALUE` at `/opt/ProxmoxMCP-Plus/proxmox-config/config.json`.  
Create the token in PVE → Datacenter → Permissions → API Tokens with **Privilege Separation OFF**.

## Validation

```bash
bash -n lxc-postinstall.sh
shellcheck lxc-postinstall.sh   # optional
```
