#!/usr/bin/env bash
# Full wipe of Bitcoin Core + LND install: services, users, configs, data, ACL, state.
# Use carefully! This is destructive.
#
# Usage:
#   sudo ./scripts/99-reset-all.sh                # interattivo (chiede conferma)
#   sudo ./scripts/99-reset-all.sh --yes          # no prompt
#   sudo ./scripts/99-reset-all.sh --yes --purge-binaries   # rimuove anche i binari

set -Eeuo pipefail

confirm() {
  local q="$1"
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  read -rp "$q [y/N]: " a
  [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[x] Please run as root (sudo)." >&2
    exit 1
  fi
}

log() { echo "[i] $*"; }
ok()  { echo "[ok] $*"; }
warn(){ echo "[!] $*" >&2; }
err() { echo "[x] $*" >&2; }

ASSUME_YES=false
PURGE_BINARIES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=true ;;
    --purge-binaries) PURGE_BINARIES=true ;;
    *) warn "Unknown option: $arg" ;;
  esac
done

require_root

# Paths used by the installer
BITCOIN_USER="bitcoin"
LND_USER="lnd"
BITCOIN_DATA_DIR="${BITCOIN_DATA_DIR:-/data/bitcoin}"
LND_DATA_DIR="${LND_DATA_DIR:-/data/lnd}"
STATE_DIR="/var/lib/btc-node-installer/state"

BITCOIN_UNIT="/etc/systemd/system/bitcoind.service"
LND_UNIT="/etc/systemd/system/lnd.service"
LND_DROPIN_DIR="/etc/systemd/system/lnd.service.d"
BITCOIN_CONF_DIR="/etc/bitcoin"
LND_CONF_DIR="/etc/lnd"           # (vecchie versioni)
LND_HOME_CONF="/home/${LND_USER}/lnd.conf"
COOKIE_HELPER="/usr/local/bin/btc-cookie-acl.sh"

# Summary prompt
echo "==========================================================="
echo "  BTC Node Installer — FULL RESET"
echo "  This will DELETE services, users, configs and data:"
echo "    - Services: bitcoind, lnd"
echo "    - Users & groups: bitcoin, lnd"
echo "    - Data dirs: ${BITCOIN_DATA_DIR}, ${LND_DATA_DIR}"
echo "    - Configs: ${BITCOIN_CONF_DIR}, ${LND_CONF_DIR}, ${LND_HOME_CONF}"
echo "    - ACL/helper: ${COOKIE_HELPER}, ACL on /data(/bitcoin)"
echo "    - Installer state: ${STATE_DIR}"
[[ "$PURGE_BINARIES" == "true" ]] && echo "    - BINARIES: bitcoind/bitcoin-cli/bitcoin-tx + lnd/lncli"
echo "==========================================================="

confirm "Proceed with FULL RESET?" || { warn "Aborted."; exit 1; }

# 1) Stop and disable services if present
log "Stopping services…"
systemctl stop lnd       2>/dev/null || true
systemctl stop bitcoind  2>/dev/null || true

log "Disabling services…"
systemctl disable lnd       2>/dev/null || true
systemctl disable bitcoind  2>/dev/null || true

# 2) Remove unit files & drop-ins
log "Removing unit files…"
rm -f "$LND_UNIT" "$BITCOIN_UNIT" || true
rm -rf "$LND_DROPIN_DIR"          || true
systemctl daemon-reload || true

# 3) Remove ACLs on /data and /data/bitcoin if setfacl exists
if command -v setfacl >/dev/null 2>&1; then
  log "Clearing ACLs on /data and /data/bitcoin…"
  setfacl -b /data           2>/dev/null || true
  setfacl -b /data/bitcoin   2>/dev/null || true
fi

# 4) Remove helper
log "Removing helper scripts…"
rm -f "$COOKIE_HELPER" || true

# 5) Remove configs
log "Removing configs…"
rm -rf "$BITCOIN_CONF_DIR" || true
rm -rf "$LND_CONF_DIR"     || true
rm -f  "$LND_HOME_CONF"    || true

# 6) Remove data directories
log "Removing data directories…"
rm -rf "$BITCOIN_DATA_DIR" || true
rm -rf "$LND_DATA_DIR"     || true

# 7) Remove users (with home dirs) and groups
log "Removing users and groups…"
# delete LND user
if id -u "$LND_USER" >/dev/null 2>&1; then
  systemctl stop lnd 2>/dev/null || true
  userdel -r "$LND_USER" 2>/dev/null || true
fi
# delete BITCOIN user
if id -u "$BITCOIN_USER" >/dev/null 2>&1; then
  systemctl stop bitcoind 2>/dev/null || true
  userdel -r "$BITCOIN_USER" 2>/dev/null || true
fi
# delete groups if empty
getent group lnd      >/dev/null && groupdel lnd      2>/dev/null || true
getent group bitcoin  >/dev/null && groupdel bitcoin  2>/dev/null || true

# 8) Purge binaries (optional)
if [[ "$PURGE_BINARIES" == "true" ]]; then
  log "Purging binaries…"
  # Bitcoin Core
  rm -f /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli /usr/local/bin/bitcoin-tx /usr/local/bin/bitcoin-util 2>/dev/null || true
  # LND
  rm -f /usr/local/bin/lnd /usr/local/bin/lncli 2>/dev/null || true
fi

# 9) Clear installer state
log "Clearing installer state…"
rm -rf "$STATE_DIR" 2>/dev/null || true

ok "Full reset completed."
echo "You can now re-run: sudo ./menu.sh"

