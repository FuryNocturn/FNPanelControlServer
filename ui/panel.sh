#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Project 'pterodactyl-installer'                                                    #
#                                                                                    #
# Copyright (C) 2018 - 2026, Vilhelm Prytz, <vilhelm@prytznet.se>                    #
#                                                                                    #
#   This program is free software: you can redistribute it and/or modify             #
#   it under the terms of the GNU General Public License as published by             #
#   the Free Software Foundation, either version 3 of the License, or                #
#   (at your option) any later version.                                              #
#                                                                                    #
#   This program is distributed in the hope that it will be useful,                  #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of                   #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                    #
#   GNU General Public License for more details.                                     #
#                                                                                    #
#   You should have received a copy of the GNU General Public License                #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.           #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# This script is not associated with the official Pterodactyl Project.               #
# https://github.com/pterodactyl-installer/pterodactyl-installer                     #
#                                                                                    #
######################################################################################

# Check if script is loaded, load if not or fail otherwise.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# ------------------ Variables ----------------- #

# Domain name / IP
export FQDN=""

# Default MySQL credentials
export MYSQL_DB=""
export MYSQL_USER=""
export MYSQL_PASSWORD=""

# Environment
export timezone=""
export email=""
export telemetry=""

# Initial admin account
export user_email=""
export user_username=""
export user_firstname=""
export user_lastname=""
export user_password=""

# Assume SSL, will fetch different config if true
export ASSUME_SSL=false
export CONFIGURE_LETSENCRYPT=false

# Firewall
export CONFIGURE_FIREWALL=false

# FNPanel extras
export CONFIGURE_TIMESYNC_SERVER=false
export TIMESYNC_ALLOW=""
export INSTALL_BLUEPRINT=false

# ------------ User input functions ------------ #

ask_letsencrypt() {
  if [ "$CONFIGURE_FIREWALL" == false ]; then
    warning "Let's Encrypt requires port 80/443 to be opened! You have opted out of the automatic firewall configuration; use this at your own risk (if port 80/443 is closed, the script will fail)!"
  fi

  echo -e -n "* Do you want to automatically configure HTTPS using Let's Encrypt? (y/N): "
  read -r CONFIRM_SSL

  if [[ "$CONFIRM_SSL" =~ [Yy] ]]; then
    CONFIGURE_LETSENCRYPT=true
    ASSUME_SSL=false
  fi
}

ask_assume_ssl() {
  output "Let's Encrypt is not going to be automatically configured by this script (user opted out)."
  output "You can 'assume' Let's Encrypt, which means the script will download a nginx configuration that is configured to use a Let's Encrypt certificate but the script won't obtain the certificate for you."
  output "If you assume SSL and do not obtain the certificate, your installation will not work."
  echo -n "* Assume SSL or not? (y/N): "
  read -r ASSUME_SSL_INPUT

  [[ "$ASSUME_SSL_INPUT" =~ [Yy] ]] && ASSUME_SSL=true
  true
}

ask_telemetry() {
  output "Pterodactyl Panel collects anonymous telemetry data to help steer the development."
  output "More Info: https://pterodactyl.io/panel/1.0/additional_configuration.html#telemetry"
  echo -n "* Enable sending anonymous telemetry data? (yes/no) [yes]: "
  read -r telemetry_input

  if [[ -z "$telemetry_input" ]] || [[ "$telemetry_input" =~ ^([Yy]|[Yy]es)$ ]]; then
    telemetry="true"
  else
    telemetry="false"
  fi
}

ask_timesync_server() {
  output "This panel machine can act as an NTP time server so ALL your nodes share the"
  output "same clock. Different clocks between machines break lag/latency metrics and"
  output "cross-server timestamp checks."
  echo -e -n "* Serve time (NTP) to your nodes from this machine? (y/N): "
  read -r CONFIRM_TS
  if [[ "$CONFIRM_TS" =~ [Yy] ]]; then
    CONFIGURE_TIMESYNC_SERVER=true
    echo -n "* Node IPs/subnets allowed to query, space separated (blank = add later): "
    read -r TIMESYNC_ALLOW
  fi
}

