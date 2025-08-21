#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state prereqs.done; then ok "Prerequisites already installed"; exit 0; fi

log "Updating base packages"
pkg_update
pkg_install curl jq git ufw unzip tar bc wget ca-certificates gnupg lsb-release python3 iptables expect

# -----------------------------------------------------------------------------
# Service users and base dirs
# -----------------------------------------------------------------------------
ensure_user bitcoin
mkdir -p /etc/bitcoin
chown -R bitcoin:bitcoin /etc/bitcoin

# -----------------------------------------------------------------------------
# Data directories (from .env or defaults) under /data
# -----------------------------------------------------------------------------
: "${BITCOIN_DATA_DIR:=/data/bitcoin}"
: "${LND_DATA_DIR:=/data/lnd}"
: "${ELECTRS_DATA_DIR:=/data/electrs}"
: "${MEMPOOL_DATA_DIR:=/data/mempool}"

mkdir -p "$BITCOIN_DATA_DIR" "$LND_DATA_DIR" "$ELECTRS_DATA_DIR" "$MEMPOOL_DATA_DIR"
chown -R bitcoin:bitcoin "$BITCOIN_DATA_DIR" "$LND_DATA_DIR" "$ELECTRS_DATA_DIR" "$MEMPOOL_DATA_DIR"
chmod 750 "$BITCOIN_DATA_DIR" "$LND_DATA_DIR" "$ELECTRS_DATA_DIR" "$MEMPOOL_DATA_DIR"

# Backward compatibility: keep old path if already used (no-op if missing)
mkdir -p /var/lib/bitcoind || true
chown -R bitcoin:bitcoin /var/lib/bitcoind || true

# -----------------------------------------------------------------------------
# Operator quality-of-life: group membership + aliases
# -----------------------------------------------------------------------------
# Add the invoking admin user to the 'bitcoin' group so they can read logs and use bitcoin-cli
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG bitcoin "$SUDO_USER" || true
  ok "Added ${SUDO_USER} to group 'bitcoin' (re-login required to take effect)"
fi

# Global shell aliases for operator convenience
cat > /etc/profile.d/btc-aliases.sh <<'ALIAS'
# Bitcoin operator shortcuts
alias bcli='sudo -u bitcoin bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/data/bitcoin'
alias btclog='sudo -u bitcoin tail -f /data/bitcoin/debug.log'
ALIAS
chmod 0644 /etc/profile.d/btc-aliases.sh

# -----------------------------------------------------------------------------
# Optional: Tor (single-file config in /etc/tor/torrc)
# -----------------------------------------------------------------------------
if confirm "Install Tor for privacy (recommended)?"; then
  pkg_install tor

  # Scrivi/aggiorna le opzioni necessarie in /etc/tor/torrc (senza duplicati)
  install -m 0644 -o root -g root /dev/null /etc/tor/torrc 2>/dev/null || true
  for kv in \
    "SocksPort 127.0.0.1:9050" \
    "ControlPort 127.0.0.1:9051" \
    "CookieAuthentication 1" \
    "CookieAuthFile /var/run/tor/control.authcookie" \
    "CookieAuthFileGroupReadable 1"
  do
    key="$(printf '%s\n' "$kv" | awk '{print $1}')"
    # rimuovi eventuali righe esistenti di quella chiave
    sed -i "/^[[:space:]]*${key}\b/d" /etc/tor/torrc
    # aggiungi la nostra riga
    echo "$kv" >> /etc/tor/torrc
  done

  # consenti ai servizi di leggere il cookie del ControlPort
  id -u bitcoin >/dev/null 2>&1 && usermod -aG debian-tor bitcoin || true
  id -u lnd >/dev/null 2>&1 && usermod -aG debian-tor lnd || true

  systemctl enable --now tor@default.service || true
  systemctl restart tor@default.service || true

  set_state tor.enabled
  ok "Tor installed & configured (9050/9051, cookie auth)."
fi


# -----------------------------------------------------------------------------
# UFW (firewall)
# -----------------------------------------------------------------------------
if confirm "Configure UFW (firewall) now?"; then
  ufw_allow 22
  ufw_allow "${BITCOIN_P2P_PORT}"
  ufw_allow 9735
  ufw_allow "${THUNDERHUB_PORT}"
  ufw_allow "${MEMPOOL_BACKEND_PORT}"
  if confirm "Enable UFW (default deny incoming)?"; then
    ufw --force enable || true
  fi
fi

set_state prereqs.done
ok "Prerequisites completed"

