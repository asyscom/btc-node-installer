#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr
if has_state security.setup; then ok "Security base already configured"; exit 0; fi
detect_pkg_mgr; pkg_update
log "Installing Fail2ban (basic SSH protection)"
pkg_install fail2ban
JAILD="/etc/fail2ban/jail.d"; mkdir -p "$JAILD"
cat > "$JAILD/sshd.local" <<'CONF'
[sshd]
enabled = true
mode = aggressive
port = ssh
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
CONF
systemctl enable --now fail2ban; ok "Fail2ban enabled"

if confirm "Install Monit to watch bitcoind, lnd, tor?"; then
  pkg_install monit
  MONITRC="/etc/monit/monitrc"
  sed -i 's/^# set httpd/set httpd/' "$MONITRC" || true
  sed -i 's/^#    use address.*/   use address localhost/' "$MONITRC" || true
  sed -i 's/^#    allow localhost.*/   allow localhost/' "$MONITRC" || true
  cat > /etc/monit/conf.d/bitcoin.conf <<'CONF'
check process bitcoind matching "bitcoind"
  start program = "/bin/systemctl start bitcoind"
  stop program  = "/bin/systemctl stop bitcoind"
  if 5 restarts within 5 cycles then alert
CONF
  cat > /etc/monit/conf.d/lnd.conf <<'CONF'
check process lnd matching "lnd"
  start program = "/bin/systemctl start lnd"
  stop program  = "/bin/systemctl stop lnd"
  if 5 restarts within 5 cycles then alert
CONF
  cat > /etc/monit/conf.d/tor.conf <<'CONF'
check process tor matching "tor"
  start program = "/bin/systemctl start tor"
  stop program  = "/bin/systemctl stop tor"
  if does not exist for 3 cycles then restart
CONF
  systemctl enable --now monit; ok "Monit installed and configured"
fi

if confirm "Install I2P (optional)?"; then
  pkg_install i2p; systemctl enable --now i2p || true; ok "I2P installed"
fi

if confirm "Route system DNS through Tor (DNSPort)?"; then
  if ! grep -q "^DNSPort" /etc/tor/torrc 2>/dev/null; then
    printf "\nDNSPort 127.0.0.1:5353\n" >> /etc/tor/torrc; systemctl restart tor || true
  fi
  if ! command -v resolvconf >/dev/null 2>&1; then pkg_install resolvconf || true; fi
  mkdir -p /etc/resolvconf/resolv.conf.d
  echo "nameserver 127.0.0.1" > /etc/resolvconf/resolv.conf.d/head
  resolvconf -u || true
  if ! grep -q "127.0.0.1" /etc/resolv.conf 2>/dev/null; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
  fi
  ok "System DNS now routed to Tor (127.0.0.1:5353)."
fi

set_state security.setup
ok "Security base setup complete."
