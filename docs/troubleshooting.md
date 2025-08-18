# Maintenance & Troubleshooting
Use `systemctl` to check services:
- bitcoind, lnd, electrs, thunderhub, mempool-backend, tor
Tail logs:
- /var/lib/bitcoind/debug.log (as user bitcoin)
- /var/lib/lnd/logs/bitcoin/mainnet/lnd.log (as user lnd)
- journalctl -u <service> -f
Reindex example:
  systemctl stop bitcoind && sudo -u bitcoin /usr/local/bin/bitcoind -reindex -datadir=/var/lib/bitcoind
Disk:
  df -h
