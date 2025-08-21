#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

# ---- Parametri configurabili (override da .env) ----
: "${THUNDERHUB_PORT:=3010}"           # porta interna (app) - solo loopback
: "${NGINX_TH_PORT:=8080}"             # porta Nginx per l’accesso locale/LAN
: "${THUNDERHUB_VERSION:=latest}"      # tag/branch o "latest"
: "${NETWORK:=mainnet}"                # mainnet|testnet|signet|regtest
: "${LND_DATA_DIR:=/data/lnd}"
: "${LND_USER:=lnd}"

if has_state thunderhub.installed; then
  ok "ThunderHub already installed"
  exit 0
fi

pkg_update

# ---- Node.js LTS + deps ----
if ! command -v node >/dev/null 2>&1; then
  case "$pkg_mgr" in
    apt)
      curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
      apt-get install -y nodejs git build-essential
      ;;
    dnf|yum)
      pkg_install nodejs npm git @development-tools
      ;;
    *)
      warn "Unknown pkg manager '$pkg_mgr'; trying generic nodejs/npm/git."
      pkg_install nodejs npm git || true
      ;;
  esac
fi

# ---- utente + dir ----
ensure_user thunderhub
mkdir -p /opt/thunderhub /etc/thunderhub
chown -R thunderhub:thunderhub /opt/thunderhub /etc/thunderhub

# ---- clone + build come thunderhub ----
if [[ ! -d /opt/thunderhub/app/.git ]]; then
  sudo -u thunderhub git clone --depth 1 https://github.com/apotdevin/thunderhub.git /opt/thunderhub/app
fi
pushd /opt/thunderhub/app >/dev/null
if [[ "${THUNDERHUB_VERSION}" != "latest" ]]; then
  sudo -u thunderhub git fetch --tags
  sudo -u thunderhub git checkout "${THUNDERHUB_VERSION}" || true
fi
sudo -u thunderhub npm ci || sudo -u thunderhub npm install
sudo -u thunderhub npm run build
popd >/dev/null

# ---- config ThunderHub ----
MACAROON_PATH="${LND_DATA_DIR}/data/chain/bitcoin/${NETWORK}/admin.macaroon"
CERT_PATH="${LND_DATA_DIR}/tls.cert"

# genera master password se non fornita da .env (TH_MASTER_PASSWORD)
: "${TH_MASTER_PASSWORD:=}"
if [[ -z "${TH_MASTER_PASSWORD}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    TH_MASTER_PASSWORD="$(openssl rand -hex 16)"
  else
    TH_MASTER_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  fi
fi

cat > /etc/thunderhub/thunderhub.env <<CONF
PORT=${THUNDERHUB_PORT}
HOST=127.0.0.1
ACCOUNT_CONFIG_PATH=/etc/thunderhub/thub.config.yaml
LOG_LEVEL=info
NODE_ENV=production
CONF

cat > /etc/thunderhub/thub.config.yaml <<CONF
masterPassword: ${TH_MASTER_PASSWORD}
accounts:
  - name: local-lnd
    serverUrl: 127.0.0.1:10009
    macaroonPath: ${MACAROON_PATH}
    certificatePath: ${CERT_PATH}
CONF
chown -R thunderhub:thunderhub /etc/thunderhub

# ---- ACL: consenti lettura macaroon/tls a thunderhub ----
if ! command -v setfacl >/dev/null 2>&1; then
  case "$pkg_mgr" in
    apt) apt-get install -y acl ;;
    dnf|yum) pkg_install acl ;;
  esac
fi
# traversal + lettura puntuale
setfacl -m u:thunderhub:rx /data || true
setfacl -m u:thunderhub:rx "${LND_DATA_DIR}" || true
setfacl -m u:thunderhub:rx "${LND_DATA_DIR}/data" || true
setfacl -m u:thunderhub:rx "${LND_DATA_DIR}/data/chain" || true
setfacl -m u:thunderhub:rx "${LND_DATA_DIR}/data/chain/bitcoin" || true
setfacl -m u:thunderhub:rx "${LND_DATA_DIR}/data/chain/bitcoin/${NETWORK}" || true
setfacl -d -m u:thunderhub:rx "${LND_DATA_DIR}/data/chain/bitcoin/${NETWORK}" || true
setfacl -m u:thunderhub:r  "${MACAROON_PATH}" || true
setfacl -m u:thunderhub:r  "${CERT_PATH}" || true

# ---- systemd: ThunderHub ----
cat > /etc/systemd/system/thunderhub.service <<SERVICE
[Unit]
Description=ThunderHub
After=network.target lnd.service
Requires=lnd.service

[Service]
User=thunderhub
Group=thunderhub
EnvironmentFile=/etc/thunderhub/thunderhub.env
WorkingDirectory=/opt/thunderhub/app
ExecStart=/usr/bin/npm run start
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
enable_start thunderhub.service

