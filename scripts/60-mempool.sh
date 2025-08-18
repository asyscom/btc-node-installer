#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state mempool.installed; then ok "Mempool already installed"; exit 0; fi

detect_pkg_mgr; pkg_update
pkg_install git mariadb-server

systemctl enable --now mariadb || true

# DB setup (simple)
DB_PASS=$(openssl rand -hex 16)
mysql -uroot -e "CREATE DATABASE IF NOT EXISTS mempool CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -uroot -e "CREATE USER IF NOT EXISTS 'mempool'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -uroot -e "GRANT ALL PRIVILEGES ON mempool.* TO 'mempool'@'localhost'; FLUSH PRIVILEGES;"
ok "Created DB 'mempool' user 'mempool' with generated password."

# Node.js LTS
if ! command -v node >/dev/null 2>&1; then
  case "$pkg_mgr" in
    apt)
      curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
      apt install -y nodejs
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
  esac
fi

# backend
ensure_user mempool
mkdir -p /opt/mempool /etc/mempool
chown -R mempool:mempool /opt/mempool /etc/mempool

cd /opt/mempool
if [[ ! -d backend ]]; then
  git clone https://github.com/mempool/mempool.git backend
fi
cd backend
git submodule update --init --recursive

# Config
cat > /etc/mempool/mempool-config.json <<CONF
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
    "PORT": ${MEMPOOL_BACKEND_PORT}
  }
}
CONF
chown -R mempool:mempool /etc/mempool

npm ci --workspace=backend
npm run build --workspace=backend

# systemd for backend
cat > /etc/systemd/system/mempool-backend.service <<SERVICE
[Unit]
Description=Mempool Backend
After=network.target mariadb.service bitcoind.service
Requires=bitcoind.service mariadb.service

[Service]
User=mempool
Group=mempool
WorkingDirectory=/opt/mempool/backend
Environment=MEMPOOL_CONFIG=/etc/mempool/mempool-config.json
ExecStart=/usr/bin/npm run start:backend
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

enable_start mempool-backend.service

ok "Mempool backend started on port ${MEMPOOL_BACKEND_PORT}. Frontend is served by the backend (API + static files)."
set_state mempool.installed
