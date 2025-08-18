#!/usr/bin/env bash
set -Eeuo pipefail

# === colors ===
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; NC="\033[0m"

# === utilities ===
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script requires root (sudo).${NC}"
    exit 1
  fi
}

log() { echo -e "${BLUE}[i]${NC} $*"; }
ok()  { echo -e "${GREEN}[ok]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){ echo -e "${RED}[x]${NC} $*"; }

error_exit() {
  err "$1"
  exit 1
}

confirm() {
  local msg="${1:-Proceed?}"
  read -r -p "$msg [y/N]: " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# load .env if present
load_env() {
  if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi
  # defaults
  : "${NETWORK:=mainnet}"
  : "${BITCOIN_RPC_PORT:=8332}"
  : "${BITCOIN_P2P_PORT:=8333}"
  : "${ZMQ_RAWBLOCK:=28332}"
  : "${ZMQ_RAWTX:=28333}"
  : "${BITCOIN_RPC_USER:=btcuser}"
  : "${BITCOIN_RPC_PASSWORD:=change-me}"
  : "${THUNDERHUB_PORT:=3000}"
  : "${MEMPOOL_BACKEND_PORT:=4080}"
  : "${USE_NGINX:=false}"
}

# state/idempotency
STATE_DIR="/var/lib/btc-node-installer/state"
ensure_state_dir() { mkdir -p "$STATE_DIR"; }
has_state() { [[ -f "$STATE_DIR/$1" ]]; }
set_state() { touch "$STATE_DIR/$1"; }

# package manager detection
pkg_mgr=""
detect_pkg_mgr() {
  if command -v apt >/dev/null 2>&1; then pkg_mgr=apt
  elif command -v dnf >/dev/null 2>&1; then pkg_mgr=dnf
  elif command -v yum >/dev/null 2>&1; then pkg_mgr=yum
  else error_exit "No supported package manager found (apt/dnf/yum)."; fi
}

pkg_update() {
  case "$pkg_mgr" in
    apt) apt update -y ;;
    dnf) dnf makecache -y ;;
    yum) yum makecache -y ;;
  esac
}

pkg_install() {
  case "$pkg_mgr" in
    apt) DEBIAN_FRONTEND=noninteractive apt install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
  esac
}

# create service user if missing
ensure_user() {
  local user="$1"
  if ! id -u "$user" >/dev/null 2>&1; then
    useradd -r -m -s /usr/sbin/nologin "$user"
    ok "Created service user: $user"
  fi
}

# write file only if content changed
write_if_changed() {
  local path="$1"; shift
  local content="$*"
  if [[ -f "$path" ]] && diff -q <(printf "%s" "$content") "$path" >/dev/null; then
    log "No changes for $path"
  else
    printf "%s" "$content" > "$path"
    ok "Updated $path"
  fi
}

# enable and start systemd unit
enable_start() {
  systemctl daemon-reload
  systemctl enable --now "$1"
  systemctl is-active --quiet "$1" && ok "Service $1 is active" || error_exit "$1 is not active"
}

# open UFW port if present
ufw_allow() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$1" || true
    ok "UFW: opened port $1"
  fi
}

# show step title then run
run_step() {
  local desc="$1"; shift
  echo -e "${YELLOW}==> $desc${NC}"
  "$@"
}
