#!/bin/bash

################################################################################
# ALL-IN-ONE COMPLETE SCRIPT
# SSH + WebSocket + Nginx + Xray + Utilities + Config Examples
# Author: Network Admin
# Description: Complete setup for secure proxy infrastructure
# Supported OS: Ubuntu 20.04+ / Debian 10+
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Variables
DOMAIN="${1:ambersvpn.shop}"
EMAIL="${2:jieromvilla23@gmail.com}"
SSH_PORT="22"
WS_PORT="8080"
NGINX_PORT_HTTP="80"
NGINX_PORT_HTTPS="443"
XRAY_PORT_VLESS="443"
XRAY_PORT_VMESS="10000"
XRAY_CONFIG="/etc/xray/config.json"
NGINX_CONFIG="/etc/nginx/sites-available/xray"
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
USER_HOME="/root"
SCRIPT_MODE="install"

################################################################################
# UTILITY FUNCTIONS - MAIN SCRIPT
################################################################################

print_header() {
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}===============================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        print_error "Cannot detect operating system"
        exit 1
    fi
    print_success "Detected OS: $OS $VERSION"
}

update_system() {
    print_header "Updating System Packages"
    apt-get update
    apt-get upgrade -y
    print_success "System updated"
}

install_dependencies() {
    print_header "Installing Dependencies"
    apt-get install -y \
        curl \
        wget \
        git \
        vim \
        nano \
        htop \
        net-tools \
        ufw \
        fail2ban \
        certbot \
        python3-certbot-nginx \
        nginx \
        openssh-server \
        openssh-client \
        ssl-cert \
        openssl \
        unzip \
        jq \
        supervisor \
        systemd \
        ca-certificates \
        python3-websockets
    
    print_success "Dependencies installed"
}

################################################################################
# SSH CONFIGURATION
################################################################################

