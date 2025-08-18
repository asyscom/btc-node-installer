#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state electrs.installed; then ok "Electrs already installed"; exit 0; fi

detect_pkg_mgr; pkg_update
pkg_install build-essential clang cmake git rustc cargo pkg-config librocksdb-dev libssl-dev

# user and dirs
ensure_user electrs
mkdir -p /var/lib/electrs /etc/electrs
chown -R electrs:electrs /var/lib/electrs /etc/electrs

# build
cd /opt
if [[ ! -d electrs ]]; then
  git clone https://github.com/romanz/electrs.git
fi
cd electrs
if [[ -n "${ELECTRS_VERSION:-}" && "${ELECTRS_VERSION}" != "latest" ]]; then
  git fetch --tags
  git checkout "${ELECTRS_VERSION}" || true
fi
cargo build --release

install -m 0755 target/release/electrs /usr/local/bin/

# systemd
cat > /etc/systemd/system/electrs.service <<SERVICE
[Unit]
Description=Electrs
After=bitcoind.service network.target
Requires=bitcoind.service

[Service]
User=electrs
Group=electrs
ExecStart=/usr/local/bin/electrs -v \
  --network=${NETWORK} \
  --db-dir=/var/lib/electrs/db \
  --daemon-dir=/var/lib/bitcoind \
  --electrum-rpc-addr=0.0.0.0:50001 \
  --cookie-file=/var/lib/bitcoind/.cookie \
  --monitoring-addr=127.0.0.1:4224
Restart=on-failure
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
SERVICE

# cookie permissions
ln -sf /var/lib/bitcoind/.cookie /var/lib/electrs/.cookie || true
chown -h electrs:electrs /var/lib/electrs/.cookie || true

enable_start electrs.service
ok "Electrs started. Indexing in progress (can take many hours)."
set_state electrs.installed
