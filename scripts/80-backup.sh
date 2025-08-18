#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr
if has_state backup.setup; then ok "LND encrypted backup already configured"; exit 0; fi
detect_pkg_mgr; pkg_update; pkg_install gpg
BACKUP_DIR="/var/backups/lnd"; SCRIPT_PATH="/usr/local/sbin/backup_lnd.sh"
mkdir -p "$BACKUP_DIR"; chown -R lnd:lnd "$BACKUP_DIR"
read -r -p "Enter a passphrase to encrypt the LND backup (no echo): " -s ENC_PASS || true; echo
cat > "$SCRIPT_PATH" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/var/backups/lnd"
DATE=$(date +%F_%H%M%S)
PLAIN="${BACKUP_DIR}/scb_${DATE}.bak"
ENC="${PLAIN}.gpg"
sudo -u lnd /usr/local/bin/lncli exportchanbackup --multi_file "$PLAIN"
if [[ -n "${ENC_PASS:-}" ]]; then
  echo -n "$ENC_PASS" | gpg --batch --yes --passphrase-fd 0 -c -o "$ENC" "$PLAIN"
else
  gpg --batch --yes -c -o "$ENC" "$PLAIN"
fi
shred -u "$PLAIN"
SCRIPT
chmod 0755 "$SCRIPT_PATH"
cat > /etc/systemd/system/lnd-backup.service <<SERVICE
[Unit]
Description=Encrypted LND SCB backup
[Service]
Type=oneshot
Environment=ENC_PASS=${ENC_PASS:-}
ExecStart=$SCRIPT_PATH
User=root
Group=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SERVICE
cat > /etc/systemd/system/lnd-backup.timer <<'TIMER'
[Unit]
Description=Run LND backup daily
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now lnd-backup.timer
ok "Encrypted LND backup configured. Backups stored in ${BACKUP_DIR} and rotated daily."
set_state backup.setup
