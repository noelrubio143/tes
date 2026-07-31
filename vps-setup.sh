#!/usr/bin/env bash
#
# ==============================================================================
#  Debian VPS All-In-One Setup Script
#  Stack: Nginx + PHP-FPM + Let's Encrypt SSL + UFW Firewall + Fail2Ban + Xray
#  Tested on: Debian 11 / 12
# ==============================================================================
#
#  USAGE:
#    1. Copy this script to your VPS (as root or a sudo user)
#    2. chmod +x vps-setup.sh
#    3. sudo ./vps-setup.sh
#       (you'll be prompted to enter your domain and email interactively)
#
#  WHAT IT DOES:
#    - Updates system packages
#    - Sets up UFW firewall (allows SSH, HTTP, HTTPS only)
#    - Installs and configures Fail2Ban (brute-force protection)
#    - Installs Nginx + PHP-FPM (latest available PHP version)
#    - Creates a sample site at /var/www/yourdomain.com
#    - Issues a free SSL certificate via Let's Encrypt (Certbot)
#    - Sets up automatic SSL renewal
#    - Installs Xray (VLESS + WebSocket + TLS), reverse-proxied behind Nginx
#      on the same 443 port and domain/cert (path-based routing so the
#      website and Xray share the port without conflict)
#
# ==============================================================================

set -euo pipefail

# ---------- Colors for output ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

# ---------- Sanity checks ----------
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root (use sudo)."
  exit 1
fi

echo
read -p "Enter your domain (e.g. example.com): " DOMAIN
until [[ -n "$DOMAIN" ]]; do
  read -p "Domain cannot be empty. Enter your domain: " DOMAIN
done

read -p "Enter your email (for SSL registration, e.g. admin@example.com): " EMAIL
until [[ -n "$EMAIL" ]]; do
  read -p "Email cannot be empty. Enter your email: " EMAIL
done

WEBROOT="/var/www/${DOMAIN}"

log "Domain: ${DOMAIN}"
log "Email:  ${EMAIL}"
log "Webroot: ${WEBROOT}"
echo
read -p "Continue with these settings? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  warn "Aborted by user."
  exit 0
fi

# ==============================================================================
# 1. SYSTEM UPDATE
# ==============================================================================
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common unzip

# ==============================================================================
# 2. FIREWALL (UFW)
# ==============================================================================
log "Configuring UFW firewall..."
apt-get install -y ufw

ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 'Nginx Full'   # opens 80 + 443
ufw --force enable

log "Firewall status:"
ufw status verbose

# ==============================================================================
# 3. FAIL2BAN (brute-force protection for SSH etc.)
# ==============================================================================
log "Installing Fail2Ban..."
apt-get install -y fail2ban

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# ==============================================================================
# 4. NGINX
# ==============================================================================
log "Installing Nginx..."
apt-get install -y nginx

systemctl enable nginx
systemctl start nginx

# ==============================================================================
# 5. PHP-FPM + common extensions
# ==============================================================================
log "Installing PHP-FPM and common extensions..."
apt-get install -y php-fpm php-cli php-common php-mysql php-curl php-gd \
  php-mbstring php-xml php-zip php-bcmath php-intl

PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
log "Detected PHP version: ${PHP_VERSION}"

systemctl enable "php${PHP_VERSION}-fpm"
systemctl start "php${PHP_VERSION}-fpm"

# ==============================================================================
# 6. SAMPLE SITE + NGINX SERVER BLOCK
# ==============================================================================
log "Creating webroot at ${WEBROOT}..."
mkdir -p "${WEBROOT}"
chown -R www-data:www-data "${WEBROOT}"

cat > "${WEBROOT}/index.php" <<EOF
<?php
echo "<h1>It works! (${DOMAIN})</h1>";
echo "<p>PHP version: " . phpversion() . "</p>";
EOF
chown www-data:www-data "${WEBROOT}/index.php"

log "Writing Nginx server block..."
cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${WEBROOT};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~ /\.ht {
        deny all;
    }

    client_max_body_size 64M;
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"

# Remove default site if present, to avoid conflicts
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

# ==============================================================================
# 7. SSL VIA LET'S ENCRYPT (CERTBOT)
# ==============================================================================
log "Installing Certbot..."
apt-get install -y certbot python3-certbot-nginx

