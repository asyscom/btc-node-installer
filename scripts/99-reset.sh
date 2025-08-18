#!/usr/bin/env bash
# Reset the whole stack to a clean state for testing.
# Usage:
#   sudo ./scripts/99-reset.sh            # FULL WIPE (everything, including blockchain)
#   sudo ./scripts/99-reset.sh --keep-blocks  # keep /data/bitcoin/blocks & chainstate

set -Eeuo pipefail

KEEP_BLOCKS=false
if [[ "${1:-}" == "--keep-blocks" ]]; then
  KEEP_BLOCKS=true
fi

echo "[!] THIS WILL REMOVE services, configs, binaries, states, and DATA under /data/*"
if [[ "${KEEP_BLOCKS}" == "true" ]]; then
  echo "[i] KEEPING Bitcoin blocks/chainstate."
else
  echo "[!] FULL WIPE (including blockchain)."
fi
read -rp "Type 'YES' to continue: " ack
[[ "${ack}" == "YES" ]] || { echo "[x] Aborted."; exit 1; }

# Stop & disable services (ignore errors if not present)
systemctl stop bitcoind lnd electrs mempool-backend thunderhub 2>/dev/null || true
systemctl disable bitcoind lnd electrs mempool-backend thunderhub 2>/dev/null || true

# Remove systemd units & drop-ins
rm -f /etc/systemd/system/bitcoind.service
rm -f /etc/systemd/system/lnd.service
rm -f /etc/systemd/system/electrs.service
rm -f /etc/systemd/system/mempool-backend.service
rm -f /etc/systemd/system/thunderhub.service
rm -rf /etc/systemd/system/lnd.service.d

# Reload systemd
systemctl daemon-reload
systemctl reset-failed || true

# Remove configs
rm -rf /etc/bitcoin /etc/lnd /etc/electrs /etc/mempool

# Remove installed binaries (if placed in /usr/local/bin)
rm -f /usr/local/bin/bitcoin* /usr/local/bin/lnd* /usr/local/bin/electrs* /usr/local/bin/lnd-unlock.sh 2>/dev/null || true

# Remove ThunderHub working dir if our scripts used it
rm -rf /home/bitcoin/thunderhub 2>/dev/null || true

# Remove operator aliases
rm -f /etc/profile.d/btc-aliases.sh

# Installer state & repo cache
rm -rf /var/lib/btc-node-installer

# DATA wipe
if [[ "${KEEP_BLOCKS}" == "true" ]]; then
  echo "[i] Keeping /data/bitcoin/blocks and /data/bitcoin/chainstate"
  # Remove everything else but keep core blockchain data
  find /data/bitcoin -mindepth 1 -maxdepth 1 ! -name blocks ! -name chainstate -exec rm -rf {} +
else
  rm -rf /data/bitcoin
fi
rm -rf /data/lnd /data/electrs /data/mempool 2>/dev/null || true
# Ensure /data exists
mkdir -p /data
chmod 755 /data

echo "[ok] Reset complete."
echo "You can now clone the repo and reinstall:"
echo "  cd ~ && rm -rf ~/btc-node-installer"
echo "  git clone https://github.com/asyscom/btc-node-installer.git"
echo "  cd btc-node-installer && git fetch --tags && git checkout v0.1.0-beta.7"
echo "  cp .env.example .env"
echo "  sudo ./menu.sh"