ask_blueprint() {
  output "Blueprint lets you apply FNPanel themes and extensions without forking the panel."
  echo -e -n "* Install the Blueprint framework? (Y/n): "
  read -r CONFIRM_BP
  if [[ -z "$CONFIRM_BP" ]] || [[ "$CONFIRM_BP" =~ ^[Yy]$ ]]; then
    INSTALL_BLUEPRINT=true
  fi
}

check_FQDN_SSL() {
  if [[ $(invalid_ip "$FQDN") == 1 && $FQDN != 'localhost' ]]; then
    SSL_AVAILABLE=true
  else
    warning "* Let's Encrypt will not be available for IP addresses."
    output "To use Let's Encrypt, you must use a valid domain name."
  fi
}

main() {
  # check if we can detect an already existing installation
  if [ -d "/var/www/pterodactyl" ]; then
    warning "The script has detected that you already have Pterodactyl panel on your system! You cannot run the script multiple times, it will fail!"
    echo -e -n "* Are you sure you want to proceed? (y/N): "
    read -r CONFIRM_PROCEED
    if [[ ! "$CONFIRM_PROCEED" =~ [Yy] ]]; then
      error "Installation aborted!"
      exit 1
    fi
  fi

  welcome "panel"

  check_os_x86_64

  # Panel version (suggested = latest stable; press Enter to accept).
  suggested_ver="$PTERODACTYL_PANEL_VERSION"
  echo -n "* Panel version to install [$suggested_ver]: "
  read -r ver_input
  [ -n "$ver_input" ] && PTERODACTYL_PANEL_VERSION="$ver_input"
  if [ "$PTERODACTYL_PANEL_VERSION" != "$suggested_ver" ]; then
    export PANEL_DL_URL="https://github.com/pterodactyl/panel/releases/download/$PTERODACTYL_PANEL_VERSION/panel.tar.gz"
  fi

  # set database credentials
  output "Database configuration."
  output ""
  output "This will be the credentials used for communication between the MySQL"
  output "database and the panel. You do not need to create the database"
  output "before running this script, the script will do that for you."
  output ""

  MYSQL_DB="-"
  while [[ "$MYSQL_DB" == *"-"* ]]; do
    required_input MYSQL_DB "Database name (panel): " "" "panel"
    [[ "$MYSQL_DB" == *"-"* ]] && error "Database name cannot contain hyphens"
  done

  MYSQL_USER="-"
  while [[ "$MYSQL_USER" == *"-"* ]]; do
    required_input MYSQL_USER "Database username (pterodactyl): " "" "pterodactyl"
    [[ "$MYSQL_USER" == *"-"* ]] && error "Database user cannot contain hyphens"
  done

  # MySQL password input
  rand_pw=$(gen_passwd 64)
  password_input MYSQL_PASSWORD "Password (press enter to use randomly generated password): " "MySQL password cannot be empty" "$rand_pw"

  readarray -t valid_timezones <<<"$(curl -s "$GITHUB_URL"/configs/valid_timezones.txt)"
  output "List of valid timezones here $(hyperlink "https://www.php.net/manual/en/timezones.php")"

  # Suggested = the machine's current system timezone (Enter to accept).
  sys_tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'Etc/UTC')"
  while [ -z "$timezone" ]; do
    echo -n "* Select timezone [$sys_tz]: "
    read -r timezone_input

    if [ -z "$timezone_input" ]; then
      timezone="$sys_tz"
    elif array_contains_element "$timezone_input" "${valid_timezones[@]}"; then
      timezone="$timezone_input"
    else
      error "Invalid timezone, see the list linked above"
    fi
  done

  email_input email "Provide the email address that will be used to configure Let's Encrypt and Pterodactyl: " "Email cannot be empty or invalid"

  # Initial admin account
  email_input user_email "Email address for the initial admin account: " "Email cannot be empty or invalid"
  required_input user_username "Username for the initial admin account: " "Username cannot be empty"
  required_input user_firstname "First name for the initial admin account: " "Name cannot be empty"
  required_input user_lastname "Last name for the initial admin account: " "Name cannot be empty"
  password_input user_password "Password for the initial admin account: " "Password cannot be empty"

  print_brake 72

  # set FQDN (suggested = detected public IP; Enter to accept)
  suggested_fqdn="$(curl -fsS4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  while [ -z "$FQDN" ]; do
    echo -n "* Set the FQDN/IP of this panel [${suggested_fqdn:-panel.example.com}]: "
    read -r FQDN
    [ -z "$FQDN" ] && FQDN="$suggested_fqdn"
    [ -z "$FQDN" ] && error "FQDN cannot be empty"
  done

  # Check if SSL is available
  check_FQDN_SSL

  # Ask if firewall is needed
  ask_firewall CONFIGURE_FIREWALL

  # Only ask about SSL if it is available
  if [ "$SSL_AVAILABLE" == true ]; then
    # Ask if letsencrypt is needed
    ask_letsencrypt
    # If it's already true, this should be a no-brainer
    [ "$CONFIGURE_LETSENCRYPT" == false ] && ask_assume_ssl
  fi

  # verify FQDN if user has selected to assume SSL or configure Let's Encrypt
  [ "$CONFIGURE_LETSENCRYPT" == true ] || [ "$ASSUME_SSL" == true ] && bash <(curl -s "$GITHUB_URL"/lib/verify-fqdn.sh) "$FQDN"

  # ask telemetry preference
  ask_telemetry

  # FNPanel extras: time sync server + Blueprint
  ask_timesync_server
  ask_blueprint

  # summary
  summary

  # confirm installation
  echo -e -n "\n* Initial configuration completed. Continue with installation? (y/N): "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ [Yy] ]]; then
    run_installer "panel"
  else
    error "Installation aborted."
    exit 1
  fi
}