configure_ssh() {
    print_header "Configuring SSH"
    
    if [ ! -f /etc/ssh/sshd_config.backup ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    fi
    
    sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/" /etc/ssh/sshd_config
    sed -i "s/#PasswordAuthentication yes/PasswordAuthentication yes/" /etc/ssh/sshd_config
    sed -i "s/X11Forwarding yes/X11Forwarding no/" /etc/ssh/sshd_config
    
    if ! grep -q "ClientAliveInterval" /etc/ssh/sshd_config; then
        echo "ClientAliveInterval 60" >> /etc/ssh/sshd_config
        echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config
    fi
    
    systemctl enable ssh
    systemctl restart ssh
    
    print_success "SSH configured on port $SSH_PORT"
}

################################################################################
# WEBSOCKET PROXY SETUP
################################################################################

setup_websocket_proxy() {
    print_header "Setting Up WebSocket Proxy"
    
    cat > /usr/local/bin/ws-proxy.py << 'EOFPYTHON'
#!/usr/bin/env python3
"""
Simple WebSocket to SSH proxy
"""
import asyncio
import websockets
import socket
import sys
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

WS_PORT = 8080
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
BUFFER_SIZE = 4096

async def handle_client(websocket, path):
    """Handle WebSocket connection and proxy to SSH"""
    try:
        reader, writer = await asyncio.open_connection(SSH_HOST, SSH_PORT)
        
        async def ws_to_ssh():
            """Forward messages from WebSocket to SSH"""
            try:
                async for message in websocket:
                    if isinstance(message, bytes):
                        writer.write(message)
                        await writer.drain()
            except Exception as e:
                logger.error(f"WS to SSH error: {e}")
            finally:
                writer.close()
                await writer.wait_closed()
        
        async def ssh_to_ws():
            """Forward data from SSH to WebSocket"""
            try:
                while True:
                    data = await reader.readexactly(BUFFER_SIZE)
                    if not data:
                        break
                    await websocket.send(data)
            except asyncio.IncompleteReadError:
                pass
            except Exception as e:
                logger.error(f"SSH to WS error: {e}")
            finally:
                await websocket.close()
        
        await asyncio.gather(ws_to_ssh(), ssh_to_ws())
        
    except Exception as e:
        logger.error(f"Connection error: {e}")
        await websocket.close()

async def main():
    logger.info(f"Starting WebSocket proxy on ws://0.0.0.0:{WS_PORT}")
    async with websockets.serve(handle_client, "0.0.0.0", WS_PORT):
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
EOFPYTHON
    
    chmod +x /usr/local/bin/ws-proxy.py
    
    cat > /etc/systemd/system/ws-proxy.service << 'EOFSERVICE'
[Unit]
Description=WebSocket to SSH Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ws-proxy.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOFSERVICE
    
    systemctl daemon-reload
    systemctl enable ws-proxy
    systemctl restart ws-proxy
    
    print_success "WebSocket proxy configured on port $WS_PORT"
}

################################################################################
# SSL CERTIFICATE SETUP
################################################################################

setup_ssl_certificate() {
    print_header "Setting Up SSL Certificate"
    
    if [ ! -d "$CERT_PATH" ]; then
        print_warning "Requesting SSL certificate for $DOMAIN"
        certbot certonly --standalone -d "$DOMAIN" \
            --email "$EMAIL" \
            --agree-tos \
            -n \
            --no-eff-email || {
            print_warning "Let's Encrypt failed, using self-signed certificate"
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout /etc/ssl/private/xray.key \
                -out /etc/ssl/certs/xray.crt \
                -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN"
        }
    fi
    
    if [ ! -f /etc/ssl/private/xray.key ]; then
        if [ -d "$CERT_PATH" ]; then
            ln -sf "$CERT_PATH/privkey.pem" /etc/ssl/private/xray.key
            ln -sf "$CERT_PATH/fullchain.pem" /etc/ssl/certs/xray.crt
        fi
    fi
    
    print_success "SSL certificate ready"
}

################################################################################
# NGINX CONFIGURATION
################################################################################

setup_nginx() {
    print_header "Configuring Nginx"
    
    rm -f /etc/nginx/sites-enabled/default
    
    cat > "$NGINX_CONFIG" << 'EOFNGINX'
upstream xray_backend {
    server 127.0.0.1:10000;
}

upstream ws_backend {
    server 127.0.0.1:8080;
}

server {
    listen 80;
    listen [::]:80;
    server_name _;
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name _;
    
    ssl_certificate /etc/ssl/certs/xray.crt;
    ssl_certificate_key /etc/ssl/private/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    location /ws {
        proxy_pass http://ws_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        proxy_connect_timeout 7d;
        proxy_send_timeout 7d;
        proxy_read_timeout 7d;
    }
    
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
    
    location / {
        return 404;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;
    
    ssl_certificate /etc/ssl/certs/xray.crt;
    ssl_certificate_key /etc/ssl/private/xray.key;
    
    location / {
        return 404;
    }
}
EOFNGINX
    
    ln -sf "$NGINX_CONFIG" /etc/nginx/sites-enabled/xray
    
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    
    print_success "Nginx configured"
}

################################################################################
# XRAY INSTALLATION
################################################################################

install_xray() {
    print_header "Installing Xray"
    
    mkdir -p /etc/xray
    mkdir -p /var/log/xray
    mkdir -p /usr/local/bin
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
        || bash -c "$(wget -O- https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    print_success "Xray installed"
}

generate_xray_config() {
    print_header "Generating Xray Configuration"
    
    UUID_VLESS=$(xray uuid)
    UUID_VMESS=$(xray uuid)
    
    cat > "$XRAY_CONFIG" << EOFCONFIG
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID_VLESS",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/ssl/certs/xray.crt",
              "keyFile": "/etc/ssl/private/xray.key"
            }
          ]
        }
      }
    },
    {
      "port": 10000,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID_VMESS",
            "level": 0,
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/ws"
        },
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/ssl/certs/xray.crt",
              "keyFile": "/etc/ssl/private/xray.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOFCONFIG
    
    chmod 644 "$XRAY_CONFIG"
    
    print_success "Xray configuration generated"
    print_warning "VLESS UUID: $UUID_VLESS"
    print_warning "VMESS UUID: $UUID_VMESS"
}

