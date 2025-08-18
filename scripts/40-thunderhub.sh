#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state thunderhub.installed; then ok "ThunderHub already installed"; exit 0; fi

detect_pkg_mgr; pkg_update
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

# user
ensure_user thunderhub
mkdir -p /opt/thunderhub /etc/thunderhub
chown -R thunderhub:thunderhub /opt/thunderhub /etc/thunderhub

cd /opt/thunderhub
if [[ ! -d app ]]; then
  git clone https://github.com/apotdevin/thunderhub.git app
fi
cd app
if [[ -n "${THUNDERHUB_VERSION:-}" && "${THUNDERHUB_VERSION}" != "latest" ]]; then
  git fetch --tags
  git checkout "${THUNDERHUB_VERSION}" || true
fi
npm install
npm run build

# minimal config
cat > /etc/thunderhub/thunderhub.env <<CONF
PORT=${THUNDERHUB_PORT}
ACCOUNT_CONFIG_PATH=/etc/thunderhub/thub.config.yaml
LOG_LEVEL=info
CONF

cat > /etc/thunderhub/thub.config.yaml <<CONF
masterPassword: change-me
accounts:
  - name: local-lnd
    serverUrl: 127.0.0.1:10009
    macaroonPath: /var/lib/lnd/data/chain/bitcoin/${NETWORK}/admin.macaroon
    certificatePath: /var/lib/lnd/tls.cert
CONF
chown -R thunderhub:thunderhub /etc/thunderhub

# systemd
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

enable_start thunderhub.service
ok "ThunderHub started on port ${THUNDERHUB_PORT}. Remember to change masterPassword."
set_state thunderhub.installed
