#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir

# -----------------------------
# Defaults (safe)
# -----------------------------
: "${LND_VERSION:=v0.19.2-beta}"
: "${LND_USER:=lnd}"
: "${LND_DATA_DIR:=/data/lnd}"          # dati e TLS persistenti
: "${LND_CONF:=/home/lnd/lnd.conf}"     # config in HOME dell'utente lnd
: "${NETWORK:=mainnet}"                 # mainnet|testnet|signet|regtest
: "${BITCOIN_RPC_PORT:=8332}"
: "${BITCOIN_RPC_USER:=btcuser}"
: "${BITCOIN_RPC_PASSWORD:=btcpwd-strong-change-me}"
: "${ZMQ_RAWBLOCK:=28332}"
: "${ZMQ_RAWTX:=28333}"

# -----------------------------
# Create user and dirs
# -----------------------------
ensure_user "${LND_USER}"
mkdir -p "${LND_DATA_DIR}" "/home/${LND_USER}"
chown -R "${LND_USER}:${LND_USER}" "${LND_DATA_DIR}" "/home/${LND_USER}"
chmod 750 "${LND_DATA_DIR}" "/home/${LND_USER}"

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
# Build lnd.conf (minimal + TLS persistente)
# -----------------------------
case "${NETWORK}" in
  mainnet|"") NETFLAG="bitcoin.mainnet=true" ;;
  testnet)     NETFLAG="bitcoin.testnet=true" ;;
  signet)      NETFLAG="bitcoin.signet=true" ;;
  regtest)     NETFLAG="bitcoin.regtest=true" ;;
  *)           NETFLAG="bitcoin.mainnet=true"; warn "Unknown NETWORK='${NETWORK}', defaulting to mainnet" ;;
esac

cat > "${LND_CONF}" <<CONF
[Application Options]
lnddir=${LND_DATA_DIR}
rpclisten=127.0.0.1:10009
restlisten=127.0.0.1:8080
listen=0.0.0.0:9735
debuglevel=info

# TLS persistente e comodo per lncli/localhost
tlsautorefresh=true
tlsdisableautofill=true
tlsextradomain=localhost
tlsextraip=127.0.0.1

[Bitcoin]
bitcoin.node=bitcoind
${NETFLAG}

[Bitcoind]
bitcoind.rpchost=127.0.0.1:${BITCOIN_RPC_PORT}
bitcoind.rpcuser=${BITCOIN_RPC_USER}
bitcoind.rpcpass=${BITCOIN_RPC_PASSWORD}
bitcoind.zmqpubrawblock=tcp://127.0.0.1:${ZMQ_RAWBLOCK}
bitcoind.zmqpubrawtx=tcp://127.0.0.1:${ZMQ_RAWTX}
CONF

# Tor (se abilitato in precedenza)
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
# systemd unit (niente auto-unlock qui)
# -----------------------------
cat > /etc/systemd/system/lnd.service <<SERVICE
[Unit]
Description=LND Lightning Network Daemon
Wants=bitcoind.service
After=network.target bitcoind.service

[Service]
User=${LND_USER}
Group=${LND_USER}
Type=simple
ExecStart=/usr/local/bin/lnd --lnddir=${LND_DATA_DIR} --configfile=${LND_CONF}
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now lnd || true

# breve attesa per permettere la creazione di tls.cert / WalletUnlocker
sleep 3

ok "LND started. Waiting for wallet setup… (WalletUnlocker on 127.0.0.1:10009)"
set_state lnd.installed

# -----------------------------
# Call wallet setup (absolute path)
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
bash "$REPO_ROOT/scripts/21-lnd-wallet.sh"

dragonesi@debian-btc-test:~/btc-node-installer$ 
dragonesi@debian-btc-test:~/btc-node-installer$ cat scripts/21-lnd-wallet.sh 
#!/usr/bin/env bash
set -Euo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir

LND_USER="lnd"
LND_DATA_DIR="${LND_DATA_DIR:-/data/lnd}"
LND_RPC_ADDR="127.0.0.1:10009"
LNCLI="/usr/local/bin/lncli"
UNIT_FILE="/etc/systemd/system/lnd.service"

FINAL_TLS="${LND_DATA_DIR}/tls.cert"
PWD_FILE="${LND_DATA_DIR}/password.txt"    # usato SOLO se abiliti auto-unlock ora

log "LND wallet setup (create/restore) — interactive first, auto-unlock opzionale dopo"