# ---- Nginx reverse-proxy ----
case "$pkg_mgr" in
  apt) apt-get install -y nginx ;;
  dnf|yum) pkg_install nginx ;;
esac

# site config
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled || true
cat > /etc/nginx/sites-available/thunderhub <<'NGX'
server {
    listen 0.0.0.0:8080 default_server;
    server_name _;

    # sicurezza base
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer-when-downgrade always;

    # reverse proxy verso app
    location / {
        proxy_pass http://127.0.0.1:3010;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGX

# sostituisci porta di ascolto Nginx se NGINX_TH_PORT != 8080
if [[ "${NGINX_TH_PORT}" != "8080" ]]; then
  sed -i "s/listen 0\.0\.0\.0:8080 default_server;/listen 0.0.0.0:${NGINX_TH_PORT} default_server;/" /etc/nginx/sites-available/thunderhub
fi

# sostituisci porta app se THUNDERHUB_PORT != 3010
if [[ "${THUNDERHUB_PORT}" != "3010" ]]; then
  sed -i "s|proxy_pass http://127\.0\.0\.1:3010;|proxy_pass http://127.0.0.1:${THUNDERHUB_PORT};|" /etc/nginx/sites-available/thunderhub
fi

# abilita sito
if [[ -d /etc/nginx/sites-enabled ]]; then
  ln -sf /etc/nginx/sites-available/thunderhub /etc/nginx/sites-enabled/thunderhub
else
  # distros senza sites-* usano direttamente conf.d
  cp /etc/nginx/sites-available/thunderhub /etc/nginx/conf.d/thunderhub.conf
fi

# rimuovi default-site se presente (Debian/Ubuntu)
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl enable --now nginx
systemctl reload nginx || true

# ---- Firewall: apri la porta Nginx di ThunderHub ----
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${NGINX_TH_PORT}/tcp" || true
  ufw reload || true
  ok "UFW rule added: allow ${NGINX_TH_PORT}/tcp"
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --add-port="${NGINX_TH_PORT}/tcp" --permanent || true
  firewall-cmd --reload || true
  ok "firewalld rule added: port ${NGINX_TH_PORT}/tcp"
else
  warn "No ufw/firewalld detected; please open TCP ${NGINX_TH_PORT} manually if needed."
fi

# ---- Tor Onion (HiddenService) → Nginx ----
ONION_DIR="/var/lib/tor/thunderhub"

# install tor se manca
if ! command -v tor >/dev/null 2>&1; then
  case "$pkg_mgr" in
    apt) apt-get install -y tor ;;
    dnf|yum) pkg_install tor ;;
  esac
fi

# Aggiungi la configurazione di Hidden Service direttamente al file torrc
# La configurazione viene aggiunta solo se non esiste già
if ! grep -q "HiddenServiceDir ${ONION_DIR}" /etc/tor/torrc; then
  cat >> /etc/tor/torrc <<TOR
# ThunderHub Onion Service
HiddenServiceDir ${ONION_DIR}
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:${NGINX_TH_PORT}
TOR
fi

# Crea e proteggi la directory HS (necessaria per hostname/keys)
mkdir -p "${ONION_DIR}"
chown -R debian-tor:debian-tor "${ONION_DIR}"
chmod 0700 "${ONION_DIR}"

# avvia tor (supporta sia 'tor' che 'tor@default')
(systemctl enable --now tor || systemctl enable --now tor@default) || true
(systemctl reload tor || systemctl reload tor@default) || true

# leggi hostname onion (può richiedere qualche secondo dopo reload)
ONION_HOST=""
for _ in $(seq 1 20); do
  if [[ -f "${ONION_DIR}/hostname" ]]; then
    ONION_HOST="$(cat "${ONION_DIR}/hostname" 2>/dev/null || true)"
    [[ -n "${ONION_HOST}" ]] && break
  fi
  sleep 1
done

# ---- Output finale: URL locali e Onion + credenziali ----
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${LOCAL_IP}" ]] && LOCAL_IP="127.0.0.1"

echo
ok "ThunderHub is ready!"
echo "Local (via Nginx):  http://${LOCAL_IP}:${NGINX_TH_PORT}/"
echo "Local (loopback):   http://127.0.0.1:${NGINX_TH_PORT}/"
if [[ -n "${ONION_HOST}" ]]; then
  echo "Onion (via Tor):    http://${ONION_HOST}/"
else
  echo "Onion (via Tor):    pending… (Tor is creating the service; check again in a few seconds)"
fi
echo "Login password (master): ${TH_MASTER_PASSWORD}"
echo "Account: local-lnd"

set_state thunderhub.installed
# ---- Pausa finale per l'utente ----
echo ""
echo "Please take note of the information above."
echo "Press any key to return to the main menu..."
read -n 1 -s
