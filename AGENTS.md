# AGENTS.md

Quick guide for coding agents in this repository.

## Project Focus

- Single-script repo: [lxc-postinstall.sh](lxc-postinstall.sh) bootstraps Proxmox LXC containers as root.
- Primary reference and detailed docs: [CLAUDE.md](CLAUDE.md).

## Quick Workflow

1. Change only what is needed for the current task.
2. Keep the numbered section structure in [lxc-postinstall.sh](lxc-postinstall.sh).
3. For new install steps, continue the `# ── N. NAME ──` pattern.
4. Before finishing, run at least a syntax check: `bash -n lxc-postinstall.sh`.

## Script Conventions

- Do not weaken root-only behavior (the script is designed for root).
- Use `pkg_install` for package installation; go distro-specific only when package names differ.
- Keep distro branches consistent: `debian|ubuntu|linuxmint`, `arch|manjaro`, `fedora`.
- Keep env defaults centralized in the CONFIG block, not scattered throughout the script.
- Only change the order of main sections when technically necessary.

## README Convention (if created/updated)

- Keep README short and operational: purpose, prerequisites, quickstart, configuration, security notes.
- For variables and step sequences, link to [CLAUDE.md](CLAUDE.md) instead of duplicating content.
- Clearly state root execution and supported distributions.

## .env.example Convention (if created/updated)

- Include every variable from the CONFIG block in [lxc-postinstall.sh](lxc-postinstall.sh) as a key.
- Keep secrets empty as placeholders (for example `TS_AUTHKEY=`, `PROXMOX_TOKEN_VALUE=`).
- Set safe defaults only for non-sensitive values (for example `TIMEZONE`, `LOCALE`, `PROXMOX_USER`, `PROXMOX_TOKEN_NAME`).
- Never include real credentials, tokens, or hosts.
- When adding new env vars, always update script and .env.example together.

## Security Boundaries

- Never write real credentials into files, commits, or output.
- For SSH changes, explicitly call out key-only access risk.

## Validation

- Minimum: `bash -n lxc-postinstall.sh`
- Optional (if available): `shellcheck lxc-postinstall.sh`
