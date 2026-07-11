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

# FNPanel: load the timesync (chrony) helpers so the panel can optionally act as
# an NTP time server for the nodes. Sourced (its standalone menu stays dormant).
if ! fn_exists configure_timesync_server; then
  # shellcheck source=installers/timesync.sh
  source <(curl -sSL "$GITHUB_URL/installers/timesync.sh") 2>/dev/null || true
fi

# FNPanel: load the Blueprint installer helper (install_blueprint).
if ! fn_exists install_blueprint; then
  # shellcheck source=installers/blueprint.sh
  source <(curl -sSL "$GITHUB_URL/installers/blueprint.sh") 2>/dev/null || true
fi

# ------------------ Variables ----------------- #

# Domain name / IP
FQDN="${FQDN:-localhost}"

# Default MySQL credentials
MYSQL_DB="${MYSQL_DB:-panel}"
MYSQL_USER="${MYSQL_USER:-pterodactyl}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(gen_passwd 64)}"

# Environment
timezone="${timezone:-Europe/Stockholm}"
telemetry="${telemetry:-true}"

# Assume SSL, will fetch different config if true
ASSUME_SSL="${ASSUME_SSL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"

# Firewall
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"

# FNPanel extras
CONFIGURE_TIMESYNC_SERVER="${CONFIGURE_TIMESYNC_SERVER:-false}" # act as NTP server for nodes
TIMESYNC_ALLOW="${TIMESYNC_ALLOW:-}"                            # space-separated node IPs/subnets
INSTALL_BLUEPRINT="${INSTALL_BLUEPRINT:-false}"                 # install Blueprint framework
# Optional sha256 of panel.tar.gz; if set, the download is verified against it.
PANEL_SHA256="${PANEL_SHA256:-}"

# Must be assigned to work, no default values
email="${email:-}"
user_email="${user_email:-}"
user_username="${user_username:-}"
user_firstname="${user_firstname:-}"
user_lastname="${user_lastname:-}"
user_password="${user_password:-}"

missing=()

for var in email user_email user_username user_firstname user_lastname user_password; do
  if [[ -z "${!var}" ]]; then
    missing+=("$var")
  fi
done