log "Requesting SSL certificate for ${DOMAIN} and www.${DOMAIN}..."
warn "Make sure both DNS A records point to this server's IP BEFORE this step, or it will fail."

set +e
certbot --nginx \
  -d "${DOMAIN}" -d "www.${DOMAIN}" \
  --non-interactive --agree-tos -m "${EMAIL}" --redirect
CERTBOT_STATUS=$?
set -e

if [[ $CERTBOT_STATUS -ne 0 ]]; then
  warn "Certbot failed. This is usually a DNS issue (A record not pointing here yet)."
  warn "Once DNS is correct, re-run manually with:"
  warn "  certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --agree-tos -m ${EMAIL}"
else
  log "SSL certificate issued successfully."
  # Ensure auto-renewal timer is active
  systemctl enable certbot.timer
  systemctl start certbot.timer
  log "Auto-renewal enabled (certbot.timer)."
fi

# ==============================================================================
# 8. XRAY (VLESS + WebSocket + TLS, behind Nginx on port 443)
# ==============================================================================
XRAY_INSTALLED=0
XRAY_UUID=""
XRAY_WS_PATH=""

if [[ $CERTBOT_STATUS -eq 0 ]]; then
  log "Installing Xray..."

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
  XRAY_WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)-ws"
  XRAY_PORT=10000

  log "Writing Xray config..."
  mkdir -p /usr/local/etc/xray
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${XRAY_WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

  systemctl enable xray
  systemctl restart xray
  XRAY_INSTALLED=1

  log "Adding Xray WebSocket proxy block into Nginx config (behind existing TLS)..."
  # Certbot already added a listen 443 ssl server block for $DOMAIN.
  # We inject a location block for the Xray WS path into that same server block,
  # right before its closing brace, so it shares the domain + certificate.
  NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"

  # Build the location block to inject
  XRAY_LOCATION=$(cat <<EOF
    location ${XRAY_WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
EOF
)

  # Insert the location block into the LAST closing "}" of the file
  # (that's the end of the SSL server block Certbot created)
  awk -v block="$XRAY_LOCATION" '
    { lines[NR] = $0 }
    END {
      last_brace = 0
      for (i = NR; i >= 1; i--) {
        if (lines[i] ~ /^}/) { last_brace = i; break }
      }
      for (i = 1; i <= NR; i++) {
        if (i == last_brace) { print block }
        print lines[i]
      }
    }
  ' "$NGINX_CONF" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "$NGINX_CONF"

  nginx -t
  systemctl reload nginx

  log "Xray installed and wired behind Nginx."
else
  warn "Skipping Xray setup: SSL certificate was not issued (Xray needs a valid cert + working domain)."
  warn "Fix DNS, re-run certbot successfully, then re-run this script or install Xray manually."
fi

# ==============================================================================
# 9. SUMMARY
# ==============================================================================
echo
log "=========================================="
log " Setup complete!"
log "=========================================="
echo " Webroot:      ${WEBROOT}"
echo " Nginx config: /etc/nginx/sites-available/${DOMAIN}"
echo " PHP version:  ${PHP_VERSION}"
echo " Firewall:     ufw status"
echo " Fail2Ban:     fail2ban-client status sshd"
if [[ $CERTBOT_STATUS -eq 0 ]]; then
  echo " Site:         https://${DOMAIN}"
else
  echo " Site:         http://${DOMAIN}  (SSL pending - fix DNS and re-run certbot)"
fi

if [[ $XRAY_INSTALLED -eq 1 ]]; then
  echo
  log "=========================================="
  log " Xray (VLESS + WS + TLS) connection info"
  log "=========================================="
  echo " Address:      ${DOMAIN}"
  echo " Port:         443"
  echo " UUID:         ${XRAY_UUID}"
  echo " Network:      ws"
  echo " Path:         ${XRAY_WS_PATH}"
  echo " TLS:          on"
  echo " Service:      systemctl status xray"
  echo " Config file:  /usr/local/etc/xray/config.json"
  echo
  echo " vless://${XRAY_UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${XRAY_WS_PATH}#${DOMAIN}"
else
  echo " Xray:         not installed (SSL cert was required first)"
fi
echo
log "Done."