summary() {
  print_brake 62
  output "Pterodactyl panel $PTERODACTYL_PANEL_VERSION with nginx on $OS"
  output "Database name: $MYSQL_DB"
  output "Database user: $MYSQL_USER"
  output "Database password: (censored)"
  output "Timezone: $timezone"
  output "Email: $email"
  output "User email: $user_email"
  output "Username: $user_username"
  output "First name: $user_firstname"
  output "Last name: $user_lastname"
  output "User password: (censored)"
  output "Hostname/FQDN: $FQDN"
  output "Configure Firewall? $CONFIGURE_FIREWALL"
  output "Configure Let's Encrypt? $CONFIGURE_LETSENCRYPT"
  output "Assume SSL? $ASSUME_SSL"
  output "Telemetry: $telemetry"
  output "Serve time (NTP) to nodes? $CONFIGURE_TIMESYNC_SERVER"
  [ "$CONFIGURE_TIMESYNC_SERVER" == true ] && output "  Allowed nodes: ${TIMESYNC_ALLOW:-<none yet>}"
  output "Install Blueprint? $INSTALL_BLUEPRINT"
  print_brake 62
}

goodbye() {
  print_brake 62
  output "Panel installation completed"
  output ""

  [ "$CONFIGURE_LETSENCRYPT" == true ] && output "Your panel should be accessible from $(hyperlink "$FQDN")"
  [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && output "You have opted in to use SSL, but not via Let's Encrypt automatically. Your panel will not work until SSL has been configured."
  [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && output "Your panel should be accessible from $(hyperlink "$FQDN")"

  output ""
  output "Installation is using nginx on $OS"
  output "Thank you for using this script."
  [ "$CONFIGURE_FIREWALL" == false ] && echo -e "* ${COLOR_RED}Note${COLOR_NC}: If you haven't configured the firewall: 80/443 (HTTP/HTTPS) is required to be open!"
  [ "$CONFIGURE_TIMESYNC_SERVER" == true ] && echo -e "* ${COLOR_YELLOW}NTP${COLOR_NC}: open ${COLOR_YELLOW}UDP/123${COLOR_NC} to your nodes so they can sync their clock from this panel."
  print_brake 62
}

# run script
main
goodbye
