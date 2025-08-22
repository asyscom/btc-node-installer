#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state electrs.installed; then
  ok "Electrs already installed"
  exit 0
fi

pkg_update
pkg_install build-essential clang cmake git rustc cargo pkg-config librocksdb-dev libssl-dev

# user and dirs
# NOTE: bitcoind gira come 'bitcoin' e usa /data/bitcoin (vedi 10-bitcoin.sh)
ensure_user bitcoin
mkdir -p /var/lib/electrs /var/lib/electrs/db /etc/electrs
chown -R bitcoin:bitcoin /var/lib/electrs /etc/electrs

# build
cd /opt
if [[ ! -d electrs ]]; then
  git clone https://github.com/romanz/electrs.git
fi
cd electrs
if [[ -n "${ELECTRS_VERSION:-}" && "${ELECTRS_VERSION}" != "latest" ]]; then
  git fetch --tags
  git checkout "${ELECTRS_VERSION}" || true
fi
cargo build --release
install -m 0755 target/release/electrs /usr/local/bin/

# detect network da bitcoin.conf
NET=mainnet
if [[ -f /etc/bitcoin/bitcoin.conf ]]; then
  grep -q '^testnet=1' /etc/bitcoin/bitcoin.conf && NET=testnet
  grep -q '^signet=1'  /etc/bitcoin/bitcoin.conf && NET=signet
  grep -q '^regtest=1' /etc/bitcoin/bitcoin.conf && NET=regtest
fi

# systemd
cat > /etc/systemd/system/electrs.service <<SERVICE
[Unit]
Description=Electrs
After=bitcoind.service network.target
Requires=bitcoind.service

[Service]
User=bitcoin
Group=bitcoin
# Attendi che RPC risponda e che il cookie esista (gira come User=bitcoin, niente sudo)
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do [ -f /data/bitcoin/.cookie ] && /usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/data/bitcoin getblockchaininfo >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/electrs \\
  --log-filters=INFO \\
  --network=${NET} \\
  --db-dir=/var/lib/electrs/db \\
  --daemon-dir=/data/bitcoin \\
  --daemon-rpc-addr=127.0.0.1:8332 \\
  --electrum-rpc-addr=0.0.0.0:50001 \\
  --cookie-file=/data/bitcoin/.cookie \\
  --monitoring-addr=127.0.0.1:4224
Restart=on-failure
RestartSec=5
LimitNOFILE=8192
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE

# ---- Tor Onion (HiddenService) → Electrs ----
ONION_DIR="/var/lib/tor/electrs"
ELECTRS_PORT="50001"

# install tor se manca
if ! command -v tor >/dev/null 2>&1; then
  case "$pkg_mgr" in
    apt) apt-get update -y && apt-get install -y tor ;;
    dnf|yum) pkg_install tor ;;
  esac
fi

# Aggiungi la configurazione di Hidden Service a torrc se manca
if ! grep -q "HiddenServiceDir ${ONION_DIR}" /etc/tor/torrc 2>/dev/null; then
  cat >> /etc/tor/torrc <<TOR
# Electrs Onion Service
HiddenServiceDir ${ONION_DIR}
HiddenServiceVersion 3
HiddenServicePort ${ELECTRS_PORT} 127.0.0.1:${ELECTRS_PORT}
TOR
fi

# Crea e proteggi la directory HS (hostname/keys)
mkdir -p "${ONION_DIR}"
chown -R debian-tor:debian-tor "${ONION_DIR}"
chmod 0700 "${ONION_DIR}"

# avvia/riload tor (supporta sia 'tor' che 'tor@default')
(systemctl enable --now tor || systemctl enable --now tor@default) || true
(systemctl reload tor || systemctl reload tor@default) || true

enable_start electrs.service
ok "Electrs started. Indexing in progress (can take many hours)."
set_state electrs.installed

# ---- Output finale: URL locali e Onion ----
ONION_HOST=""
for _ in $(seq 1 20); do
  if [[ -f "${ONION_DIR}/hostname" ]]; then
    ONION_HOST="$(cat "${ONION_DIR}/hostname" 2>/dev/null || true)"
    [[ -n "${ONION_HOST}" ]] && break
  fi
  sleep 1
done

echo
ok "Electrs is ready!"
echo "Local (loopback):    127.0.0.1:${ELECTRS_PORT}"
if [[ -n "${ONION_HOST}" ]]; then
  echo "Onion (via Tor):     ${ONION_HOST}:${ELECTRS_PORT}"
else
  echo "Onion (via Tor):     pending… (Tor is creating the service; check again in a few seconds)"
fi

echo
echo "Press any key to return to the main menu..."
read -n 1 -s

