#!/usr/bin/env bash
#
# ==============================================================================
#  Debian VPS All-In-One Setup Script (IP-only, self-signed TLS)
#  Stack: Nginx + PHP-FPM + Self-Signed SSL + UFW Firewall + Fail2Ban + Xray
#  Tested on: Debian 11 / 12
# ==============================================================================
#
#  USAGE:
#    1. Copy this script to your VPS (as root or a sudo user)
#    2. chmod +x vps-setup.sh
#    3. sudo ./vps-setup.sh
#       (public IP is auto-detected; no domain or email needed)
#
#  WHAT IT DOES:
#    - Updates system packages
#    - Sets up UFW firewall (allows SSH, HTTP, HTTPS only)
#    - Installs and configures Fail2Ban (brute-force protection)
#    - Installs Nginx + PHP-FPM (latest available PHP version)
#    - Creates a sample site at /var/www/site
#    - Generates a self-signed TLS certificate for the server's public IP
#    - Installs Xray (VLESS + WebSocket + TLS), reverse-proxied behind Nginx
#      on the same 443 port, sharing the same self-signed cert
#
#  NOTE ON SELF-SIGNED + IP-ONLY TLS:
#    Browsers and most clients will show a trust warning / require you to
#    manually accept or pin the certificate, since it isn't issued by a
#    public CA. This setup is intended for personal/private use (your own
#    devices connecting to your own server) — not for public-facing sites,
#    and it does not disguise itself as ordinary traffic to outside
#    observers the way a domain + real CA cert would.
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

# ==============================================================================
# 0. DETECT PUBLIC IP
# ==============================================================================
log "Detecting public IP address..."
apt-get update -y -qq
apt-get install -y -qq curl >/dev/null

SERVER_IP=""
for svc in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
  SERVER_IP=$(curl -fsSL --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    break
  fi
  SERVER_IP=""
done

if [[ -z "$SERVER_IP" ]]; then
  err "Could not auto-detect public IP."
  read -p "Enter your server's public IP manually: " SERVER_IP
  until [[ "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; do
    read -p "That doesn't look like a valid IPv4 address. Enter it again: " SERVER_IP
  done
fi

WEBROOT="/var/www/site"

log "Detected public IP: ${SERVER_IP}"
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
apt-get install -y wget gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common unzip openssl

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
# 6. SELF-SIGNED TLS CERTIFICATE (for the server's IP)
# ==============================================================================
log "Generating self-signed TLS certificate for ${SERVER_IP}..."
CERT_DIR="/etc/nginx/ssl"
mkdir -p "${CERT_DIR}"

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${CERT_DIR}/selfsigned.key" \
  -out "${CERT_DIR}/selfsigned.crt" \
  -days 3650 \
  -subj "/CN=${SERVER_IP}" \
  -addext "subjectAltName=IP:${SERVER_IP}"

chmod 600 "${CERT_DIR}/selfsigned.key"
log "Self-signed certificate created (valid 10 years): ${CERT_DIR}/selfsigned.crt"

# ==============================================================================
# 7. SAMPLE SITE + NGINX SERVER BLOCK (HTTP -> HTTPS, IP-based)
# ==============================================================================
log "Creating webroot at ${WEBROOT}..."
mkdir -p "${WEBROOT}"
chown -R www-data:www-data "${WEBROOT}"

cat > "${WEBROOT}/index.php" <<EOF
<?php
echo "<h1>It works! (${SERVER_IP})</h1>";
echo "<p>PHP version: " . phpversion() . "</p>";
EOF
chown www-data:www-data "${WEBROOT}/index.php"

log "Writing Nginx server block..."
cat > "/etc/nginx/sites-available/site" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_IP};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${SERVER_IP};

    ssl_certificate     ${CERT_DIR}/selfsigned.crt;
    ssl_certificate_key ${CERT_DIR}/selfsigned.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

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

ln -sf "/etc/nginx/sites-available/site" "/etc/nginx/sites-enabled/site"

# Remove default site if present, to avoid conflicts
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

# ==============================================================================
# 8. XRAY (VLESS + WebSocket + TLS, behind Nginx on port 443)
# ==============================================================================
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

log "Adding Xray WebSocket proxy block into Nginx config (behind the self-signed cert)..."
NGINX_CONF="/etc/nginx/sites-available/site"

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
# (the HTTPS server block, since it comes after the HTTP redirect block)
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

# ==============================================================================
# 9. SUMMARY
# ==============================================================================
echo
log "=========================================="
log " Setup complete!"
log "=========================================="
echo " Webroot:      ${WEBROOT}"
echo " Nginx config: /etc/nginx/sites-available/site"
echo " PHP version:  ${PHP_VERSION}"
echo " Firewall:     ufw status"
echo " Fail2Ban:     fail2ban-client status sshd"
echo " TLS cert:     ${CERT_DIR}/selfsigned.crt (self-signed, 10yr, CN=${SERVER_IP})"
echo " Site:         https://${SERVER_IP}  (browser will warn: self-signed cert)"

echo
log "=========================================="
log " Xray (VLESS + WS + TLS) connection info"
log "=========================================="
echo " Address:      ${SERVER_IP}"
echo " Port:         443"
echo " UUID:         ${XRAY_UUID}"
echo " Network:      ws"
echo " Path:         ${XRAY_WS_PATH}"
echo " TLS:          on (self-signed — client must enable 'allow insecure' / skip cert verify)"
echo " Service:      systemctl status xray"
echo " Config file:  /usr/local/etc/xray/config.json"
echo
echo " vless://${XRAY_UUID}@${SERVER_IP}:443?encryption=none&security=tls&type=ws&host=${SERVER_IP}&path=${XRAY_WS_PATH}&allowInsecure=1#${SERVER_IP}"
echo
warn "Self-signed cert: clients (browsers, Xray/V2Ray apps) must explicitly trust"
warn "or bypass certificate verification, since no public CA issued this cert."
echo
log "Done."
