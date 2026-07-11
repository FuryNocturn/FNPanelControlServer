# FNPanel installer

Fork of [`pterodactyl-installer`](https://github.com/pterodactyl-installer/pterodactyl-installer)
adapted to deploy **FNPanel** (Pterodactyl + Blueprint) with a few hardening fixes and
two extra features. Public, no hardcoded domains/versions — everything is prompted with a
**suggested default you accept by pressing Enter**.

## What changed vs upstream

### New features
- **`installers/timesync.sh`** — clock sync with chrony. The panel machine can act as an
  NTP **server** for the nodes; each node syncs from the panel (**client**). Fixes clock
  skew that breaks lag/latency metrics and cross-server timestamp checks.
  Runs standalone (`bash timesync.sh`) or is sourced by the panel/wings installers.
  - Panel prompt: *"Serve time (NTP) to your nodes?"* → asks allowed node IPs.
  - Wings prompt: *"Panel IP/host to sync time from"*.
  - Client uses `makestep 1.0 3` so the clock is corrected **immediately** on start.
- **`installers/blueprint.sh`** — installs Node 20 + yarn + the Blueprint framework on top
  of the panel, so FNPanel themes/extensions can be applied without a hard fork.
  - Panel prompt: *"Install the Blueprint framework? (Y/n)"* (default yes).

### Suggested-default prompts (public-friendly)
- **Panel version** → suggested = latest stable (Enter accepts); a specific version builds
  the correct `releases/download/<ver>/panel.tar.gz` URL.
- **FQDN/IP** → suggested = detected public IP.
- **Timezone** → suggested = the machine's current system timezone (not hardcoded).

### Hardening / bug fixes
- `set -eo pipefail` in `lib.sh` (a failing `curl` in a pipe no longer passes silently).
- Idempotent DB: `CREATE USER/DATABASE IF NOT EXISTS` → installer is re-runnable.
- Cron: explicit 5-field line + de-dup on re-run (previously the 5th field was completed
  by a logging prefix — fragile — and re-running duplicated the entry).
- sury PHP repo key scoped with `signed-by=` instead of system-wide `trusted.gpg.d`.
- Panel tarball: validate it is a real gzip archive before extracting; optional
  `PANEL_SHA256` env var for checksum verification.
- Removed a dead `uname -r | grep xxxx` kernel check.
- Fixed `ask_letsencrypt` referencing undefined `CONFIGURE_UFW` → uses `CONFIGURE_FIREWALL`.
- Wings: `systemctl restart mariadb` (was `mysqld`, wrong unit on Debian/Ubuntu).

## Before publishing to your GitHub
The scripts fetch `lib.sh` / `installers/*` at runtime from `GITHUB_BASE_URL`. Point it at
your fork in `install.sh` and `lib/lib.sh`:

```
export GITHUB_BASE_URL="https://raw.githubusercontent.com/<your-user>/fnpanel-installer"
```

Until then, the remote-sourced extras (timesync/blueprint) are skipped gracefully when run
from a local clone, and `timesync.sh` still works standalone.
