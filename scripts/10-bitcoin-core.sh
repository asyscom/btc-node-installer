#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state bitcoin.installed; then ok "Bitcoin Core già installato"; exit 0; fi

BITCOIN_VERSION="${BITCOIN_VERSION:-26.2}"
ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)

log "Installazione Bitcoin Core $BITCOIN_VERSION"
TMP=$(mktemp -d)
cd "$TMP"
URL="https://bitcoincore.org/bin/bitcoin-core-$BITCOIN_VERSION/bitcoin-$BITCOIN_VERSION-$(uname -s | tr '[:upper:]' '[:lower:]')-$ARCH.tar.gz"
if ! curl -fSL "$URL" -o bitcoin.tar.gz; then
  error_exit "Failed to download Bitcoin Core ($URL). Check version/arch."
fi
tar -xzf bitcoin.tar.gz
install -m 0755 -o root -g root bitcoin-*/bin/* /usr/local/bin/

# === Prompt: modalità pruned? ===
USE_PRUNE=false
PRUNE_GB=10
echo
if confirm "Vuoi attivare la modalità pruned (consigliato su dischi piccoli)?"; then
  USE_PRUNE=true
  read -r -p "Quanti GB dedicare ai blocchi (es. 10)? " PRUNE_GB_INPUT || true
  if [[ -n "${PRUNE_GB_INPUT:-}" ]]; then
    # valida intero positivo
    if [[ "$PRUNE_GB_INPUT" =~ ^[0-9]+$ ]] && [[ "$PRUNE_GB_INPUT" -ge 1 ]]; then
      PRUNE_GB="$PRUNE_GB_INPUT"
    else
      warn "Valore non valido, uso default ${PRUNE_GB} GB"
    fi
  fi
fi
# Converti GB -> MiB per bitcoin.conf (prune accetta MiB)
PRUNE_MIB=$(( PRUNE_GB * 1024 ))

# bitcoin.conf (txindex disabilitato se prune)
TXINDEX=1
if [[ "$USE_PRUNE" == "true" ]]; then
  TXINDEX=0
fi

cat > /etc/bitcoin/bitcoin.conf <<CONF
daemon=1
server=1
rest=1
txindex=${TXINDEX}
blockfilterindex=1
dbcache=2048

# rete
${NETWORK}=1

# RPC
rpcuser=${BITCOIN_RPC_USER}
rpcpassword=${BITCOIN_RPC_PASSWORD}
rpcallowip=127.0.0.1
rpcport=${BITCOIN_RPC_PORT}

# ZMQ
zmqpubrawblock=tcp://127.0.0.1:${ZMQ_RAWBLOCK}
zmqpubrawtx=tcp://127.0.0.1:${ZMQ_RAWTX}

# dati
datadir=/var/lib/bitcoind
CONF

if [[ "$USE_PRUNE" == "true" ]]; then
  echo "prune=${PRUNE_MIB}" >> /etc/bitcoin/bitcoin.conf
  warn "Pruned mode enabled (${PRUNE_GB} GB ~ ${PRUNE_MIB} MiB). 'txindex=0' impostato."
  warn "Note: Electrs and Mempool may NOT index/show full history on a pruned node."
else
  ok "Full node: 'txindex=1' mantenuto (richiede molto spazio su disco)."
fi

chown -R bitcoin:bitcoin /etc/bitcoin

# unità systemd
cat > /etc/systemd/system/bitcoind.service <<'SERVICE'
[Unit]
Description=Bitcoin daemon
After=network.target
Wants=network.target

[Service]
User=bitcoin
Group=bitcoin
Type=simple
ExecStart=/usr/local/bin/bitcoind -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoind
ExecStop=/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoind stop
Restart=on-failure
TimeoutStopSec=120
RuntimeDirectory=bitcoind
RuntimeDirectoryMode=0750
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE

enable_start bitcoind.service
ok "Bitcoin Core avviato. Check sync with: sudo -u bitcoin bitcoin-cli -datadir=/var/lib/bitcoind getblockchaininfo"
set_state bitcoin.installed
