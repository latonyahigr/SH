#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR="/opt/bookstack"
readonly LOCAL_PORT="6875"

log() {
    printf '\n[BookStack] %s\n' "$*"
}

fail() {
    printf '\n[BookStack] ERROR: %s\n' "$*" >&2
    exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Please run this script as root."

DOMAIN="${1:-}"
[[ -n "$DOMAIN" ]] || fail "Usage: bash install-bookstack.sh wiki.example.com"
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
    || fail "Invalid domain: $DOMAIN"

if [[ -e "$INSTALL_DIR/compose.yml" || -e "$INSTALL_DIR/.env" ]]; then
    fail "An existing deployment was found in $INSTALL_DIR. Nothing was changed."
fi

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "12" ]]; then
        log "Warning: this script was designed for Debian 12; detected ${PRETTY_NAME:-unknown OS}."
    fi
fi

export DEBIAN_FRONTEND=noninteractive
log "Installing basic packages"
apt-get update
apt-get install -y ca-certificates curl openssl

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Engine and Docker Compose"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

systemctl enable --now docker
docker compose version >/dev/null 2>&1 || fail "Docker Compose is unavailable after installation."

log "Creating persistent data directory"
install -d -m 700 "$INSTALL_DIR"
cd "$INSTALL_DIR"

umask 077
DB_ROOT_PASSWORD="$(openssl rand -hex 24)"
DB_PASSWORD="$(openssl rand -hex 24)"
APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"

{
    printf 'DB_ROOT_PASSWORD=%s\n' "$DB_ROOT_PASSWORD"
    printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD"
    printf 'APP_KEY=%s\n' "$APP_KEY"
} > .env
chmod 600 .env

cat > compose.yml <<EOF
services:
  bookstack-db:
    image: lscr.io/linuxserver/mariadb:latest
    container_name: bookstack-db
    restart: unless-stopped
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "Asia/Shanghai"
      MYSQL_ROOT_PASSWORD: "\${DB_ROOT_PASSWORD}"
      MYSQL_DATABASE: "bookstack"
      MYSQL_USER: "bookstack"
      MYSQL_PASSWORD: "\${DB_PASSWORD}"
    volumes:
      - ./db-config:/config
    networks:
      - bookstack-network

  bookstack:
    image: lscr.io/linuxserver/bookstack:latest
    container_name: bookstack
    restart: unless-stopped
    depends_on:
      - bookstack-db
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "Asia/Shanghai"
      APP_URL: "https://${DOMAIN}"
      APP_KEY: "\${APP_KEY}"
      DB_HOST: "bookstack-db"
      DB_PORT: "3306"
      DB_DATABASE: "bookstack"
      DB_USERNAME: "bookstack"
      DB_PASSWORD: "\${DB_PASSWORD}"
    volumes:
      - ./app-config:/config
    ports:
      - "127.0.0.1:${LOCAL_PORT}:80"
    networks:
      - bookstack-network

networks:
  bookstack-network:
    name: bookstack-network
EOF
chmod 600 compose.yml

log "Downloading and starting BookStack"
docker compose pull
docker compose up -d

log "Container status"
docker compose ps

cat <<EOF

Installation command completed.

Next steps in aaPanel/BT Panel:
  1. Create website: ${DOMAIN}
  2. Add reverse proxy to: http://127.0.0.1:${LOCAL_PORT}
  3. Apply for a Let's Encrypt certificate and enable forced HTTPS
  4. Visit: https://${DOMAIN}

Initial BookStack login:
  Email:    admin@admin.com
  Password: password

Change the initial email and password immediately after login.
Persistent data: ${INSTALL_DIR}
EOF