enable_xray_service() {
    print_header "Enabling Xray Service"
    
    systemctl enable xray
    systemctl restart xray
    
    sleep 2
    
    if systemctl is-active --quiet xray; then
        print_success "Xray service is running"
    else
        print_error "Xray service failed to start"
        journalctl -u xray -n 20
    fi
}

################################################################################
# FIREWALL CONFIGURATION
################################################################################

setup_firewall() {
    print_header "Configuring Firewall"
    
    ufw --force enable
    ufw default deny incoming
    ufw default allow outgoing
    
    ufw allow "$SSH_PORT/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "$WS_PORT/tcp"
    ufw allow "$XRAY_PORT_VMESS/tcp"
    
    print_success "Firewall configured"
}

################################################################################
# FAIL2BAN CONFIGURATION
################################################################################

setup_fail2ban() {
    print_header "Configuring Fail2Ban"
    
    cat > /etc/fail2ban/jail.local << 'EOFJAIL'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log

[nginx-limit-req]
enabled = true
port = http,https
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
EOFJAIL
    
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    print_success "Fail2Ban configured"
}

################################################################################
# SYSTEM OPTIMIZATION
################################################################################

optimize_system() {
    print_header "Optimizing System"
    
    cat >> /etc/security/limits.conf << 'EOFLIMITS'
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
EOFLIMITS
    
    cat >> /etc/sysctl.conf << 'EOFSYSCTL'

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 10000 65000
net.core.somaxconn = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
EOFSYSCTL
    
    sysctl -p > /dev/null
    
    print_success "System optimized"
}

################################################################################
# LOGGING CONFIGURATION
################################################################################

