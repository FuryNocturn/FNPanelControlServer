#!/usr/bin/env bash

######################################################################################
#                                                                                    #
# FNPanel :: timesync.sh                                                             #
#                                                                                    #
# Keeps every machine's clock in agreement using chrony (NTP). Clock skew between    #
# a panel and its nodes breaks anything time-dependent: lag/latency metrics,         #
# timestamp validation for cross-server messaging, and log correlation.              #
#                                                                                    #
#   server mode -> run on the PANEL machine. Disciplines its own clock from public   #
#                  NTP pools AND serves time to your nodes, so the nodes agree with   #
#                  each other even if the internet upstream blips.                    #
#   client mode -> run on each NODE (wings). Prefers the panel as time source, keeps  #
#                  the distro's public pool as fallback, and STEPS the clock on       #
#                  start (makestep) instead of slewing it slowly.                     #
#                                                                                    #
# Standalone:  bash timesync.sh                                                       #
# Sourced:     configure_timesync_server "203.0.113.10 203.0.113.11"                  #
#              configure_timesync_client "203.0.113.1"                                #
#                                                                                    #
# Part of the FNPanel installer (fork of pterodactyl-installer, GPLv3).               #
######################################################################################

# NOTE: strict mode (set -euo pipefail) is enabled ONLY in the standalone runner at
# the bottom, so that `source`-ing this file from the installer does not alter the
# caller's shell options.

# --- minimal logging shims (real installer provides these; keep standalone-safe) ---
command -v output  >/dev/null 2>&1 || output()  { echo -e "* $1"; }
command -v success >/dev/null 2>&1 || success() { echo -e "* SUCCESS: $1"; }
command -v warning >/dev/null 2>&1 || warning() { echo -e "* WARNING: $1"; }
command -v error   >/dev/null 2>&1 || error()   { echo -e "* ERROR: $1" 1>&2; }

FN_BEGIN="# >>> FNPanel timesync >>>"
FN_END="# <<< FNPanel timesync <<<"

CHRONY_CONF=""
CHRONY_SVC=""

# Detect the chrony config path and systemd service name across distros.
_detect_chrony() {
  if [ -f /etc/chrony/chrony.conf ]; then
    CHRONY_CONF=/etc/chrony/chrony.conf            # Debian / Ubuntu
  elif [ -f /etc/chrony.conf ]; then
    CHRONY_CONF=/etc/chrony.conf                   # RHEL family
  else
    CHRONY_CONF=/etc/chrony/chrony.conf            # sensible default
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^chronyd\.service'; then
    CHRONY_SVC=chronyd                             # RHEL family
  else
    CHRONY_SVC=chrony                              # Debian / Ubuntu
  fi
}

install_chrony() {
  output "Installing chrony (NTP)..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq chrony
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q chrony
  else
    error "No supported package manager (apt/dnf) found."
    return 1
  fi
  # systemd-timesyncd is a client-only SNTP daemon and conflicts with chrony.
  systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
  _detect_chrony
}

# Remove any previously-managed FNPanel block so re-running is idempotent.
_strip_fn_block() {
  [ -f "$CHRONY_CONF" ] || return 0
  sed -i "/$FN_BEGIN/,/$FN_END/d" "$CHRONY_CONF"
}

_apply() {
  systemctl enable "$CHRONY_SVC" >/dev/null 2>&1 || true
  systemctl restart "$CHRONY_SVC"
}

# configure_timesync_server "<allowed node IPs/subnets, space separated>"
# The existing distro upstream pool lines are kept; we only append allow + local.
configure_timesync_server() {
  local allow_list="${1:-}"
  install_chrony
  _strip_fn_block
  {
    echo "$FN_BEGIN"
    echo "# Serve time to FNPanel nodes; keep serving even if upstream is unreachable."
    echo "local stratum 10"
    if [ -n "$allow_list" ]; then
      for a in $allow_list; do echo "allow $a"; done
    else
      warning "No node IPs given: nobody is allowed to query this server yet."
      echo "# (no 'allow' entries yet - add: allow <node-ip> and restart chrony)"
    fi
    echo "$FN_END"
  } >> "$CHRONY_CONF"
  _apply
  success "Panel now serves time via chrony. Remember to open UDP/123 to your nodes."
}

# configure_timesync_client "<panel IP/host>"
# Appends the panel as preferred source; distro pool stays as fallback.
configure_timesync_client() {
  local panel_host="${1:?panel host/IP required}"
  install_chrony
  _strip_fn_block
  {
    echo "$FN_BEGIN"
    echo "server $panel_host iburst prefer"
    echo "makestep 1.0 3"
    echo "$FN_END"
  } >> "$CHRONY_CONF"
  _apply
  success "Clock now synced from $panel_host (chrony), with public pool as fallback."
}

verify_timesync() {
  command -v chronyc >/dev/null 2>&1 || return 0
  output "chrony sources:"
  chronyc sources || true
  output "chrony tracking:"
  chronyc tracking || true
}

# ------------------------------ standalone runner ---------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  [ "$(id -u)" -eq 0 ] || { error "This script must be run as root."; exit 1; }

  echo "FNPanel time sync"
  echo "  [1] This is the PANEL machine (act as time server for my nodes)"
  echo "  [2] This is a NODE / wings machine (sync from my panel)"
  read -rp "* Select 1 or 2: " mode

  case "$mode" in
    1)
      read -rp "* Node IPs/subnets allowed to query (space separated, blank = add later): " ips
      configure_timesync_server "$ips"
      ;;
    2)
      read -rp "* Panel IP/host to sync from: " host
      [ -z "$host" ] && { error "Panel host is required."; exit 1; }
      configure_timesync_client "$host"
      ;;
    *)
      error "Invalid option."
      exit 1
      ;;
  esac

  verify_timesync
fi
