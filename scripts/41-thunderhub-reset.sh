#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

# ---- Parametri/percorsi noti (rispettano .env se presente) ----
: "${LND_DATA_DIR:=/data/lnd}"
: "${NETWORK:=mainnet}"
: "${NGINX_TH_PORT:=8080}"       # porta Nginx usata da ThunderHub (reverse proxy)

TH_USER="thunderhub"
TH_APP_DIR="/opt/thunderhub"
TH_CONF_DIR="/etc/thunderhub"
TH_SVC="thunderhub.service"

# Nginx
NGX_AVAIL="/etc/nginx/sites-available/thunderhub"
NGX_ENABLED="/etc/nginx/sites-enabled/thunderhub"
NGX_CONF_D="/etc/nginx/conf.d/thunderhub.conf"

# Tor HS
TOR_DROPIN="/etc/tor/torrc.d/thunderhub.conf"
TOR_HS_DIR="/var/lib/tor/thunderhub"

# LND secrets paths (ACL da revocare)
MACAROON_PATH="${LND_DATA_DIR}/data/chain/bitcoin/${NETWORK}/admin.macaroon"
CERT_PATH="${LND_DATA_DIR}/tls.cert"

echo "[i] Reset ThunderHub: inizializzo…"

# ---- Fermare/Disabilitare il servizio ----
if systemctl list-unit-files | grep -q "^${TH_SVC}"; then
  systemctl stop "${TH_SVC}" || true
  systemctl disable "${TH_SVC}" || true
  rm -f "/etc/systemd/system/${TH_SVC}"
  systemctl daemon-reload
  echo "[ok] Service ${TH_SVC} rimosso"
else
  echo "[i] Service ${TH_SVC} non presente"
fi

# ---- Pulizia app/config ----
rm -rf "${TH_APP_DIR}" "${TH_CONF_DIR}" || true
echo "[ok] Rimossi ${TH_APP_DIR} e ${TH_CONF_DIR}"

# ---- Nginx: rimuovi sito e reload ----
if command -v nginx >/dev/null 2>&1; then
  rm -f "${NGX_ENABLED}" "${NGX_AVAIL}" "${NGX_CONF_D}" || true
  if nginx -t; then
    systemctl reload nginx || systemctl restart nginx || true
  fi
  echo "[ok] Pulizia Nginx completata"
else
  echo "[i] Nginx non installato, salto"
fi

# ---- Tor: rimuovi HiddenService e drop-in, poi reload ----
if command -v tor >/dev/null 2>&1; then
  rm -f "${TOR_DROPIN}" || true
  rm -rf "${TOR_HS_DIR}" || true
  systemctl reload tor || systemctl restart tor || true
  echo "[ok] Tor HS di ThunderHub rimossa"
else
  echo "[i] Tor non installato, salto"
fi

# ---- Revoca ACL su macaroon/tls (se setfacl disponibile) ----
if command -v setfacl >/dev/null 2>&1; then
  for p in "${MACAROON_PATH}" "${CERT_PATH}"; do
    if [[ -f "$p" ]]; then
      setfacl -x u:${TH_USER} "$p" || true
    fi
  done
  # traversal dirs: proviamo a rimuovere l’ACL esplicita (ignorato se non c’è)
  setfacl -x u:${TH_USER} /data || true
  setfacl -x u:${TH_USER} "${LND_DATA_DIR}" || true
  setfacl -x u:${TH_USER} "${LND_DATA_DIR}/data" || true
  setfacl -x u:${TH_USER} "${LND_DATA_DIR}/data/chain" || true
  setfacl -x u:${TH_USER} "${LND_DATA_DIR}/data/chain/bitcoin" || true
  setfacl -x u:${TH_USER} "${LND_DATA_DIR}/data/chain/bitcoin/${NETWORK}" || true
  echo "[ok] ACL revocate per utente ${TH_USER}"
fi

# ---- Rimuovere utente/gruppo thunderhub ----
if id -u "${TH_USER}" >/dev/null 2>&1; then
  # rimuove utente, home e mail spool (se esistono)
  userdel -r "${TH_USER}" 2>/dev/null || userdel "${TH_USER}" || true
  echo "[ok] Utente ${TH_USER} rimosso"
else
  echo "[i] Utente ${TH_USER} non esisteva"
fi

# ---- Chiudere firewall (porta Nginx ThunderHub) ----
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow "${NGINX_TH_PORT}/tcp" || true
  ufw reload || true
  echo "[ok] UFW: regola su ${NGINX_TH_PORT}/tcp rimossa"
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --remove-port="${NGINX_TH_PORT}/tcp" --permanent || true
  firewall-cmd --reload || true
  echo "[ok] firewalld: regola su ${NGINX_TH_PORT}/tcp rimossa"
else
  echo "[i] Nessun firewall gestito automaticamente rilevato"
fi

echo
ok "Reset ThunderHub completato."
echo "Ora puoi rilanciare l’installazione dal menu:  '40 - ThunderHub'."