setup_logging() {
    print_header "Setting Up Logging"
    
    cat > /etc/logrotate.d/xray << 'EOFLOGROTATE'
/var/log/xray/*.log {
    daily
    missingok
    rotate 10
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl reload xray > /dev/null 2>&1 || true
    endscript
}
EOFLOGROTATE
    
    print_success "Logging configured"
}

################################################################################
# DISPLAY INFORMATION
################################################################################

show_connection_info() {
    print_header "Connection Information"
    
    PUBLIC_IP=$(curl -s https://api.ipify.org || echo "your_server_ip")
    
    cat << EOFINFO

${CYAN}═══════════════════════════════════════════════════════════${NC}
${CYAN}                   Connection Details${NC}
${CYAN}═══════════════════════════════════════════════════════════${NC}

Server IP: ${MAGENTA}$PUBLIC_IP${NC}
Domain: ${MAGENTA}$DOMAIN${NC}

${GREEN}🔌 SSH Connection${NC}
   Protocol: SSH
   Host: $PUBLIC_IP
   Port: $SSH_PORT
   Command: ssh -p $SSH_PORT root@$PUBLIC_IP

${GREEN}🌐 WebSocket Proxy${NC}
   Protocol: WebSocket
   URL: wss://$DOMAIN/ws
   Port: 443 (via Nginx)
   Internal Port: $WS_PORT

${GREEN}🔐 Xray VLESS${NC}
   Protocol: VLESS
   Address: $PUBLIC_IP
   Port: $XRAY_PORT_VLESS
   TLS: true
   UUID: $(grep -oP '"id":\s*"\K[^"]+' $XRAY_CONFIG | head -1)

${GREEN}🔐 Xray VMESS (WebSocket)${NC}
   Protocol: VMESS
   Address: $PUBLIC_IP or $DOMAIN
   Port: 443
   TLS: true
   Path: /ws
   UUID: $(grep -oP '"id":\s*"\K[^"]+' $XRAY_CONFIG | tail -1)
   AlterID: 0
   Network: WebSocket

${GREEN}📝 Logs${NC}
   Nginx: /var/log/nginx/access.log
   Xray: /var/log/xray/access.log
   System: journalctl -u xray

${GREEN}🛡️ Firewall Status${NC}
$(ufw status)

${CYAN}═══════════════════════════════════════════════════════════${NC}

EOFINFO
}

show_usage() {
    cat << 'EOFUSAGE'

╔════════════════════════════════════════════════════════════════╗
║              Service Management Commands                       ║
╚════════════════════════════════════════════════════════════════╝

SSH Service:
   systemctl status ssh
   systemctl restart ssh

WebSocket Proxy:
   systemctl status ws-proxy
   systemctl restart ws-proxy
   journalctl -u ws-proxy -f

Nginx:
   systemctl status nginx
   systemctl restart nginx
   nginx -t

Xray:
   systemctl status xray
   systemctl restart xray
   journalctl -u xray -f
   xray -test -c /etc/xray/config.json

For more utilities, use: script.sh utilities [command]

═════════════════════════════════════════════════════════════════

EOFUSAGE
}

################################################################################
# UTILITY FUNCTIONS - MANAGEMENT
################################################################################

service_status() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          Service Status Monitor${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
    
    for service in ssh ws-proxy nginx xray; do
        status=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
        if [ "$status" = "active" ]; then
            echo -e "${GREEN}✓${NC} $service: ${GREEN}ACTIVE${NC}"
        else
            echo -e "${RED}✗${NC} $service: ${RED}INACTIVE${NC}"
        fi
    done
    
    echo -e "\n${BLUE}Port Status:${NC}\n"
    netstat -tulpn 2>/dev/null | grep -E ':(22|80|443|8080|10000)' || ss -tulpn 2>/dev/null | grep -E ':(22|80|443|8080|10000)'
}

view_logs() {
    local service=$1
    
    case "$service" in
        ssh)
            echo "SSH Logs:"
            journalctl -u ssh -n 50 -f
            ;;
        ws)
            echo "WebSocket Proxy Logs:"
            journalctl -u ws-proxy -n 50 -f
            ;;
        nginx)
            echo "Nginx Logs:"
            tail -f /var/log/nginx/error.log
            ;;
        xray)
            echo "Xray Logs:"
            tail -f /var/log/xray/access.log
            ;;
        *)
            echo "Usage: script.sh utilities logs [ssh|ws|nginx|xray]"
            ;;
    esac
}

generate_uuid() {
    if command -v xray &> /dev/null; then
        echo -e "${GREEN}New UUID:${NC}"
        xray uuid
    else
        echo "Xray is not installed"
        return 1
    fi
}

add_xray_user() {
    local email=$1
    local uuid=$(xray uuid)
    
    if [ -z "$email" ]; then
        read -p "Enter email/username for new user: " email
    fi
    
    echo -e "${YELLOW}Adding user: $email${NC}"
    echo "UUID: $uuid"
    
    cp /etc/xray/config.json /etc/xray/config.json.bak
    
    if command -v jq &> /dev/null; then
        jq ".inbounds[0].settings.clients += [{\"id\": \"$uuid\", \"level\": 0, \"email\": \"$email\"}]" \
            /etc/xray/config.json > /tmp/config.json && \
            mv /tmp/config.json /etc/xray/config.json
        
        xray -test -c /etc/xray/config.json
        
        if [ $? -eq 0 ]; then
            systemctl restart xray
            echo -e "${GREEN}✓ User added successfully${NC}"
        else
            echo -e "${RED}✗ Config error, restoring backup${NC}"
            cp /etc/xray/config.json.bak /etc/xray/config.json
            return 1
        fi
    else
        echo -e "${RED}jq is required to add users${NC}"
        return 1
    fi
}

remove_xray_user() {
    local uuid=$1
    
    if [ -z "$uuid" ]; then
        read -p "Enter UUID to remove: " uuid
    fi
    
    echo -e "${YELLOW}Removing user with UUID: $uuid${NC}"
    
    cp /etc/xray/config.json /etc/xray/config.json.bak
    
    if command -v jq &> /dev/null; then
        jq ".inbounds[0].settings.clients |= map(select(.id != \"$uuid\"))" \
            /etc/xray/config.json > /tmp/config.json && \
            mv /tmp/config.json /etc/xray/config.json
        
        xray -test -c /etc/xray/config.json && \
            systemctl restart xray && \
            echo -e "${GREEN}✓ User removed successfully${NC}" || \
            { cp /etc/xray/config.json.bak /etc/xray/config.json; return 1; }
    fi
}

list_xray_users() {
    echo -e "${BLUE}Xray Users:${NC}\n"
    
    if command -v jq &> /dev/null; then
        jq -r '.inbounds[0].settings.clients[] | "\(.email // "No email"): \(.id)"' /etc/xray/config.json
    else
        grep -o '"id":\s*"[^"]*"' /etc/xray/config.json | cut -d'"' -f4
    fi
}

health_check() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          System Health Check${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${YELLOW}CPU Usage:${NC}"
    top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print "Idle: " $1 "%"}'
    
    echo -e "\n${YELLOW}Memory Usage:${NC}"
    free -h | grep Mem
    
    echo -e "\n${YELLOW}Disk Usage:${NC}"
    df -h /
    
    echo -e "\n${YELLOW}Load Average:${NC}"
    cat /proc/loadavg
}

test_nginx() {
    echo -e "${BLUE}Testing Nginx Configuration${NC}\n"
    
    if nginx -t; then
        echo -e "${GREEN}✓ Nginx configuration is valid${NC}"
    else
        echo -e "${RED}✗ Nginx configuration has errors${NC}"
        return 1
    fi
}

test_xray() {
    echo -e "${BLUE}Testing Xray Configuration${NC}\n"
    
    if xray -test -c /etc/xray/config.json; then
        echo -e "${GREEN}✓ Xray configuration is valid${NC}"
    else
        echo -e "${RED}✗ Xray configuration has errors${NC}"
        return 1
    fi
}

restart_all() {
    echo -e "${YELLOW}Restarting all services...${NC}\n"
    
    services=(ssh ws-proxy nginx xray)
    for service in "${services[@]}"; do
        echo "Restarting $service..."
        systemctl restart "$service" && echo -e "${GREEN}✓ $service restarted${NC}" || echo -e "${RED}✗ $service failed${NC}"
    done
}

backup_config() {
    local backup_dir="/backup"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/xray-config-$timestamp.tar.gz"
    
    mkdir -p "$backup_dir"
    
    echo -e "${YELLOW}Creating backup...${NC}"
    tar -czf "$backup_file" /etc/xray /etc/nginx /etc/ssh/sshd_config
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Backup created: $backup_file${NC}"
        ls -lh "$backup_file"
    else
        echo -e "${RED}✗ Backup failed${NC}"
        return 1
    fi
}

cert_info() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          SSL Certificate Information${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
    
    if [ -f /etc/ssl/certs/xray.crt ]; then
        openssl x509 -in /etc/ssl/certs/xray.crt -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After|Public-Key:"
    else
        echo "Certificate not found"
    fi
    
    expiry=$(openssl x509 -in /etc/ssl/certs/xray.crt -noout -dates | grep "notAfter" | cut -d= -f2)
    echo -e "\n${YELLOW}Expiration Date: $expiry${NC}"
}

show_firewall() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          Firewall Rules (UFW)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
    
    ufw status
    
    echo -e "\n${BLUE}Detailed Rules:${NC}"
    ufw show added
}

show_config_examples() {
    print_header "Xray Configuration Examples"
    
    cat << 'EOFEXAMPLES'

╔════════════════════════════════════════════════════════════════╗
║           XRAY CONFIGURATION EXAMPLES                          ║
╚════════════════════════════════════════════════════════════════╝

1. MULTIPLE USERS VLESS
──────────────────────────────────────────────────────────────────
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "uuid1", "level": 0, "email": "user1@example.com"},
        {"id": "uuid2", "level": 0, "email": "user2@example.com"},
        {"id": "uuid3", "level": 1, "email": "premium@example.com"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/ssl/certs/xray.crt",
          "keyFile": "/etc/ssl/private/xray.key"
        }]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}

2. TROJAN PROTOCOL
──────────────────────────────────────────────────────────────────
{
  "inbounds": [{
    "port": 443,
    "protocol": "trojan",
    "settings": {
      "clients": [
        {"password": "your-trojan-password-here"}
      ]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/ssl/certs/xray.crt",
          "keyFile": "/etc/ssl/private/xray.key"
        }]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}

3. WEBSOCKET WITH HTTP MASQUERADE
──────────────────────────────────────────────────────────────────
{
  "inbounds": [{
    "port": 443,
    "protocol": "vmess",
    "settings": {
      "clients": [{"id": "uuid-here", "alterId": 0}]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/ray",
        "headers": {
          "Host": "example.com",
          "User-Agent": "Mozilla/5.0"
        }
      },
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/ssl/certs/xray.crt",
          "keyFile": "/etc/ssl/private/xray.key"
        }]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}

4. GRPC PROTOCOL
──────────────────────────────────────────────────────────────────
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "uuid-here"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "grpc",
      "grpcSettings": {"serviceName": "ray"},
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/ssl/certs/xray.crt",
          "keyFile": "/etc/ssl/private/xray.key"
        }]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}

5. ADVANCED ROUTING
──────────────────────────────────────────────────────────────────
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "uuid-here"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/ssl/certs/xray.crt",
          "keyFile": "/etc/ssl/private/xray.key"
        }]
      }
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "ip": ["geoip:private", "geoip:cn"],
        "outboundTag": "direct"
      }
    ]
  }
}

═════════════════════════════════════════════════════════════════

EOFEXAMPLES
}

################################################################################
# UTILITIES MENU
################################################################################

show_utilities_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     AIO SSH + WS + Nginx + Xray Utilities             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${YELLOW}Service Management:${NC}"
    echo "1.  Show service status"
    echo "2.  View logs"
    echo "3.  Restart all services"
    
    echo -e "\n${YELLOW}Xray User Management:${NC}"
    echo "4.  Add Xray user"
    echo "5.  Remove Xray user"
    echo "6.  List Xray users"
    echo "7.  Generate new UUID"
    
    echo -e "\n${YELLOW}Monitoring & Diagnostics:${NC}"
    echo "8.  System health check"
    echo "9.  Show firewall rules"
    echo "10. Certificate information"
    
    echo -e "\n${YELLOW}Configuration & Testing:${NC}"
    echo "11. Test Nginx config"
    echo "12. Test Xray config"
    echo "13. Show config examples"
    
    echo -e "\n${YELLOW}Maintenance:${NC}"
    echo "14. Backup configuration"
    
    echo -e "\n${YELLOW}Other:${NC}"
    echo "0.  Exit"
    echo ""
}

utilities_menu() {
    while true; do
        show_utilities_menu
        read -p "Select option [0-14]: " choice
        
        case $choice in
            1) service_status ;;
            2) read -p "Enter service [ssh|ws|nginx|xray]: " service; view_logs "$service" ;;
            3) restart_all ;;
            4) add_xray_user ;;
            5) remove_xray_user ;;
            6) list_xray_users ;;
            7) generate_uuid ;;
            8) health_check ;;
            9) show_firewall ;;
            10) cert_info ;;
            11) test_nginx ;;
            12) test_xray ;;
            13) show_config_examples ;;
            14) backup_config ;;
            0) echo "Exiting..."; exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

################################################################################
# MAIN INSTALLATION FLOW
################################################################################

main_install() {
    clear
    
    print_header "All-In-One SSH + WebSocket + Nginx + Xray Installer"
    echo "Domain: $DOMAIN"
    echo "Email: $EMAIL"
    echo ""
    echo "This script will install and configure:"
    echo "  • SSH Server (port $SSH_PORT)"
    echo "  • WebSocket Proxy (port $WS_PORT)"
    echo "  • Nginx Reverse Proxy (ports $NGINX_PORT_HTTP, $NGINX_PORT_HTTPS)"
    echo "  • Xray Proxy (ports $XRAY_PORT_VLESS, $XRAY_PORT_VMESS)"
    echo "  • SSL Certificate"
    echo "  • Firewall & Security"
    echo ""
    read -p "Press Enter to continue or Ctrl+C to cancel..."
    
    check_root
    detect_os
    update_system
    install_dependencies
    configure_ssh
    setup_websocket_proxy
    setup_ssl_certificate
    setup_nginx
    install_xray
    generate_xray_config
    enable_xray_service
    setup_firewall
    setup_fail2ban
    optimize_system
    setup_logging
    
    print_header "Installation Complete!"
    show_connection_info
    show_usage
    
    print_success "All services are configured and running"
    echo ""
    echo "To use utilities, run:"
    echo "  $0 utilities"
    echo ""
}

################################################################################
# MAIN ENTRY POINT
################################################################################

show_main_menu() {
    cat << 'EOFMENU'

╔════════════════════════════════════════════════════════════════╗
║      All-In-One SSH + WS + Nginx + Xray Complete Script       ║
╚════════════════════════════════════════════════════════════════╝

Usage: script.sh [COMMAND] [OPTIONS]

COMMANDS:
  install [domain] [email]  - Install all services
                             Default: example.com admin@example.com

  utilities [command]       - Open utilities menu or run command
                             Commands: status, logs, add-user, etc.

  help                      - Show this help message

UTILITIES COMMANDS:
  status              - Show service status
  logs [service]      - View service logs (ssh|ws|nginx|xray)
  uuid                - Generate new UUID
  add-user [email]    - Add new Xray user
  remove-user [id]    - Remove Xray user
  list-users          - List all Xray users
  health              - System health check
  firewall            - Show firewall rules
  cert                - Certificate information
  test-nginx          - Test Nginx configuration
  test-xray           - Test Xray configuration
  restart             - Restart all services
  backup              - Backup configuration
  examples            - Show config examples

EXAMPLES:
  # Install with defaults
  sudo script.sh install

  # Install with custom domain
  sudo script.sh install example.com admin@example.com

  # Show service status
  ./script.sh utilities status

  # Add new user
  ./script.sh utilities add-user user@example.com

  # View Xray logs
  ./script.sh utilities logs xray

  # Show configuration examples
  ./script.sh utilities examples

═════════════════════════════════════════════════════════════════

EOFMENU
}

# Parse arguments
case "${1:-}" in
    install)
        main_install
        ;;
    utilities)
        if [ -z "${2:-}" ]; then
            utilities_menu
        else
            case "$2" in
                status) service_status ;;
                logs) view_logs "$3" ;;
                uuid) generate_uuid ;;
                add-user) add_xray_user "$3" ;;
                remove-user) remove_xray_user "$3" ;;
                list-users) list_xray_users ;;
                health) health_check ;;
                firewall) show_firewall ;;
                cert) cert_info ;;
                test-nginx) test_nginx ;;
                test-xray) test_xray ;;
                restart) restart_all ;;
                backup) backup_config ;;
                examples) show_config_examples ;;
                *)
                    echo "Unknown command: $2"
                    show_main_menu
                    ;;
            esac
        fi
        ;;
    help|--help|-h)
        show_main_menu
        ;;
    "")
        show_main_menu
        ;;
    *)
        echo "Unknown command: $1"
        show_main_menu
        ;;
esac
