#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh

require_root; load_env; ensure_state_dir; detect_pkg_mgr

# --- Porte e variabili default ---------------------------------------------
MEMPOOL_PUBLIC_PORT="${MEMPOOL_PUBLIC_PORT:-4080}"    # porta esterna (Nginx)
MEMPOOL_BACKEND_PORT="${MEMPOOL_BACKEND_PORT:-8999}"  # backend mempool
BITCOIN_DATA_DIR="${BITCOIN_DATA_DIR:-/data/bitcoin}"
BITCOIN_RPC_PORT="${BITCOIN_RPC_PORT:-8332}"
ELECTRS_HOST="${ELECTRS_HOST:-127.0.0.1}"
ELECTRS_PORT="${ELECTRS_PORT:-50001}"

# Se già installato, esci
if has_state mempool.installed; then
  ok "Mempool already installed"
  # Mostra comunque il riepilogo e rientra al menu
  echo
  echo "Premi un tasto per tornare al menu..."
  read -n 1 -s
  exit 0
fi

pkg_update

# --- Dipendenze ------------------------------------------------------------
case "$pkg_mgr" in
  apt)
    pkg_install git mariadb-server redis-server curl ca-certificates nginx acl
    ;;
  dnf|yum)
    pkg_install git mariadb-server redis curl ca-certificates nginx acl
    ;;
esac

# Servizi DB/Redis/Nginx
systemctl enable --now mariadb || true
systemctl enable --now redis-server || systemctl enable --now redis || true
systemctl enable --now nginx || true

# --- Node.js LTS se manca ---------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  case "$pkg_mgr" in
    apt)
      curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
      apt-get install -y nodejs
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
  esac
fi

# --- Utente e dir -----------------------------------------------------------
ensure_user mempool
mkdir -p /opt/mempool /etc/mempool
chown -R mempool:mempool /opt/mempool /etc/mempool

# --- Database ---------------------------------------------------------------
# Password random per l’utente db (la mostriamo nel summary)
DB_PASS="$(openssl rand -hex 16)"

# Usa il client MariaDB “nativo” (via unix_socket) per evitare noie di root@localhost
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS mempool CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'mempool'@'localhost'  IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS 'mempool'@'127.0.0.1'  IDENTIFIED BY '${DB_PASS}';

ALTER USER 'mempool'@'localhost'  IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_PASS}');
ALTER USER 'mempool'@'127.0.0.1'  IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_PASS}');

GRANT ALL PRIVILEGES ON mempool.* TO 'mempool'@'localhost';
GRANT ALL PRIVILEGES ON mempool.* TO 'mempool'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Created DB 'mempool' and users 'mempool'@'localhost' & '127.0.0.1'."

# --- Codice sorgente --------------------------------------------------------
(
  cd /
  if [[ ! -d /opt/mempool/mempool/.git ]]; then
    rm -rf /opt/mempool/mempool 2>/dev/null || true
    sudo -u mempool -H git clone https://github.com/mempool/mempool.git /opt/mempool/mempool
  fi
  sudo -u mempool -H git -C /opt/mempool/mempool submodule update --init --recursive
  sudo -u mempool -H git config --global --add safe.directory /opt/mempool/mempool || true
)

# --- Config backend ---------------------------------------------------------
# NB: Backend = electrum; Core RPC via COOKIE (no user/pass)
install -o mempool -g mempool -m 0644 /dev/stdin /etc/mempool/mempool-config.json <<CONF
{
  "MEMPOOL": {
    "NETWORK": "${NETWORK}",
    "BACKEND": "electrum",
    "DB": {
      "HOST": "127.0.0.1",
      "PORT": 3306,
      "USER": "mempool",
      "PASSWORD": "${DB_PASS}",
      "DATABASE": "mempool"
    }
  },
  "ELECTRUM": {
    "HOST": "${ELECTRS_HOST}",
    "PORT": ${ELECTRS_PORT},
    "TLS": false,
    "TLS_ENABLED": false
  },
  "CORE_RPC": {
    "HOST": "127.0.0.1",
    "PORT": ${BITCOIN_RPC_PORT},
    "COOKIE": true,
    "COOKIE_PATH": "${BITCOIN_DATA_DIR}/.cookie"
  },
  "API": {
    "ENABLED": true,
    "HOST": "127.0.0.1",
    "PORT": ${MEMPOOL_BACKEND_PORT}
  },
  "REDIS": {
    "ENABLED": true,
    "HOST": "127.0.0.1",
    "PORT": 6379
  }
}
CONF

