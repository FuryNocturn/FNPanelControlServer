#!/usr/bin/env bash

######################################################################################
#                                                                                    #
# FNPanel :: blueprint.sh                                                            #
#                                                                                    #
# Installs the Blueprint framework on top of an already-installed Pterodactyl panel  #
# so FNPanel themes/extensions can be built and applied without hard-forking.        #
#                                                                                    #
# MUST run AFTER the panel is installed at PANEL_DIR. Requires Node.js 20+, yarn,     #
# unzip. Ref: https://blueprint.zip  /  github.com/BlueprintFramework/framework      #
#                                                                                    #
# Standalone:  bash blueprint.sh                                                      #
# Sourced:     install_blueprint                                                      #
######################################################################################

# --- minimal logging shims (real installer provides these) ---
command -v output  >/dev/null 2>&1 || output()  { echo -e "* $1"; }
command -v success >/dev/null 2>&1 || success() { echo -e "* SUCCESS: $1"; }
command -v warning >/dev/null 2>&1 || warning() { echo -e "* WARNING: $1"; }
command -v error   >/dev/null 2>&1 || error()   { echo -e "* ERROR: $1" 1>&2; }

PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"

_install_node_yarn() {
  local node_major
  node_major="$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')"

  if ! command -v node >/dev/null 2>&1 || [ "${node_major:-0}" -lt 20 ]; then
    output "Installing Node.js 20.x..."
    if command -v apt-get >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs
    elif command -v dnf >/dev/null 2>&1; then
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      dnf install -y nodejs
    fi
  fi

  command -v yarn >/dev/null 2>&1 || npm install -g yarn
  command -v unzip >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 && apt-get install -y unzip; }
}

install_blueprint() {
  if [ ! -d "$PANEL_DIR" ]; then
    error "Panel directory $PANEL_DIR not found; install the panel first."
    return 1
  fi

  output "Installing Blueprint framework in $PANEL_DIR ..."
  _install_node_yarn

  cd "$PANEL_DIR" || return 1

  # Blueprint expects a working yarn setup in the panel.
  output "Installing panel node dependencies (yarn)..."
  yarn install --frozen-lockfile || yarn install || true

  # Resolve the latest Blueprint release zip from GitHub.
  local dl
  dl="$(curl -sSL https://api.github.com/repos/BlueprintFramework/framework/releases/latest \
        | grep -Eo 'https://[^"]+release\.zip' | head -n1)"
  if [ -z "$dl" ]; then
    error "Could not resolve the latest Blueprint release URL (GitHub rate limit?)."
    return 1
  fi

  output "Downloading Blueprint from $dl"
  curl -fL -o blueprint.zip "$dl"
  unzip -o blueprint.zip >/dev/null
  chmod +x blueprint.sh

  # Provide a .blueprintrc if absent (web user differs per distro/webserver).
  local webuser="www-data"
  case "${OS:-}" in
    rocky | almalinux) webuser="nginx" ;;
  esac
  if [ ! -f "$PANEL_DIR/.blueprintrc" ]; then
    printf 'WEBUSER="%s";\nOWNERSHIP="%s:%s";\nUSERSHELL="/bin/bash";\n' \
      "$webuser" "$webuser" "$webuser" >"$PANEL_DIR/.blueprintrc"
  fi

  output "Running Blueprint installer..."
  if bash blueprint.sh; then
    success "Blueprint installed. Build FNPanel extensions/themes with the 'blueprint' command."
  else
    warning "Blueprint installer returned an error. Finish/verify it manually in $PANEL_DIR (https://blueprint.zip)."
  fi
}

# ------------------------------ standalone runner ---------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  [ "$(id -u)" -eq 0 ] || { error "This script must be run as root."; exit 1; }
  install_blueprint
fi
