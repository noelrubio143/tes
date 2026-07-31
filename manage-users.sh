#!/usr/bin/env bash
#
# ==============================================================================
#  SSH + Xray Account Manager
#  Companion script to vps-setup.sh — run this AFTER the main setup script
#  has installed Nginx + Xray.
# ==============================================================================
#
#  USAGE:
#    chmod +x manage-users.sh
#    sudo ./manage-users.sh
#
#  Provides an interactive menu to:
#    - Create / delete a restricted SSH-only user (no shell, for tunneling)
#    - Create / delete an Xray VLESS client
#    - List existing SSH and Xray accounts
#
# ==============================================================================

set -euo pipefail

XRAY_CONFIG="/usr/local/etc/xray/config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root (use sudo)."
  exit 1
fi

require_jq() {
  if ! command -v jq &>/dev/null; then
    log "Installing jq (needed to edit Xray config safely)..."
    apt-get update -y && apt-get install -y jq
  fi
}

# ------------------------------------------------------------------------------
# SSH USER FUNCTIONS
# ------------------------------------------------------------------------------

ssh_create_user() {
  read -rp "Username: " USERNAME
  if id "$USERNAME" &>/dev/null; then
    err "User '${USERNAME}' already exists."
    return
  fi

  read -rp "Account expiry in days (e.g. 30, leave blank for no expiry): " DAYS

  useradd -m -s /bin/false "$USERNAME"
  passwd "$USERNAME"

  if [[ -n "${DAYS:-}" ]]; then
    EXPIRE_DATE=$(date -d "+${DAYS} days" +%Y-%m-%d)
    chage -E "$EXPIRE_DATE" "$USERNAME"
    log "User '${USERNAME}' created, expires on ${EXPIRE_DATE}."
  else
    log "User '${USERNAME}' created with no expiry."
  fi

  warn "Note: shell is set to /bin/false — this account can be used for SSH"
  warn "port-forwarding / tunneling but cannot get an interactive shell."
  echo "  To allow full shell login instead, run: chsh -s /bin/bash ${USERNAME}"
}

ssh_delete_user() {
  read -rp "Username to delete: " USERNAME
  if ! id "$USERNAME" &>/dev/null; then
    err "User '${USERNAME}' does not exist."
    return
  fi
  read -rp "Delete user '${USERNAME}' and their home directory? (y/n): " CONFIRM
  if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
    userdel -r "$USERNAME" 2>/dev/null || userdel "$USERNAME"
    log "User '${USERNAME}' deleted."
  else
    warn "Cancelled."
  fi
}

ssh_list_users() {
  echo -e "${CYAN}Non-system users (UID >= 1000):${NC}"
  awk -F: '$3 >= 1000 && $3 < 60000 {print " -", $1, "| shell:", $7}' /etc/passwd
}

# ------------------------------------------------------------------------------
# XRAY CLIENT FUNCTIONS
# ------------------------------------------------------------------------------

xray_check_installed() {
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    err "Xray config not found at ${XRAY_CONFIG}."
    err "Run vps-setup.sh first to install Xray."
    return 1
  fi
  return 0
}

xray_create_client() {
  xray_check_installed || return
  require_jq

  read -rp "Client label/email (e.g. friend1): " LABEL
  NEW_UUID=$(cat /proc/sys/kernel/random/uuid)

  jq --arg id "$NEW_UUID" --arg email "$LABEL" \
    '.inbounds[0].settings.clients += [{"id": $id, "level": 0, "email": $email}]' \
    "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

  systemctl restart xray
  log "Xray client '${LABEL}' created."

  WS_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$XRAY_CONFIG")
  DOMAIN_GUESS=$(grep -h server_name /etc/nginx/sites-available/*.conf 2>/dev/null | head -n1 | awk '{print $2}' | tr -d ';')
  if [[ -z "$DOMAIN_GUESS" ]]; then
    DOMAIN_GUESS=$(grep -rl "location ${WS_PATH}" /etc/nginx/sites-available/ 2>/dev/null | xargs grep -h server_name 2>/dev/null | head -n1 | awk '{print $2}' | tr -d ';')
  fi
  DOMAIN_GUESS="${DOMAIN_GUESS:-yourdomain.com}"

  echo
  echo " UUID:  ${NEW_UUID}"
  echo " Link:  vless://${NEW_UUID}@${DOMAIN_GUESS}:443?encryption=none&security=tls&type=ws&host=${DOMAIN_GUESS}&path=${WS_PATH}#${LABEL}"
}

xray_delete_client() {
  xray_check_installed || return
  require_jq

  xray_list_clients
  read -rp "UUID to delete: " DEL_UUID

  jq --arg id "$DEL_UUID" \
    '.inbounds[0].settings.clients |= map(select(.id != $id))' \
    "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

  systemctl restart xray
  log "Client removed (if it existed) and Xray restarted."
}

xray_list_clients() {
  xray_check_installed || return
  require_jq
  echo -e "${CYAN}Xray clients:${NC}"
  jq -r '.inbounds[0].settings.clients[] | " - " + (.email // "unlabeled") + "  |  " + .id' "$XRAY_CONFIG"
}

# ------------------------------------------------------------------------------
# MENU
# ------------------------------------------------------------------------------

main_menu() {
  while true; do
    echo
    echo -e "${CYAN}==================== Account Manager ====================${NC}"
    echo " 1) Create SSH user"
    echo " 2) Delete SSH user"
    echo " 3) List SSH users"
    echo " 4) Create Xray client"
    echo " 5) Delete Xray client"
    echo " 6) List Xray clients"
    echo " 0) Exit"
    echo -e "${CYAN}===========================================================${NC}"
    read -rp "Choose an option: " CHOICE

    case "$CHOICE" in
      1) ssh_create_user ;;
      2) ssh_delete_user ;;
      3) ssh_list_users ;;
      4) xray_create_client ;;
      5) xray_delete_client ;;
      6) xray_list_clients ;;
      0) log "Bye."; exit 0 ;;
      *) err "Invalid option." ;;
    esac
  done
}

main_menu