# --- Backend deps (no migrations manuali: il backend le gestisce da solo) ---
(
  cd /opt/mempool/mempool/backend
  if [[ -f package-lock.json ]]; then
    sudo -u mempool -H npm ci --omit=dev || sudo -u mempool -H npm ci
  else
    sudo -u mempool -H npm install --omit=dev || sudo -u mempool -H npm install
  fi
  sudo -u mempool -H npm run build || true
)

# --- ACL per il cookie di bitcoind -----------------------------------------
# Concedi a 'mempool' traversal + lettura del file cookie
install -d -m 0755 /data
install -d -m 0750 "${BITCOIN_DATA_DIR}"
setfacl -m u:mempool:rx /data || true
setfacl -m u:mempool:rx "${BITCOIN_DATA_DIR}" || true
[[ -f "${BITCOIN_DATA_DIR}/.cookie" ]] && setfacl -m u:mempool:r "${BITCOIN_DATA_DIR}/.cookie" || true

# --- systemd (backend) ------------------------------------------------------
cat > /etc/systemd/system/mempool-backend.service <<SERVICE
[Unit]
Description=Mempool Backend (API + static)
After=network.target mariadb.service redis-server.service bitcoind.service electrs.service
Requires=mariadb.service redis-server.service bitcoind.service
Wants=electrs.service

[Service]
User=mempool
Group=mempool
WorkingDirectory=/opt/mempool/mempool/backend
Environment=MEMPOOL_CONFIG=/etc/mempool/mempool-config.json
# Attendi cookie + bitcoind RPC
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do [ -f "${BITCOIN_DATA_DIR}/.cookie" ] && sudo -u bitcoin bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir="${BITCOIN_DATA_DIR}" getblockchaininfo >/dev/null 2>&1 && exit 0; sleep 2; done; exit 0'
ExecStart=/usr/bin/node /opt/mempool/mempool/backend/dist/index.js
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
enable_start mempool-backend.service

# --- Nginx reverse proxy (:MEMPOOL_PUBLIC_PORT -> backend) ------------------
SERVER_NAME="${MEMPOOL_SERVER_NAME:-_}"

NGINX_DEBIAN_SITE="/etc/nginx/sites-available/mempool.conf"
NGINX_DEBIAN_LINK="/etc/nginx/sites-enabled/mempool.conf"
NGINX_RHEL_SITE="/etc/nginx/conf.d/mempool.conf"

NGINX_CONF_CONTENT=$(cat <<NGX
# Mempool reverse proxy (locale)
server {
    listen ${MEMPOOL_PUBLIC_PORT};
    server_name ${SERVER_NAME};

    # proxy principale
    location / {
        proxy_pass http://127.0.0.1:${MEMPOOL_BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
    }

    # WebSocket (aggiornamenti live)
    location /api/v1/ws {
        proxy_pass http://127.0.0.1:${MEMPOOL_BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 300;
    }

    # Statici (cache 7 giorni)
    location ~* \.(js|css|png|jpg|jpeg|gif|svg|ico|woff2?)\$ {
        proxy_pass http://127.0.0.1:${MEMPOOL_BACKEND_PORT};
        expires 7d;
        access_log off;
    }
}
NGX
)

