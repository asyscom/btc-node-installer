#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

# Porta pubblica (esterna) - default 4080 se non settata in env
MEMPOOL_PUBLIC_PORT="${MEMPOOL_PUBLIC_PORT:-4080}"

if has_state mempool.installed; then ok "Mempool already installed"; exit 0; fi

detect_pkg_mgr; pkg_update

# Dipendenze
case "$pkg_mgr" in
  apt)
    pkg_install git mariadb-server redis-server curl ca-certificates nginx
    ;;
  dnf|yum)
    pkg_install git mariadb-server redis curl ca-certificates nginx
    ;;
esac

# Servizi DB/Redis/Nginx
systemctl enable --now mariadb || true
systemctl enable --now redis || systemctl enable --now redis-server || true
systemctl enable --now nginx || true

# DB setup (semplice)
DB_PASS="$(openssl rand -hex 16)"
mysql -uroot -e "CREATE DATABASE IF NOT EXISTS mempool CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -uroot -e "CREATE USER IF NOT EXISTS 'mempool'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -uroot -e "GRANT ALL PRIVILEGES ON mempool.* TO 'mempool'@'localhost'; FLUSH PRIVILEGES;"
ok "Created DB 'mempool' and user 'mempool' (random password)."

# Node.js LTS
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

# utente e percorsi
ensure_user mempool
mkdir -p /opt/mempool /etc/mempool
chown -R mempool:mempool /opt/mempool /etc/mempool

# codice sorgente (repo root in /opt/mempool/mempool) - eseguito come utente mempool
( cd / && {
    if [[ ! -d /opt/mempool/mempool/.git ]]; then
      rm -rf /opt/mempool/mempool 2>/dev/null || true
      sudo -u mempool -H git clone https://github.com/mempool/mempool.git /opt/mempool/mempool
    fi
    sudo -u mempool -H git -C /opt/mempool/mempool submodule update --init --recursive
    sudo -u mempool -H git config --global --add safe.directory /opt/mempool/mempool || true
})

# Config backend (API bind su loopback)
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
    "HOST": "127.0.0.1",
    "PORT": 50001,
    "TLS": false
  },
  "CORE_RPC": {
    "HOST": "127.0.0.1",
    "PORT": ${BITCOIN_RPC_PORT},
    "USERNAME": "${BITCOIN_RPC_USER}",
    "PASSWORD": "${BITCOIN_RPC_PASSWORD}"
  },
  "ZMQ": {
    "RAW_BLOCK": "tcp://127.0.0.1:${ZMQ_RAWBLOCK}",
    "RAW_TX": "tcp://127.0.0.1:${ZMQ_RAWTX}"
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

# ---------- INSTALL & BUILD DIRETTO NEI WORKSPACE ----------
# Backend
( cd / && sudo -u mempool -H bash -lc '
  set -Eeuo pipefail
  cd /opt/mempool/mempool/backend
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  npm run build
  npm run migration:run 2>/dev/null || npx typeorm migration:run || true
' )

# Frontend (se presente)
( cd / && sudo -u mempool -H bash -lc '
  set -Eeuo pipefail
  if [[ -f /opt/mempool/mempool/frontend/package.json ]]; then
    cd /opt/mempool/mempool/frontend
    if [[ -f package-lock.json ]]; then
      npm ci
    else
      npm install
    fi
    npm run build || true
  fi
' )

# systemd (punta direttamente a backend)
cat > /etc/systemd/system/mempool-backend.service <<'SERVICE'
[Unit]
Description=Mempool Backend (API + static)
After=network.target mariadb.service redis.service bitcoind.service
Requires=mariadb.service redis.service bitcoind.service

[Service]
User=mempool
Group=mempool
WorkingDirectory=/opt/mempool/mempool/backend
Environment=MEMPOOL_CONFIG=/etc/mempool/mempool-config.json
ExecStart=/bin/bash -lc '(npm run start:backend || npm run start || node dist/index.js)'
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
SERVICE

enable_start mempool-backend.service

# ---------------- NGINX reverse proxy (:${MEMPOOL_PUBLIC_PORT} -> backend) ----------------
SERVER_NAME="${MEMPOOL_SERVER_NAME:-_}"   # opzionale: export MEMPOOL_SERVER_NAME="mempool.yourdomain.tld"

NGINX_DEBIAN_SITE="/etc/nginx/sites-available/mempool.conf"
NGINX_DEBIAN_LINK="/etc/nginx/sites-enabled/mempool.conf"
NGINX_RHEL_SITE="/etc/nginx/conf.d/mempool.conf"

NGINX_CONF_CONTENT=$(cat <<NGX
# Mempool reverse proxy
server {
    listen ${MEMPOOL_PUBLIC_PORT};
    server_name ${SERVER_NAME};

    # gzip on; # abilitalo se vuoi comprimere il traffico

    location / {
        proxy_pass http://127.0.0.1:${MEMPOOL_BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
    }

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

# SELinux (proxy da nginx a 127.0.0.1:${MEMPOOL_BACKEND_PORT})
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  command -v setsebool >/dev/null 2>&1 && setsebool -P httpd_can_network_connect 1 || true
fi

nginx -t
systemctl reload nginx

# ---------------------- FIREWALL apertura porta pubblica ----------------------
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

# ---------------- Tor Hidden Service per Mempool (porta pubblica) ----------------
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

# ---------------------- SUMMARY ----------------------
echo
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
NGINX_PATH="$( [[ $pkg_mgr == apt ]] && echo ${NGINX_DEBIAN_SITE} || echo ${NGINX_RHEL_SITE} )"

ok "Summary:"
echo "  • DB user: mempool  | DB name: mempool  | Pass: ${DB_PASS}"
echo "  • Public URL:  http://${SERVER_IP}:${MEMPOOL_PUBLIC_PORT}/"
[[ -n "${MEMPOOL_SERVER_NAME:-}" && "${MEMPOOL_SERVER_NAME}" != "_" ]] && echo "  • Hostname:    http://${MEMPOOL_SERVER_NAME}:${MEMPOOL_PUBLIC_PORT}/"
echo "  • Backend:     http://127.0.0.1:${MEMPOOL_BACKEND_PORT}/"
echo "  • Nginx conf:  ${NGINX_PATH}"
echo "  • Tor HS dir:  ${HS_DIR}"
if [[ -n "${MEMPOOL_ONION}" ]]; then
  echo "  • Onion URL:   http://${MEMPOOL_ONION}/   (and http://${MEMPOOL_ONION}:${MEMPOOL_PUBLIC_PORT}/)"
else
  echo "  • Onion URL:   pending… (Tor is creating it; check ${HS_DIR}/hostname shortly)"
fi