# Assicura che lnd sia avviato (WalletUnlocker)
systemctl start lnd || true

wait_for_final_tls() {
  local timeout=120 i=0
  while (( i < timeout )); do
    [[ -s "${FINAL_TLS}" ]] && return 0
    sleep 1; ((i++))
  done
  return 1
}

# Attendi TLS persistente
if ! wait_for_final_tls; then
  warn "[!] tls.cert not found yet; restarting lnd and retrying…"
  systemctl restart lnd || true
  if ! wait_for_final_tls; then
    error_exit "Final TLS certificate not found at ${FINAL_TLS}"
  fi
fi
ok "TLS ready at ${FINAL_TLS}"

echo
echo "Choose wallet operation:"
echo "  1) Create NEW wallet (seed will be SHOWN ONCE)"
echo "  2) RESTORE wallet from existing 24-word seed (interactive)"
read -rp "Selection (1/2) [1]: " choice
choice="${choice:-1}"

set +e
case "$choice" in
  1|create|new)
    echo "[i] Creating NEW wallet (seed will be printed; WRITE IT DOWN OFFLINE)."
    sudo -u "${LND_USER}" "${LNCLI}" \
      --lnddir="${LND_DATA_DIR}" \
      --rpcserver="${LND_RPC_ADDR}" \
      --tlscertpath="${FINAL_TLS}" \
      create
    ;;
  2|restore)
    echo "[i] Restoring wallet from SEED (you will be prompted interactively)."
    sudo -u "${LND_USER}" "${LNCLI}" \
      --lnddir="${LND_DATA_DIR}" \
      --rpcserver="${LND_RPC_ADDR}" \
      --tlscertpath="${FINAL_TLS}" \
      create
    ;;
  *)
    warn "Unknown selection '${choice}', defaulting to NEW wallet."
    sudo -u "${LND_USER}" "${LNCLI}" \
      --lnddir="${LND_DATA_DIR}" \
      --rpcserver="${LND_RPC_ADDR}" \
      --tlscertpath="${FINAL_TLS}" \
      create
    ;;
esac
set -e

echo "[i] Restarting lnd…"
systemctl restart lnd || true
sleep 2

# test lncli
sudo -u "${LND_USER}" "${LNCLI}" \
  --lnddir="${LND_DATA_DIR}" \
  --rpcserver="${LND_RPC_ADDR}" \
  --tlscertpath="${FINAL_TLS}" \
  getinfo || true

ok "Wallet created/restored successfully."

# -----------------------------
# Auto-unlock (opzionale)
# -----------------------------
echo
read -rp "Enable AUTO-UNLOCK at boot now? [y/N]: " au
case "${au,,}" in
  y|yes)
p1=""; p2=""
    while true; do
      read -rsp "Enter LND wallet password for auto-unlock (min 8 chars): " p1; echo
      read -rsp "Confirm password: " p2; echo
      if [[ ${#p1} -lt 8 ]]; then
        echo "[x] Too short." >&2
      elif [[ "$p1" != "$p2" ]]; then
        echo "[x] Mismatch, try again." >&2
      else
        break
      fi
    done
    printf '%s' "$p1" > "${PWD_FILE}"
    chown "${LND_USER}:${LND_USER}" "${PWD_FILE}"
    chmod 600 "${PWD_FILE}"
    ok "Saved auto-unlock password to ${PWD_FILE}"

    # aggiungi flag a systemd ExecStart se non presente
    if ! grep -q -- '--wallet-unlock-password-file=' "${UNIT_FILE}"; then
      sed -i "s#^ExecStart=.*#ExecStart=/usr/local/bin/lnd --lnddir=${LND_DATA_DIR} --configfile=/home/${LND_USER}/lnd.conf --wallet-unlock-password-file=${PWD_FILE}#g" "${UNIT_FILE}"
      systemctl daemon-reload
    fi

    echo "[i] Restarting lnd to test auto-unlock…"
    systemctl restart lnd || true
    sleep 2
    sudo -u "${LND_USER}" "${LNCLI}" \
      --lnddir="${LND_DATA_DIR}" \
      --rpcserver="${LND_RPC_ADDR}" \
      --tlscertpath="${FINAL_TLS}" \
      getinfo || true
    ;;
  *) : ;;
esac

ok "LND wallet setup completed. If Bitcoin is still syncing, synced_to_chain=false is expected."
set_state lnd.wallet.done
