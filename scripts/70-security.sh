#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
. lib/common.sh

require_root
load_env
ensure_state_dir
detect_pkg_mgr   # in Debian userà apt/apt-get secondo la tua implementazione
pkg_update

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

# -------------------------------------------------------------------
# Fail2ban (SSH)
# -------------------------------------------------------------------
log "Installing Fail2ban (basic SSH protection)"
pkg_install fail2ban || true

if systemctl list-unit-files | grep -q '^fail2ban\.service'; then
  JAILD="/etc/fail2ban/jail.d"; mkdir -p "$JAILD"
  cat > "$JAILD/sshd.local" <<'CONF'
[sshd]
enabled  = true
mode     = aggressive
backend  = systemd
port     = ssh        # metti qui la tua porta se diversa
maxretry = 5
findtime = 10m
bantime  = 1h
CONF
  systemctl enable --now fail2ban
  ok "Fail2ban enabled"
  DID_FAIL2BAN=true
else
  warn "Fail2ban non installato (manca l'unit). Verifica il package manager e riprova."
  DID_FAIL2BAN=false
fi

# -------------------------------------------------------------------
# Monit (opzionale)
# -------------------------------------------------------------------
if confirm "Install Monit to watch bitcoind, lnd, tor?"; then
  pkg_install monit || true

  if systemctl list-unit-files | grep -q '^monit\.service'; then
    MONITRC="/etc/monit/monitrc"

    # Abilita l'HTTPD locale nell'rc principale (presenti commentati su Debian)
    sed -i 's/^# *set httpd/set httpd/' "$MONITRC" || true
    sed -i 's/^# *use address.*/   use address localhost/' "$MONITRC" || true
    sed -i 's/^# *allow localhost.*/   allow localhost/' "$MONITRC" || true

    mkdir -p /etc/monit/conf.d

    cat > /etc/monit/conf.d/bitcoin.conf <<'CONF'
check process bitcoind matching "bitcoind"
  start program = "/bin/systemctl start bitcoind"
  stop  program = "/bin/systemctl stop bitcoind"
  if 5 restarts within 5 cycles then alert
CONF

    cat > /etc/monit/conf.d/lnd.conf <<'CONF'
check process lnd matching "lnd"
  start program = "/bin/systemctl start lnd"
  stop  program = "/bin/systemctl stop lnd"
  if 5 restarts within 5 cycles then alert
CONF

    cat > /etc/monit/conf.d/tor.conf <<'CONF'
check process tor matching "tor"
  start program = "/bin/systemctl start tor"
  stop  program = "/bin/systemctl stop tor"
  if does not exist for 3 cycles then restart
CONF

    systemctl enable --now monit
    ok "Monit installed and configured"
    DID_MONIT=true
  else
    warn "Monit non installato (manca l'unit)."
    DID_MONIT=false
  fi
fi

# -------------------------------------------------------------------
# DNS via Tor (opzionale) - Debian 12/13
# -------------------------------------------------------------------
if confirm "Route system DNS through Tor (DNSPort)?"; then
  # Assicura tor installato (su Debian si chiama 'tor')
  pkg_install tor || true

  # Attiva DNSPort su 127.0.0.1:5353 in /etc/tor/torrc (aggiunge se mancante)
  if ! grep -qE '^\s*DNSPort\s+127\.0\.0\.1:5353\b' /etc/tor/torrc 2>/dev/null; then
    printf "\n# Enable DNS over Tor\nDNSPort 127.0.0.1:5353\n" >> /etc/tor/torrc
    systemctl restart tor || true
  fi

  # Su Debian usiamo resolvconf (pacchetto 'resolvconf')
  if ! command -v resolvconf >/dev/null 2>&1; then
    pkg_install resolvconf || true
  fi

  # Configura resolvconf: testa il resolver a 127.0.0.1
  mkdir -p /etc/resolvconf/resolv.conf.d 2>/dev/null || true
  echo "nameserver 127.0.0.1" > /etc/resolvconf/resolv.conf.d/head
  resolvconf -u || true

  # In caso /etc/resolv.conf non sia gestito da resolvconf, forziamo e proteggiamo
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
# Summary + Useful Commands 
# -------------------------------------------------------------------
echo
echo "==================== Security Setup Summary ===================="

# ---- Fail2ban ----
if $DID_FAIL2BAN; then
  F2B_STATUS=$(systemctl is-active fail2ban || true)
  F2B_VERSION=$(fail2ban-server --version 2>/dev/null | head -n1 || echo "unknown")
  echo "• Fail2ban: ENABLED ($F2B_STATUS)"
  echo "    Version   : $F2B_VERSION"
  echo "    Jail file : /etc/fail2ban/jail.d/sshd.local"
  echo "    Service   : systemctl status fail2ban"
  echo "    Useful:"
  echo "      - Overall status ..........: fail2ban-client status"
  echo "      - SSHD jail status ........: fail2ban-client status sshd"
  echo "      - Unban IP .................: fail2ban-client set sshd unbanip <IP>"
  echo "      - Logs (service) ..........: journalctl -u fail2ban -n 100 --no-pager"
  echo "      - Config dir ..............: /etc/fail2ban/"
else
  echo "• Fail2ban: not installed (skipped)"
fi
echo

# ---- Monit ----
if $DID_MONIT; then
  MONIT_STATUS=$(systemctl is-active monit || true)
  MONIT_VERSION=$(monit -V 2>/dev/null | head -n1 || echo "unknown")
  echo "• Monit: INSTALLED & ENABLED ($MONIT_STATUS)"
  echo "    Version   : $MONIT_VERSION"
  echo "    Conf dir  : /etc/monit/conf.d/"
  echo "    Main conf : /etc/monit/monitrc (HTTP on localhost)"
  echo "    Checks    : bitcoind, lnd, tor"
  echo "    Useful:"
  echo "      - Status (all) ............: monit status"
  echo "      - Reload config ...........: monit reload"
  echo "      - Restart a check .........: monit restart <name>"
  echo "      - Service logs ............: journalctl -u monit -n 100 --no-pager"
else
  echo "• Monit: not installed (skipped)"
fi
echo

# ---- DNS via Tor ----
if $DID_TOR_DNS; then
  TOR_STATUS=$(systemctl is-active tor || true)
  TOR_VERSION=$(tor --version 2>/dev/null | head -n1 || echo "unknown")
  echo "• System DNS via Tor: ENABLED ($TOR_STATUS)"
  echo "    Version   : $TOR_VERSION"
  echo "    torrc     : /etc/tor/torrc (DNSPort 127.0.0.1:5353)"
  echo "    resolv.conf points to 127.0.0.1"
  echo "    Useful:"
  echo "      - Test DNS ................: dig +short @127.0.0.1 -p 5353 example.com"
  echo "      - Check port ..............: ss -ltnp | grep ':5353'"
  echo "      - Tor service logs ........: journalctl -u tor -n 100 --no-pager"
else
  echo "• System DNS via Tor: not enabled (skipped)"
fi

echo "================================================================"
echo

# ---- Schermata finale / ritorno al menu ----
read -n1 -s -r -p "Press any key to return to the main menu..."
echo
[[ -x ./scripts/menu.sh ]] && exec ./scripts/menu.sh || exit 0


