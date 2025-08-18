#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir

# Defaults
: "${LND_DATA_DIR:=/data/lnd}"
: "${LND_RPC_ADDR:=127.0.0.1:10009}"
: "${LND_USER:=lnd}"

# Ensure dirs
mkdir -p /etc/lnd
chown -R "${LND_USER}:${LND_USER}" /etc/lnd
chmod 750 /etc/lnd

log "LND wallet setup (create/restore + auto-unlock)"

# Detect existing wallet
WALLET_DB="${LND_DATA_DIR}/data/chain/bitcoin/mainnet/wallet.db"
if [[ -f "$WALLET_DB" ]]; then
  warn "An LND wallet already exists (${WALLET_DB})."
  if confirm "Do you only want to (re)configure auto-unlock?"; then
    goto_autounlock_only=true
  else
    ok "Skipping wallet creation/restore."
    goto_autounlock_only=false
  fi
else
  goto_autounlock_only=false
fi

# Read password (twice) and save to /etc/lnd/wallet.password
read_password() {
  local p1 p2
  while true; do
    read -rsp "Enter LND wallet password: " p1; echo
    read -rsp "Confirm LND wallet password: " p2; echo
    if [[ "$p1" != "$p2" ]]; then
      echo "[x] Passwords do not match, try again." >&2
    elif [[ -z "$p1" ]]; then
      echo "[x] Password cannot be empty." >&2
    else
      break
    fi
  done
  printf '%s' "$p1" > /etc/lnd/wallet.password
  chown "${LND_USER}:${LND_USER}" /etc/lnd/wallet.password
  chmod 600 /etc/lnd/wallet.password
  ok "Saved wallet password to /etc/lnd/wallet.password (600)."
}

# Ensure expect is installed (just in case)
if ! command -v expect >/dev/null 2>&1; then
  detect_pkg_mgr
  pkg_install expect
fi

if [[ "${goto_autounlock_only}" != "true" ]]; then
  echo
  echo "Choose wallet operation:"
  echo "  1) Create NEW wallet (non-interactive password, seed shown on screen)"
  echo "  2) RESTORE wallet from existing 24-word seed (interactive)"
  op="$(prompt "Selection (1/2)" "1")"

  # Read & store password
  read_password

  if [[ "$op" == "1" ]]; then
    # Create NEW wallet using expect to pass the password automatically.
    # We choose defaults: NO seed passphrase; user must write down shown seed.
    log "Starting LND NEW wallet creation (password automated, seed will be shown)..."
    sudo -u "${LND_USER}" -H bash -c "expect <<'EOF'
set timeout 120
spawn /usr/local/bin/lncli --lnddir=${LND_DATA_DIR} --rpcserver=${LND_RPC_ADDR} create
expect {
  -re {Input wallet password:} {
    send -- [exec cat /etc/lnd/wallet.password]
    send -- \"\r\"
    exp_continue
  }
  -re {Confirm wallet password:} {
    send -- [exec cat /etc/lnd/wallet.password]
    send -- \"\r\"
    exp_continue
  }
  -re {Do you have an existing cipher seed mnemonic you want to use\? \(Enter y/n\):} {
    send -- \"n\r\"
    exp_continue
  }
  -re {Your cipher seed can optionally be encrypted.*\(Enter y/n\):} {
    send -- \"n\r\"
    exp_continue
  }
  -re {Generating your cipher seed mnemonic*} {
    exp_continue
  }
  -re {lnd successfully initialized!} {
    # wallet created
  }
}
EOF"
    ok "Wallet created. WRITE DOWN the seed displayed above carefully!"
  else
    # RESTORE path: run interactive lncli create so the user can input 24 words/optional passphrase.
    warn "Launching interactive RESTORE: please enter your 24-word seed (and optional seed passphrase if you had one)."
    sudo -u "${LND_USER}" /usr/local/bin/lncli --lnddir="${LND_DATA_DIR}" --rpcserver="${LND_RPC_ADDR}" create
    ok "Wallet restore attempted via interactive flow."
  fi
fi

# -------------------------------------------------------------------
# Auto-unlock: install helper and systemd drop-in
# -------------------------------------------------------------------
log "Installing lnd-unlock helper..."
cat > /usr/local/bin/lnd-unlock.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
LND_DIR="/data/lnd"
RPC="127.0.0.1:10009"
PASS_FILE="/etc/lnd/wallet.password"

# Retry unlock until RPC is ready
for i in {1..60}; do
  if /usr/local/bin/lncli --lnddir="${LND_DIR}" --rpcserver="${RPC}" unlock --stdin < "${PASS_FILE}" 2>/dev/null; then
    echo "[ok] LND wallet unlocked"
    exit 0
  fi
  sleep 2
done
echo "[x] Failed to unlock LND wallet after retries" >&2
exit 1
SH
chmod +x /usr/local/bin/lnd-unlock.sh
chown root:root /usr/local/bin/lnd-unlock.sh
ok "Installed /usr/local/bin/lnd-unlock.sh"

log "Adding systemd drop-in for ExecStartPost..."
mkdir -p /etc/systemd/system/lnd.service.d
cat > /etc/systemd/system/lnd.service.d/override.conf <<'OVR'
[Service]
ExecStartPost=/usr/local/bin/lnd-unlock.sh
OVR

systemctl daemon-reload
systemctl restart lnd
ok "LND restarted. Auto-unlock is now active (ExecStartPost)."

# Quick checks
sleep 2
sudo -u "${LND_USER}" /usr/local/bin/lncli --lnddir="${LND_DATA_DIR}" --rpcserver="${LND_RPC_ADDR}" getinfo || true

ok "LND wallet setup completed."