case "$pkg_mgr" in
  apt)
    [[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default || true
    echo "$NGINX_CONF_CONTENT" > "$NGINX_DEBIAN_SITE"
    ln -sf "$NGINX_DEBIAN_SITE" "$NGINX_DEBIAN_LINK"
    ;;
  dnf|yum)
    echo "$NGINX_CONF_CONTENT" > "$NGINX_RHEL_SITE"
    ;;
esac

# SELinux (solo RHEL-like)
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  command -v setsebool >/dev/null 2>&1 && setsebool -P httpd_can_network_connect 1 || true
fi

nginx -t
systemctl reload nginx

# --- FIREWALL ---------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  ufw allow ${MEMPOOL_PUBLIC_PORT}/tcp || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --add-port=${MEMPOOL_PUBLIC_PORT}/tcp --permanent || true
  firewall-cmd --reload || true
else
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport ${MEMPOOL_PUBLIC_PORT} -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport ${MEMPOOL_PUBLIC_PORT} -j ACCEPT
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
  fi
fi

# --- Tor Hidden Service opzionale ------------------------------------------
if ! command -v tor >/dev/null 2>&1; then
  case "$pkg_mgr" in
    apt)     apt-get update -y && apt-get install -y tor ;;
    dnf|yum) pkg_install tor ;;
  esac
fi

HS_DIR="/var/lib/tor/mempool"
mkdir -p "${HS_DIR}"
chown -R debian-tor:debian-tor "${HS_DIR}"
chmod 0700 "${HS_DIR}"

if ! grep -q "HiddenServiceDir ${HS_DIR}" /etc/tor/torrc 2>/dev/null; then
  cat >> /etc/tor/torrc <<TOR
# Mempool Onion Service
HiddenServiceDir ${HS_DIR}
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:${MEMPOOL_PUBLIC_PORT}
HiddenServicePort ${MEMPOOL_PUBLIC_PORT} 127.0.0.1:${MEMPOOL_PUBLIC_PORT}
TOR
fi

(systemctl enable --now tor || systemctl enable --now tor@default) || true
(systemctl reload tor || systemctl reload tor@default) || true

MEMPOOL_ONION=""
for _ in $(seq 1 20); do
  [[ -f "${HS_DIR}/hostname" ]] && MEMPOOL_ONION="$(cat "${HS_DIR}/hostname" 2>/dev/null || true)"
  [[ -n "${MEMPOOL_ONION}" ]] && break
  sleep 1
done

ok "Mempool backend on 127.0.0.1:${MEMPOOL_BACKEND_PORT}. Nginx listening on 0.0.0.0:${MEMPOOL_PUBLIC_PORT}."
set_state mempool.installed

# ---------------------- SUMMARY + ritorno al menu ---------------------------
echo
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
NGINX_PATH="$( [[ $pkg_mgr == apt ]] && echo /etc/nginx/sites-available/mempool.conf || echo /etc/nginx/conf.d/mempool.conf )"

ok "Summary:"
echo "  • DB user: mempool  | DB name: mempool  | Pass: ${DB_PASS}"
echo "  • Public URL:  http://${SERVER_IP}:${MEMPOOL_PUBLIC_PORT}/"
[[ -n "${MEMPOOL_SERVER_NAME:-}" && "${MEMPOOL_SERVER_NAME}" != "_" ]] && echo "  • Hostname:    http://${MEMPOOL_SERVER_NAME}:${MEMPOOL_PUBLIC_PORT}/"
echo "  • Backend:     http://127.0.0.1:${MEMPOOL_BACKEND_PORT}/"
echo "  • Nginx conf:  ${NGINX_PATH}"
echo "  • Tor HS dir:  ${HS_DIR}"
if [[ -n "${MEMPOOL_ONION}" ]]; then
  echo "  • Onion URL:   http://${MEMPOOL_ONION}/   (anche :${MEMPOOL_PUBLIC_PORT}/)"
else
  echo "  • Onion URL:   pending… (Tor sta creando il servizio; controlla ${HS_DIR}/hostname fra poco)"
fi

echo
echo "Premi un tasto per tornare al menu..."
read -n 1 -s

