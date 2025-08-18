#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir

if has_state bitcoin.installed; then ok "Bitcoin Core already installed"; exit 0; fi

log "Downloading Bitcoin Core ${BITCOIN_VERSION}..."
URL="https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz"
if ! curl -fSLO "$URL"; then
  error_exit "Failed to download Bitcoin Core ($URL). Check version/arch."
fi

tar -xvf "bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz"
install -m 0755 -o root -g root bitcoin-*/bin/* /usr/local/bin/

rm -rf bitcoin-*

# -----------------------------------------------------------------------------
# bitcoin.conf
# -----------------------------------------------------------------------------
log "Writing /etc/bitcoin/bitcoin.conf"

cat > /etc/bitcoin/bitcoin.conf <<CONF
# Bitcoin Core configuration
server=1
daemon=0
datadir=${BITCOIN_DATA_DIR}
disablewallet=1
rpccookieperms=group
uacomment=BTC-Node-Installer
assumevalid=0

# Indexes
blockfilterindex=1
peerblockfilters=1
coinstatsindex=1

# Logging
debug=tor
debug=i2p
nodebuglogfile=0

# P2P
listen=1
bind=127.0.0.1
bind=127.0.0.1=onion
proxy=unix:/run/tor/socks
i2psam=127.0.0.1:7656

# RPC
rpcuser=${BITCOIN_RPC_USER}
rpcpassword=${BITCOIN_RPC_PASSWORD}
rpcallowip=127.0.0.1
rpcport=${BITCOIN_RPC_PORT}

# ZMQ
zmqpubrawblock=tcp://127.0.0.1:${ZMQ_RAWBLOCK}
zmqpubrawtx=tcp://127.0.0.1:${ZMQ_RAWTX}

# Performance
dbcache=2048
blocksonly=1
CONF

if [[ "$USE_PRUNE" == "true" ]]; then
  echo "prune=${PRUNE_MIB}" >> /etc/bitcoin/bitcoin.conf
  warn "Pruned mode enabled (${PRUNE_GB} GB ~ ${PRUNE_MIB} MiB). 'txindex=0' enforced."
  echo "txindex=0" >> /etc/bitcoin/bitcoin.conf
else
  echo "txindex=1" >> /etc/bitcoin/bitcoin.conf
  ok "Full node mode enabled ('txindex=1')."
fi

chown -R bitcoin:bitcoin /etc/bitcoin

# -----------------------------------------------------------------------------
# systemd unit
# -----------------------------------------------------------------------------
log "Installing systemd unit for bitcoind"

cat > /etc/systemd/system/bitcoind.service <<SERVICE
[Unit]
Description=Bitcoin daemon
After=network.target
Wants=network.target

[Service]
User=bitcoin
Group=bitcoin
Type=simple
ExecStart=/usr/local/bin/bitcoind -conf=/etc/bitcoin/bitcoin.conf -datadir=${BITCOIN_DATA_DIR} -daemon=0
ExecStop=/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=${BITCOIN_DATA_DIR} stop
Restart=on-failure
TimeoutStopSec=120
RuntimeDirectory=bitcoind
RuntimeDirectoryMode=0750
LimitNOFILE=65535
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE

enable_start bitcoind.service
ok "Bitcoin Core started. Monitor with: bcli getblockchaininfo"
set_state bitcoin.installed

