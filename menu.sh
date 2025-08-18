#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

. lib/common.sh
require_root
load_env
ensure_state_dir

if ! command -v whiptail >/dev/null 2>&1; then
  detect_pkg_mgr; pkg_update; pkg_install whiptail
fi

while true; do
  CHOICE=$(whiptail --title "BTC Node Installer" --menu "Choose an action" 20 78 12 \
    1 "00 - Prerequisites" \
    2 "10 - Bitcoin Core" \
    3 "20 - LND" \
    4 "30 - Electrs" \
    5 "40 - ThunderHub" \
    6 "50 - Monitoring (Prometheus/Grafana)" \
    7 "60 - Mempool" \
    8 "Show useful commands" \
    9 "Exit" 3>&1 1>&2 2>&3) || exit 0

  case "$CHOICE" in
    1) sudo ./scripts/00-prereqs.sh ;;
    2) sudo ./scripts/10-bitcoin-core.sh ;;
    3) sudo ./scripts/20-lnd.sh ;;
    4) sudo ./scripts/30-electrs.sh ;;
    5) sudo ./scripts/40-thunderhub.sh ;;
    6) sudo ./scripts/50-monitoring.sh ;;
    7) sudo ./scripts/60-mempool.sh ;;
    8) whiptail --title "Useful commands" --msgbox "
Bitcoin: sudo -u bitcoin bitcoin-cli -datadir=/var/lib/bitcoind getblockchaininfo
LND:     lncli getinfo
Electrs: journalctl -u electrs -f
ThunderHub: http://<host>:$THUNDERHUB_PORT
Mempool:    http://<host>:$MEMPOOL_BACKEND_PORT
" 15 70 ;;
    9) exit 0 ;;
  esac
done