if (( ${#missing[@]} > 0 )); then
  for m in "${missing[@]}"; do
    error "${m} is required"
  done
  exit 1
fi


# --------- Main installation functions -------- #

install_composer() {
  output "Installing composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  success "Composer installed!"
}

ptdl_dl() {
  output "Downloading panel files from $PANEL_DL_URL .. "
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit 1

  curl -fL -o panel.tar.gz "$PANEL_DL_URL"

  # Integrity: ensure we actually got a valid gzip archive. Catches HTML error
  # pages / truncated downloads before we try to extract them.
  if ! gzip -t panel.tar.gz 2>/dev/null; then
    error "Downloaded panel.tar.gz is not a valid archive (download failed?)."
    exit 1
  fi

  # Authenticity: only if the caller pinned a checksum via PANEL_SHA256.
  if [ -n "$PANEL_SHA256" ]; then
    output "Verifying SHA256 checksum..."
    echo "$PANEL_SHA256  panel.tar.gz" | sha256sum -c - || {
      error "Checksum verification failed!"
      exit 1
    }
  fi

  tar -xzf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env

  success "Downloaded panel files!"
}

install_composer_deps() {
  output "Installing composer dependencies.."
  [ "$OS" == "rocky" ] || [ "$OS" == "almalinux" ] && export PATH=/usr/local/bin:$PATH
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  success "Installed composer dependencies!"
}

# Configure environment
configure() {
  output "Configuring environment.."

  local app_url="http://$FQDN"
  [ "$ASSUME_SSL" == true ] && app_url="https://$FQDN"
  [ "$CONFIGURE_LETSENCRYPT" == true ] && app_url="https://$FQDN"

  # Generate encryption key
  php artisan key:generate --force

  # Fill in environment:setup automatically
  php artisan p:environment:setup \
    --author="$email" \
    --url="$app_url" \
    --timezone="$timezone" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --telemetry="$telemetry" \
    --settings-ui=true

  # Fill in environment:database credentials automatically
  php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$MYSQL_DB" \
    --username="$MYSQL_USER" \
    --password="$MYSQL_PASSWORD"

  # configures database
  php artisan migrate --seed --force

  # Create user account
  php artisan p:user:make \
    --email="$user_email" \
    --username="$user_username" \
    --name-first="$user_firstname" \
    --name-last="$user_lastname" \
    --password="$user_password" \
    --admin=1

  success "Configured environment!"
}

# set the correct folder permissions depending on OS and webserver
set_folder_permissions() {
  # if os is ubuntu or debian, we do this
  case "$OS" in
  debian | ubuntu)
    chown -R www-data:www-data ./*
    ;;
  rocky | almalinux)
    chown -R nginx:nginx ./*
    ;;
  esac
}

insert_cronjob() {
  output "Installing cronjob.. "

  # Full, explicit 5-field cron line (previously the 5th field was completed by the
  # log-prefix of output(), which was fragile).
  local cron_line="* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"

  # Idempotent: strip any previous pterodactyl schedule entry, then append ours once.
  # crontab -l exits non-zero when no crontab exists yet, so tolerate that.
  {
    crontab -l 2>/dev/null | grep -v -F "artisan schedule:run" || true
    echo "$cron_line"
  } | crontab -

  success "Cronjob installed!"
}

install_pteroq() {
  output "Installing pteroq service.."

  curl -o /etc/systemd/system/pteroq.service "$GITHUB_URL"/configs/pteroq.service

  case "$OS" in
  debian | ubuntu)
    sed -i -e "s@<user>@www-data@g" /etc/systemd/system/pteroq.service
    ;;
  rocky | almalinux)
    sed -i -e "s@<user>@nginx@g" /etc/systemd/system/pteroq.service
    ;;
  esac

  systemctl enable pteroq.service
  systemctl start pteroq

  success "Installed pteroq!"
}

# -------- OS specific install functions ------- #

enable_services() {
  case "$OS" in
  ubuntu | debian)
    systemctl enable redis-server
    systemctl start redis-server
    ;;
  rocky | almalinux)
    systemctl enable redis
    systemctl start redis
    ;;
  esac
  systemctl enable nginx
  systemctl enable mariadb
  systemctl start mariadb
}

selinux_allow() {
  setsebool -P httpd_can_network_connect 1 || true # these commands can fail OK
  setsebool -P httpd_execmem 1 || true
  setsebool -P httpd_unified 1 || true
}

php_fpm_conf() {
  curl -o /etc/php-fpm.d/www-pterodactyl.conf "$GITHUB_URL"/configs/www-pterodactyl.conf

  systemctl enable php-fpm
  systemctl start php-fpm
}

ubuntu_dep() {
  # Install deps for adding repos
  install_packages "software-properties-common apt-transport-https ca-certificates gnupg"

  # Add Ubuntu universe repo
  add-apt-repository universe -y
}

debian_dep() {
  # Install deps for adding repos
  install_packages "dirmngr ca-certificates apt-transport-https lsb-release"

  # Install PHP using sury's repo. Scope the key to THIS repo only via signed-by,
  # instead of dropping it into trusted.gpg.d (which would trust it system-wide).
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury-php.gpg
  echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    >/etc/apt/sources.list.d/php.list
}

alma_rocky_dep() {
  # SELinux tools
  install_packages "policycoreutils selinux-policy selinux-policy-targeted \
    setroubleshoot-server setools setools-console mcstrans"

  # add remi repo (php8.3)
  install_packages "epel-release http://rpms.remirepo.net/enterprise/remi-release-$OS_VER_MAJOR.rpm"
  dnf module enable -y php:remi-8.3
}

dep_install() {
  output "Installing dependencies for $OS $OS_VER..."

  # Update repos before installing
  update_repos

  [ "$CONFIGURE_FIREWALL" == true ] && install_firewall && firewall_ports

  case "$OS" in
  ubuntu | debian)
    [ "$OS" == "ubuntu" ] && ubuntu_dep
    debian_dep

    update_repos

    # Install dependencies
    install_packages "php8.3 php8.3-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
      mariadb-common mariadb-server mariadb-client \
      nginx \
      redis-server \
      zip unzip tar \
      git cron"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    ;;
  rocky | almalinux)
    alma_rocky_dep

    # Install dependencies
    install_packages "php php-{common,fpm,cli,json,mysqlnd,mcrypt,gd,mbstring,pdo,zip,bcmath,dom,opcache,posix} \
      mariadb mariadb-server \
      nginx \
      redis \
      zip unzip tar \
      git cronie"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    # Allow nginx
    selinux_allow

    # Create config for php fpm
    php_fpm_conf
    ;;
  esac

  enable_services

  success "Dependencies installed!"
}

# --------------- Other functions -------------- #

firewall_ports() {
  output "Opening ports: 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

  firewall_allow_ports "22 80 443"

  success "Firewall ports opened!"
}

letsencrypt() {
  FAILED=false

  output "Configuring Let's Encrypt..."

  # Obtain certificate
  certbot --nginx --redirect --no-eff-email --email "$email" -d "$FQDN" || FAILED=true

  # Check if it succeded
  if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
    warning "The process of obtaining a Let's Encrypt certificate failed!"
    echo -n "* Still assume SSL? (y/N): "
    read -r CONFIGURE_SSL

    if [[ "$CONFIGURE_SSL" =~ [Yy] ]]; then
      ASSUME_SSL=true
      CONFIGURE_LETSENCRYPT=false
      configure_nginx
    else
      ASSUME_SSL=false
      CONFIGURE_LETSENCRYPT=false
    fi
  else
    success "The process of obtaining a Let's Encrypt certificate succeeded!"
  fi
}

# ------ Webserver configuration functions ----- #

configure_nginx() {
  output "Configuring nginx .."

  if [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    DL_FILE="nginx_ssl.conf"
  else
    DL_FILE="nginx.conf"
  fi

  case "$OS" in
  ubuntu | debian)
    PHP_SOCKET="/run/php/php8.3-fpm.sock"
    CONFIG_PATH_AVAIL="/etc/nginx/sites-available"
    CONFIG_PATH_ENABL="/etc/nginx/sites-enabled"
    ;;
  rocky | almalinux)
    PHP_SOCKET="/var/run/php-fpm/pterodactyl.sock"
    CONFIG_PATH_AVAIL="/etc/nginx/conf.d"
    CONFIG_PATH_ENABL="$CONFIG_PATH_AVAIL"
    ;;
  esac

  rm -rf "$CONFIG_PATH_ENABL"/default

  curl -o "$CONFIG_PATH_AVAIL"/pterodactyl.conf "$GITHUB_URL"/configs/$DL_FILE

  sed -i -e "s@<domain>@${FQDN}@g" "$CONFIG_PATH_AVAIL"/pterodactyl.conf

  sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" "$CONFIG_PATH_AVAIL"/pterodactyl.conf

  case "$OS" in
  ubuntu | debian)
    ln -sf "$CONFIG_PATH_AVAIL"/pterodactyl.conf "$CONFIG_PATH_ENABL"/pterodactyl.conf
    ;;
  esac

  if [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    systemctl restart nginx
  fi

  success "Nginx configured!"
}

# --------------- Main functions --------------- #

perform_install() {
  output "Starting installation.. this might take a while!"
  dep_install
  install_composer
  ptdl_dl
  install_composer_deps
  create_db_user "$MYSQL_USER" "$MYSQL_PASSWORD"
  create_db "$MYSQL_DB" "$MYSQL_USER"
  configure
  set_folder_permissions
  insert_cronjob
  install_pteroq
  configure_nginx
  [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt

  # FNPanel: optionally make this machine an NTP time server for the nodes.
  if [ "$CONFIGURE_TIMESYNC_SERVER" == true ] && fn_exists configure_timesync_server; then
    configure_timesync_server "$TIMESYNC_ALLOW"
  fi

  # FNPanel: optionally install the Blueprint framework (themes/extensions).
  if [ "$INSTALL_BLUEPRINT" == true ] && fn_exists install_blueprint; then
    install_blueprint
  fi

  return 0
}

# ------------------- Install ------------------ #

perform_install
