#!/usr/bin/env bash
# LND wallet setup: create or restore + secure auto-unlock
# - Stores password at /etc/lnd/wallet.password (600, owned by lnd)
# - Adds wallet-unlock-password-file to /etc/lnd/lnd.conf
# - Restarts lnd and verifies with lncli getinfo
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir

# --- defaults (safe) ---
: "${LND_USER:=lnd}"
: "${LND_DATA_DIR:=/data/lnd}"
: "${LND_RPC_ADDR:=127.0.0.1:10009}"
: "${LND_CONF:=/etc/lnd/lnd.conf}"
: "${LND_PASS_FILE:=/etc/lnd/wallet.password}"

log "LND wallet setup (create/restore) + auto-unlock"

# --- helper: ensure lnd service is running enough to serve WalletUnlocker ---
if ! systemctl is-active --quiet lnd; then
  warn "lnd.service is not active yet; starting it..."
  systemctl start lnd || true
  sleep 2
fi

# --- helper: prompt fallback (if common.sh doesn't provide it) ---
if ! command -v prompt >/dev/null 2>&1; then
  prompt() {
    local q="$1"; local def="${2:-}"; local ans
    if [[ -n "$def" ]]; then
      read -rp "${q} [${def}]: " ans
      printf '%s\n' "${ans:-$def}"
    else
      read -rp "${q}: " ans
      printf '%s\n' "${ans}"
    fi
  }
fi

# --- detect existing wallet ---
WALLET_DB="${LND_DATA_DIR}/data/chain/bitcoin/${NETWORK:-mainnet}/wallet.db"
wallet_exists=false
if [[ -f "$WALLET_DB" ]]; then
  wallet_exists=true
  warn "An existing LND wallet was detected at: ${WALLET_DB}"
fi

# --- ensure directories & perms ---
mkdir -p /etc/lnd
chown -R "${LND_USER}:${LND_USER}" /etc/lnd
chmod 750 /etc/lnd

# --- ensure expect available (for non-interactive new wallet flow) ---
if ! command -v expect >/dev/null 2>&1; then
  detect_pkg_mgr
  pkg_install expect
fi

# --- read and save wallet password securely ---
read_password() {
  local p1 p2
  while true; do
    read -rsp "Enter LND wallet password: " p1; echo
    read -rsp "Confirm LND wallet password: " p2; echo
    if [[ -z "$p1" ]]; then
      echo "[x] Password cannot be empty." >&2
    elif [[ "$p1" != "$p2" ]]; then
      echo "[x] Passwords do not match, try again." >&2
    else
      break
    fi
  done
  printf '%s' "$p1" > "${LND_PASS_FILE}"
  chown "${LND_USER}:${LND_USER}" "${LND_PASS_FILE}"
  chmod 600 "${LND_PASS_FILE}"
  ok "Saved wallet password to ${LND_PASS_FILE} (mode 600)."
}

# --- write auto-unlock config into lnd.conf (idempotent) ---
ensure_autounlock_conf() {
  mkdir -p "$(dirname "${LND_CONF}")"
  touch "${LND_CONF}"
  if grep -q '^wallet-unlock-password-file=' "${LND_CONF}"; then
    sed -i "s|^wallet-unlock-password-file=.*$|wallet-unlock-password-file=${LND_PASS_FILE}|" "${LND_CONF}"
  else
    printf "\n# Auto-unlock configured by btc-node-installer\nwallet-unlock-password-file=%s\n" "${LND_PASS_FILE}" >> "${LND_CONF}"
  fi
  chown "${LND_USER}:${LND_USER}" "${LND_CONF}"
  chmod 640 "${LND_CONF}"
  ok "Updated ${LND_CONF} with wallet-unlock-password-file."
}

# --- main flow ---
if [[ "${wallet_exists}" == "true" ]]; then
  log "Wallet already exists. We will only set up auto-unlock."
  read_password
  ensure_autounlock_conf
else
  echo
  echo "Choose wallet operation:"
  echo "  1) Create NEW wallet (password automated; seed will be SHOWN ONCE)"
  echo "  2) RESTORE wallet from existing 24-word seed (interactive)"
  op="$(prompt "Selection (1/2)" "1")"

  case "${op}" in
    1|create|new)
      read_password
      ensure_autounlock_conf
      log "Creating NEW wallet (seed will be printed by lncli; WRITE IT DOWN OFFLINE)."
      # Use expect to pass the password automatically; choose defaults for seed passphrase (No).
      sudo -u "${LND_USER}" -H bash -c "expect <<'EOF'
set timeout 180
spawn /usr/local/bin/lncli --lnddir=${LND_DATA_DIR} --rpcserver=${LND_RPC_ADDR} create
expect {
  -re {Input wallet password:} {
    send -- [exec cat ${LND_PASS_FILE}]
    send -- \"\r\"
    exp_continue
  }
  -re {Confirm wallet password:} {
    send -- [exec cat ${LND_PASS_FILE}]
    send -- \"\r\"
    exp_continue
  }
  -re {Do you have an existing cipher seed mnemonic you want to use\\? \\(Enter y/n\\):} {
    send -- \"n\r\"
    exp_continue
  }
  -re {Your cipher seed can optionally be encrypted.*\\(Enter y/n\\):} {
    send -- \"n\r\"
    exp_continue
  }
  -re {lnd successfully initialized!} {
    # wallet created
  }
}
EOF"
      ok "Wallet created. Seed was shown above ONCE — store it securely offline."
      ;;
    2|restore)
      read_password
      ensure_autounlock_conf
      warn "Launching interactive RESTORE: enter your 24-word seed (and seed passphrase if you used one)."
      # For restore, let user type seed interactively (more reliable for 24 words).
      sudo -u "${LND_USER}" /usr/local/bin/lncli --lnddir="${LND_DATA_DIR}" --rpcserver="${LND_RPC_ADDR}" create || true
      ok "Restore flow completed (if you entered a valid seed)."
      ;;
    *)
      warn "Unknown selection '${op}'. Defaulting to NEW wallet."
      read_password
      ensure_autounlock_conf
      sudo -u "${LND_USER}" -H bash -c "expect <<'EOF'
set timeout 180
spawn /usr/local/bin/lncli --lnddir=${LND_DATA_DIR} --rpcserver=${LND_RPC_ADDR} create
expect {
  -re {Input wallet password:} {
    send -- [exec cat ${LND_PASS_FILE}]
    send -- \"\r\"
    exp_continue
  }
  -re {Confirm wallet password:} {
    send -- [exec cat ${LND_PASS_FILE}]
    send -- \"\r\"
    exp_continue
  }
  -re {Do you have an existing cipher seed mnemonic you want to use\\? \\(Enter y/n\\):} {
    send -- \"n\r\"
    exp_continue
  }
  -re {Your cipher seed can optionally be encrypted.*\\(Enter y/n\\):} {
    send -- \"n\r\"
    exp_continue
  }
  -re {lnd successfully initialized!} {
    # wallet created
  }
}
EOF"
      ok "Wallet created (default path). Seed was shown above ONCE — store it securely offline."
      ;;
  esac
fi

# --- restart lnd to ensure auto-unlock takes effect ---
log "Restarting lnd to apply auto-unlock..."
systemctl restart lnd
sleep 2

# --- quick check ---
sudo -u "${LND_USER}" /usr/local/bin/lncli --lnddir="${LND_DATA_DIR}" --rpcserver="${LND_RPC_ADDR}" getinfo || true

ok "LND wallet setup completed (auto-unlock active). If Bitcoin is still syncing, synced_to_chain=false is expected."

