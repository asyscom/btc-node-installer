#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

# ---- state flags for summary ----
DID_FAIL2BAN=false
DID_MONIT=false
DID_TOR_DNS=false

if has_state security.setup; then
  ok "Security base already configured"
  echo
  echo "Nothing to do. Security base was already configured."
  echo
  read -n1 -s -r -p "Press any key to return to the main menu..."
  echo
  [[ -x ./scripts/menu.sh ]] && exec ./scripts/menu.sh || exit 0
fi

detect_pkg_mgr; pkg_update

# -------------------------------------------------------------------
# Fail2ban (SSH)
# -------------------------------------------------------------------
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
systemctl enable --now fail2ban
ok "Fail2ban enabled"
DID_FAIL2BAN=true

# -------------------------------------------------------------------
# Monit (opzionale)
# -------------------------------------------------------------------
if confirm "Install Monit to watch bitcoind, lnd, tor?"; then
  pkg_install monit
  MONITRC="/etc/monit/monitrc"
  sed -i 's/^# *set httpd/set httpd/' "$MONITRC" || true
  sed -i 's/^# *use address.*/   use address localhost/' "$MONITRC" || true
  sed -i 's/^# *allow localhost.*/   allow localhost/' "$MONITRC" || true

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

  systemctl enable --now monit
  ok "Monit installed and configured"
  DID_MONIT=true
fi

# -------------------------------------------------------------------
# DNS via Tor (opzionale)
# -------------------------------------------------------------------
if confirm "Route system DNS through Tor (DNSPort)?"; then
  if ! grep -q "^DNSPort" /etc/tor/torrc 2>/dev/null; then
    printf "\nDNSPort 127.0.0.1:5353\n" >> /etc/tor/torrc
    systemctl restart tor || true
  fi

  if ! command -v resolvconf >/dev/null 2>&1; then
    pkg_install resolvconf || true
  fi

  mkdir -p /etc/resolvconf/resolv.conf.d 2>/dev/null || true
  if [[ -d /etc/resolvconf/resolv.conf.d ]]; then
    echo "nameserver 127.0.0.1" > /etc/resolvconf/resolv.conf.d/head
    resolvconf -u || true
  fi

  if ! grep -q "127.0.0.1" /etc/resolv.conf 2>/dev/null; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    printf "nameserver 127.0.0.1\n" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
  fi

  ok "System DNS now routed to Tor (127.0.0.1:5353)."
  DID_TOR_DNS=true
fi

set_state security.setup
ok "Security base setup complete."

# -------------------------------------------------------------------
# RIEPILOGO
# -------------------------------------------------------------------
echo
echo "==================== Security Setup Summary ===================="
if $DID_FAIL2BAN; then
  STATUS=$(systemctl is-active fail2ban || true)
  VERSION=$(fail2ban-server --version 2>/dev/null | head -n1 || echo "unknown")
  echo "• Fail2ban: ENABLED ($STATUS)"
  echo "    Version   : $VERSION"
  echo "    Jail file : /etc/fail2ban/jail.d/sshd.local"
  echo "    Service   : systemctl status fail2ban"
else
  echo "• Fail2ban: already present (no changes)"
fi

if $DID_MONIT; then
  STATUS=$(systemctl is-active monit || true)
  VERSION=$(monit -V 2>/dev/null | head -n1 || echo "unknown")
  echo "• Monit: INSTALLED & ENABLED ($STATUS)"
  echo "    Version   : $VERSION"
  echo "    Conf dir  : /etc/monit/conf.d/"
  echo "    Main conf : /etc/monit/monitrc (HTTP on localhost)"
  echo "    Service   : systemctl status monit"
  echo "    Checks    : bitcoind, lnd, tor"
else
  echo "• Monit: not installed (skipped)"
fi

if $DID_TOR_DNS; then
  STATUS=$(systemctl is-active tor || systemctl is-active tor@default || true)
  VERSION=$(tor --version 2>/dev/null | head -n1 || echo "unknown")
  echo "• System DNS via Tor: ENABLED ($STATUS)"
  echo "    Version   : $VERSION"
  echo "    torrc     : /etc/tor/torrc (DNSPort 127.0.0.1:5353)"
  echo "    resolv.conf points to 127.0.0.1"
else
  echo "• System DNS via Tor: not enabled (skipped)"
fi
echo "================================================================"
echo

read -n1 -s -r -p "Press any key to return to the main menu..."
echo
[[ -x ./scripts/menu.sh ]] && exec ./scripts/menu.sh || exit 0

