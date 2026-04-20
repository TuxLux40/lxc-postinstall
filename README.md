# lxc-postinstall

Bootstrap script for Proxmox LXC containers.

This repository contains a single root-only script, [lxc-postinstall.sh](lxc-postinstall.sh), that performs post-install setup across supported Linux distributions.

## Install One-Liner

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/TuxLux40/lxc-postinstall/main/lxc-postinstall.sh)
```

Optional with environment variables in one command:

```bash
TIMEZONE=Europe/Berlin LOCALE=de_DE.UTF-8 TS_AUTHKEY=... PROXMOX_HOST=... PROXMOX_USER=root@pam PROXMOX_TOKEN_NAME=mcp-token PROXMOX_TOKEN_VALUE=... bash <(curl -fsSL https://raw.githubusercontent.com/TuxLux40/lxc-postinstall/main/lxc-postinstall.sh)
```

## Interactive Mode

By default (when run in a TTY), the script opens an interactive flow where you can:

- Set `TIMEZONE`, `LOCALE`, `TS_AUTHKEY`, and Proxmox MCP credentials
- On a Proxmox host, choose target containers (CTIDs) and run setup in batch

You can disable prompts for automation:

```bash
sudo bash lxc-postinstall.sh --non-interactive
```

## Prerequisites

- Run inside an LXC container where you want the setup applied
- Root privileges
- Internet access for package and tool downloads
- Supported distributions:
  - Debian
  - Ubuntu
  - Linux Mint
  - Arch Linux
  - Manjaro
  - Fedora

## Quickstart

```bash
cp .env.example .env
micro .env
sudo bash lxc-postinstall.sh
```

The script automatically loads `.env` from the repository directory.

## Configuration

All configuration is environment-driven via `.env`.

For complete variable details, defaults, and behavior, see [CLAUDE.md](CLAUDE.md).

## Security Notes

- Do not commit `.env` with real credentials or tokens.
- Keep secret values empty in `.env.example`.
- The script enforces SSH key-only authentication; ensure `/root/.ssh/authorized_keys` is in place before relying on SSH access.

## Validation

```bash
bash -n lxc-postinstall.sh
```

Optional (if installed):

```bash
shellcheck lxc-postinstall.sh
```
