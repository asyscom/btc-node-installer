#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state lnd.installed; then ok "LND already installed"; exit 0; fi

detect_pkg_mgr; pkg_update; pkg_install wget tar

# Download LND binaries
LND_VERSION="${LND_VERSION:-v0.18.3-beta}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) LND_ARCH=amd64 ;;
  aarch64|arm64) LND_ARCH=arm64 ;;
  *) LND_ARCH=amd64 ;;
esac

TMP=$(mktemp -d); cd "$TMP"
URL="https://github.com/lightningnetwork/lnd/releases/download/${LND_VERSION}/lnd-linux-${LND_ARCH}-${LND_VERSION}.tar.gz"
if ! curl -fSL "$URL" -o lnd.tar.gz; then
  error_exit "Failed to download LND ($URL)."
fi
tar -xzf lnd.tar.gz
install -m 0755 -o root -g root lnd-*/lnd* /usr/local/bin/
install -m 0755 -o root -g root lnd-*/lncli /usr/local/bin/lncli

# user and dirs
ensure_user lnd
mkdir -p /var/lib/lnd /etc/lnd
chown -R lnd:lnd /var/lib/lnd /etc/lnd

# lnd.conf
cat > /etc/lnd/lnd.conf <<CONF
[Application Options]
datadir=/var/lib/lnd
tlscertpath=/var/lib/lnd/tls.cert
tlskeypath=/var/lib/lnd/tls.key
adminmacaroonpath=/var/lib/lnd/data/chain/bitcoin/${NETWORK}/admin.macaroon
listen=0.0.0.0:9735
rpclisten=127.0.0.1:10009
debuglevel=info

[Bitcoin]
bitcoin.${NETWORK}=true
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpchost=127.0.0.1:${BITCOIN_RPC_PORT}
bitcoind.rpcuser=${BITCOIN_RPC_USER}
bitcoind.rpcpass=${BITCOIN_RPC_PASSWORD}
bitcoind.zmqpubrawblock=tcp://127.0.0.1:${ZMQ_RAWBLOCK}
bitcoind.zmqpubrawtx=tcp://127.0.0.1:${ZMQ_RAWTX}
CONF
chown -R lnd:lnd /etc/lnd

# systemd
cat > /etc/systemd/system/lnd.service <<'SERVICE'
[Unit]
Description=LND Lightning Network Daemon
Wants=bitcoind.service
After=bitcoind.service

[Service]
User=lnd
Group=lnd
Type=simple
ExecStart=/usr/local/bin/lnd --configfile=/etc/lnd/lnd.conf
Restart=on-failure
LimitNOFILE=128000

[Install]
WantedBy=multi-user.target
SERVICE

enable_start lnd.service
ok "LND started. Initialize wallet with: sudo -u lnd lncli --rpcserver=127.0.0.1:10009 create"
set_state lnd.installed

# Call wallet setup immediately so the user completes LND in one go
# call wallet setup right after install (robust path)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
"$REPO_ROOT/scripts/21-lnd-wallet.sh"

