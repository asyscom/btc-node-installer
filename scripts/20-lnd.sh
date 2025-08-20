#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir

# -----------------------------
# Defaults
# -----------------------------
: "${LND_VERSION:=v0.19.2-beta}"
: "${LND_USER:=lnd}"
: "${LND_DATA_DIR:=/data/lnd}"            # dati + TLS
: "${LND_CONF:=/home/lnd/lnd.conf}"       # config nella HOME di lnd
: "${BITCOIN_DATA_DIR:=/data/bitcoin}"    # cookie path
: "${BITCOIN_RPC_PORT:=8332}"
: "${NETWORK:=mainnet}"                   # mainnet|testnet|signet|regtest
: "${ZMQ_RAWBLOCK:=28332}"
: "${ZMQ_RAWTX:=28333}"

# Evita re-ingressi
if has_state lnd.installing; then
  warn "LND install already in progress; skipping duplicate run."
  exit 0
fi
set_state lnd.installing

# -----------------------------
# Create user and dirs
# -----------------------------
ensure_user "${LND_USER}"
mkdir -p "${LND_DATA_DIR}" "/home/${LND_USER}"
chown -R "${LND_USER}:${LND_USER}" "${LND_DATA_DIR}" "/home/${LND_USER}"
chmod 750 "${LND_DATA_DIR}" "/home/${LND_USER}"

# Aggiungi lnd al gruppo 'bitcoin' così eredita l'ACL sul cookie
usermod -aG bitcoin "${LND_USER}" || true

# -----------------------------
# Download & install LND + lncli
# -----------------------------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
pushd "$TMPDIR" >/dev/null
URL="https://github.com/lightningnetwork/lnd/releases/download/${LND_VERSION}/lnd-linux-amd64-${LND_VERSION}.tar.gz"
log "Downloading LND ${LND_VERSION} from ${URL}"
curl -fSLO "$URL"
tar -xf "lnd-linux-amd64-${LND_VERSION}.tar.gz"
install -m 0755 -o root -g root lnd-linux-amd64-*/{lnd,lncli} /usr/local/bin/
popd >/dev/null

# -----------------------------
# Build lnd.conf (RPC cookie, NO user/pass)
# -----------------------------
case "${NETWORK}" in
  mainnet|"") NETFLAG="bitcoin.mainnet=true" ;;
  testnet)    NETFLAG="bitcoin.testnet=true" ;;
  signet)     NETFLAG="bitcoin.signet=true" ;;
  regtest)    NETFLAG="bitcoin.regtest=true" ;;
  *)          NETFLAG="bitcoin.mainnet=true"; warn "Unknown NETWORK='${NETWORK}', defaulting to mainnet" ;;
esac

cat > "${LND_CONF}" <<CONF
[Application Options]
alias=your node name
color=#ff9900
lnddir=${LND_DATA_DIR}
rpclisten=127.0.0.1:10009
restlisten=127.0.0.1:9911
listen=0.0.0.0:9735
debuglevel=info

# TLS persistente utile per lncli/localhost
tlsautorefresh=true
tlsdisableautofill=true
tlsextradomain=localhost
tlsextraip=127.0.0.1

# Operatività
no-backup-archive=true
maxpendingchannels=5
accept-keysend=true
accept-amp=true
allow-circular-route=true
gc-canceled-invoices-on-startup=true
gc-canceled-invoices-on-the-fly=true
ignore-historical-gossip-filters=true

[protocol]
protocol.wumbo-channels=true
protocol.option-scid-alias=true
protocol.simple-taproot-chans=true
protocol.zero-conf=true
protocol.rbf-coop-close=true

[wtclient]
wtclient.active=true

[watchtower]
watchtower.active=true

[routing]
routing.strictgraphpruning=true

[Bitcoin]
bitcoin.node=bitcoind
${NETFLAG}

[Bitcoind]
bitcoind.rpchost=127.0.0.1:${BITCOIN_RPC_PORT}
bitcoind.rpccookie=${BITCOIN_DATA_DIR}/.cookie
bitcoind.zmqpubrawblock=tcp://127.0.0.1:${ZMQ_RAWBLOCK}
bitcoind.zmqpubrawtx=tcp://127.0.0.1:${ZMQ_RAWTX}
CONF

# Tor (se abilitato)
if has_state tor.enabled; then
  cat >> "${LND_CONF}" <<'CONF'
[tor]
tor.active=true
tor.v3=true
tor.socks=127.0.0.1:9050
tor.control=127.0.0.1:9051
tor.streamisolation=true
CONF
  usermod -aG debian-tor "${LND_USER}" || true
fi

chown "${LND_USER}:${LND_USER}" "${LND_CONF}"
chmod 640 "${LND_CONF}"

# -----------------------------
# systemd unit (no auto-unlock qui; lo offre 21-lnd-wallet)
# -----------------------------
cat > /etc/systemd/system/lnd.service <<SERVICE
[Unit]
Description=LND Lightning Network Daemon
Wants=bitcoind.service
After=network.target bitcoind.service

[Service]
Type=simple
#User=${LND_USER}
User=lnd
#Group=${LND_USER}
Group=lnd
#ExecStartPre=/bin/bash -c 'for i in {1..60}; do [ -r /data/bitcoin/.cookie ] && exit 0; sleep 1; done; echo "Cookie not readable"; exit 1'
ExecStartPre=/bin/bash -c 'for i in {1..180}; do [ -r /data/bitcoin/.cookie ] && exit 0; sleep 1; done; echo "Cookie not readable by lnd"; exit 1'
#ExecStart=/usr/local/bin/lnd --lnddir=${LND_DATA_DIR} --configfile=${LND_CONF}
ExecStart=/usr/local/bin/lnd --lnddir=/data/lnd --configfile=/home/lnd/lnd.conf
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now lnd || true

sleep 3
ok "LND started. Waiting for wallet setup… (WalletUnlocker on 127.0.0.1:10009)"
set_state lnd.installed

# Avvio automatico del wallet setup solo se non già fatto
if ! has_state lnd.wallet.done && ! has_state lnd.wallet.inprogress; then
  set_state lnd.wallet.inprogress
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
  bash "$REPO_ROOT/scripts/21-lnd-wallet.sh" || true
fi

# cleanup flag installing
rm -f /var/lib/btc-node-installer/state/lnd.installing || true

