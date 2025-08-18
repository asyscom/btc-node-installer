#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
require_root; load_env; ensure_state_dir; detect_pkg_mgr

if has_state monitoring.installed; then ok "Monitoring already installed"; exit 0; fi

detect_pkg_mgr; pkg_update
pkg_install prometheus prometheus-node-exporter grafana

systemctl enable --now node-exporter || systemctl enable --now prometheus-node-exporter || true
systemctl enable --now prometheus || true
systemctl enable --now grafana-server || true

ok "Prometheus: :9090 | Node Exporter: :9100 | Grafana: :3000 (admin/admin)"
set_state monitoring.installed
