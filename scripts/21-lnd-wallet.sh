#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir

# -----------------------------
# Defaults/paths
# -----------------------------
LND_USER="lnd"
LND_DATA_DIR="${LND_DATA_DIR:-/data/lnd}"
LND_CONF="${LND_CONF:-/home/lnd/lnd.conf}"
LND_RPC_ADDR="127.0.0.1:10009"
LNCLI="/usr/local/bin/lncli"
UNIT_FILE="/etc/systemd/system/lnd.service"

EPHEMERAL_TLS="${LND_DATA_DIR}/tls.walletunlocker.pem"   # cert effimero per lncli create
FINAL_TLS="${LND_DATA_DIR}/tls.cert"                      # cert definitivo dopo il wallet
PWD_FILE="${LND_DATA_DIR}/password.txt"                   # usato SOLO se abiliti auto-unlock

log "LND wallet setup (create/restore) — no auto-unlock during creation"

# -----------------------------
# Helpers
# -----------------------------
need_pkg() { command -v "$1" >/dev/null 2>&1 || { apt-get update -y && apt-get install -y "$1"; }; }

fetch_ephemeral_tls() {
  need_pkg openssl
  rm -f "${EPHEMERAL_TLS}"
  local tries=30
  for _i in $(seq 1 "${tries}"); do
    # prendi la chain presentata dal WalletUnlocker
    openssl s_client -connect "${LND_RPC_ADDR}" -servername localhost -showcerts </dev/null 2>/dev/null \
      | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "${EPHEMERAL_TLS}" || true
    if [[ -s "${EPHEMERAL_TLS}" ]]; then
      chown "${LND_USER}:${LND_USER}" "${EPHEMERAL_TLS}"
      chmod 0644 "${EPHEMERAL_TLS}"
      ok "Ephemeral TLS prepared at ${EPHEMERAL_TLS}"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_final_tls() {
  local timeout=120 i=0
  while (( i < timeout )); do
    [[ -s "${FINAL_TLS}" ]] && return 0
    sleep 1; ((i++))
  done
  return 1
}

enable_autounlock() {
  local p1 p2
  echo
  echo "Enable AUTO-UNLOCK: enter your wallet password (min 8 chars)."
  while true; do
    read -rsp "Password: " p1; echo
    read -rsp "Confirm : " p2; echo
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

  # drop-in override (più robusto di sed su ExecStart)
  mkdir -p /etc/systemd/system/lnd.service.d
  cat > /etc/systemd/system/lnd.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/lnd --lnddir=${LND_DATA_DIR} --configfile=${LND_CONF} --wallet-unlock-password-file=${PWD_FILE}
EOF

  systemctl daemon-reload
  echo "[i] Restarting lnd to test auto-unlock…"
  systemctl restart lnd || true
  sleep 2
  sudo -u "${LND_USER}" "${LNCLI}" \
    --lnddir="${LND_DATA_DIR}" \
    --rpcserver="${LND_RPC_ADDR}" \
    --tlscertpath="${FINAL_TLS}" \
    getinfo || true
  ok "Auto-unlock enabled."
}

# -----------------------------
# Flow
# -----------------------------
# Assicura che lnd sia avviato (WalletUnlocker)
systemctl start lnd || true

echo
echo "Choose wallet operation:"
echo "  1) Create NEW wallet (seed will be SHOWN ONCE)"
echo "  2) RESTORE wallet from existing 24-word seed (interactive)"
read -rp "Selection (1/2) [1]: " choice
choice="${choice:-1}"

# 1) PREPARA CERT EFFIMERO E LANCIA lncli create
if ! fetch_ephemeral_tls; then
  warn "[!] Ephemeral TLS not ready; restarting lnd and retrying…"
  systemctl restart lnd || true
  sleep 2
  fetch_ephemeral_tls || error_exit "Cannot obtain ephemeral TLS from WalletUnlocker"
fi

set +e
case "$choice" in
  1|create|new)
    echo "[i] Creating NEW wallet (seed will be printed; WRITE IT DOWN OFFLINE)."
    sudo -u "${LND_USER}" "${LNCLI}" \
      --lnddir="${LND_DATA_DIR}" \
      --rpcserver="${LND_RPC_ADDR}" \
      --tlscertpath="${EPHEMERAL_TLS}" \
      create
    ;;
  2|restore)
    echo "[i] Restoring wallet from SEED (you will be prompted interactively)."
    sudo -u "${LND_USER}" "${LNCLI}" \
      --lnddir="${LND_DATA_DIR}" \
      --rpcserver="${LND_RPC_ADDR}" \
      --tlscertpath="${EPHEMERAL_TLS}" \
      create
    ;;
  *)
    warn "Unknown selection '${choice}', defaulting to NEW wallet."
    sudo -u "${LND_USER}" "${LNCLI}" \
      --lnddir="${LND_DATA_DIR}" \
      --rpcserver="${LND_RPC_ADDR}" \
      --tlscertpath="${EPHEMERAL_TLS}" \
      create
    ;;
esac
set -e

# 2) RIAVVIA LND, ATTENDI CERT DEFINITIVO, PROVA getinfo
echo "[i] Restarting lnd to write final TLS/macaroon…"
systemctl restart lnd || true
if ! wait_for_final_tls; then
  warn "[!] tls.cert not found, retrying once more…"
  systemctl restart lnd || true
  wait_for_final_tls || error_exit "Final TLS certificate not found at ${FINAL_TLS}"
fi

sudo -u "${LND_USER}" "${LNCLI}" \
  --lnddir="${LND_DATA_DIR}" \
  --rpcserver="${LND_RPC_ADDR}" \
  --tlscertpath="${FINAL_TLS}" \
  getinfo || true

ok "Wallet created/restored successfully."

# 3) (OPZIONALE) AUTO-UNLOCK DOPO LA CREAZIONE
echo
read -rp "Enable AUTO-UNLOCK at boot now? [y/N]: " au
case "${au,,}" in
  y|yes) enable_autounlock ;;
  *) : ;;
esac

ok "LND wallet setup completed. If Bitcoin is still syncing, synced_to_chain=false is expected."
set_state lnd.wallet.done

