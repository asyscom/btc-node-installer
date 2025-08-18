#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state prereqs.done; then ok "Prerequisites already installed"; exit 0; fi

log "Updating base packages"
pkg_update
pkg_install curl jq git ufw unzip tar bc wget ca-certificates gnupg lsb-release python3 iptables

# service users and directories
ensure_user bitcoin
mkdir -p /var/lib/bitcoind /etc/bitcoin
chown -R bitcoin:bitcoin /var/lib/bitcoind /etc/bitcoin

# optional: Tor
if confirm "Install Tor for privacy (recommended)?"; then
  pkg_install tor
  systemctl enable --now tor || true
  set_state tor.enabled
  ok "Tor installed"
fi

# UFW
if confirm "Configure UFW (firewall) now?"; then
  ufw_allow 22
  ufw_allow ${BITCOIN_P2P_PORT}
  ufw_allow 9735
  ufw_allow ${THUNDERHUB_PORT}
  ufw_allow ${MEMPOOL_BACKEND_PORT}
  if confirm "Enable UFW (default deny incoming)?"; then
    ufw --force enable || true
  fi
fi

set_state prereqs.done
ok "Prerequisites completed"
