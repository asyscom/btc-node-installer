# Full Bitcoin Node Stack Installer (Beta)

> **Status:** Beta – expect rough edges and breaking changes. Use at your own risk.

This repository provides a **modular, menu-driven installer** for a self-hosted Bitcoin stack:

- **Bitcoin Core** (full or pruned)
- **LND** (Lightning Network Daemon)
- **Electrs** (Electrum server)
- **ThunderHub** (LND web UI)
- **Mempool** (block explorer)
- **Privacy** (Tor; I2P & DNS-over-Tor planned)
- **Monitoring** (Prometheus + Grafana planned)

Everything is configured under `/etc/<service>/` and stores data under `/data/<service>` by default.

---

## 1) Requirements

- Debian/Ubuntu-like system with `sudo`
- A non-root user with sudo privileges
- Network access (Tor optional)
- At least:
  - Pruned node: ~15–20 GB free space
  - Full node + Electrs/Mempool: > 900 GB

---

## 2) Install

```bash
git clone https://github.com/asyscom/btc-node-installer.git
cd btc-node-installer
```

Copy the environment template and adjust it:

```bash
cp .env.example .env
nano .env
```

### What to configure in `.env`

You can pin versions and tweak ports/paths here. Common keys:

- **Bitcoin Core**
  - `BITCOIN_VERSION`, `BITCOIN_DATA_DIR=/data/bitcoin`
  - `BITCOIN_PRUNE=0` (full) or e.g. `BITCOIN_PRUNE=9000` (MB)
  - `BITCOIN_RPC_USER`, `BITCOIN_RPC_PASSWORD`, `BITCOIN_RPC_PORT=8332`
  - `ZMQ_RAWBLOCK=28332`, `ZMQ_RAWTX=28333`

- **LND**
  - `LND_VERSION` (e.g. `v0.19.2-beta`)
  - `LND_DATA_DIR=/data/lnd`
  - `NETWORK=mainnet|testnet|signet|regtest`

- **Electrs / Mempool / ThunderHub / Tor**
  - Data dirs and ports as needed (see defaults below)

> **Tip:** The menu scripts read `.env` at runtime, so you can change versions and rerun.

---

## 3) Run the menu

```bash
sudo ./menu.sh
```

Use the menu to install components **in sequence**. A typical order:

1. **Prerequisites**
2. **Bitcoin Core** (choose *pruned* or *full*)
3. **LND**
4. (Optional) **Electrs**, **ThunderHub**, **Mempool**
5. **Privacy (Tor)**

You can install each part independently; the menu remembers progress.

---

## 4) Where things live (paths)

| Component     | Service                  | Config path                    | Data dir            | Binaries                 |
|---------------|---------------------------|--------------------------------|---------------------|--------------------------|
| Bitcoin Core  | `bitcoind.service`        | `/etc/bitcoin/bitcoin.conf`    | `/data/bitcoin`     | `/usr/local/bin/bitcoin*`|
| LND           | `lnd.service`             | `/etc/lnd/lnd.conf`            | `/data/lnd`         | `/usr/local/bin/lnd, lncli` |
| Electrs       | `electrs.service`         | `/etc/electrs/config.toml`     | `/data/electrs`     | `/usr/local/bin/electrs` |
| ThunderHub    | `thunderhub.service`      | `/etc/thunderhub/config.yaml`  | `/data/thunderhub`  | (via Node/npm)           |
| Mempool       | `mempool.service`         | `/etc/mempool/*.conf`          | `/data/mempool`     | (docker/compiled)        |
| Tor           | `tor.service`             | `/etc/tor/torrc`               | `/var/lib/tor`      | `/usr/sbin/tor`          |

---

## 5) Customizing configs

### Bitcoin Core

`/etc/bitcoin/bitcoin.conf`

- **Pruned node**:
  ```ini
  prune=9000
  txindex=0
  ```
- **Full node**:
  ```ini
  prune=0
  txindex=1
  ```

Restart:
```bash
sudo systemctl restart bitcoind
```

### LND

`/etc/lnd/lnd.conf`

```ini
[Application Options]
lnddir=/data/lnd
alias=YourFancyAlias⚡
color=#3399ff
rpclisten=127.0.0.1:10009
restlisten=127.0.0.1:8080
listen=0.0.0.0:9735
debuglevel=info
```

**Auto-unlock (optional):**  
Password saved in `/data/lnd/password.txt` and added to systemd unit.

Restart:
```bash
sudo systemctl restart lnd
```

---

## 6) Service management

```bash
# Start / Stop / Restart
sudo systemctl restart bitcoind
sudo systemctl restart lnd

# Logs
journalctl -fu bitcoind
journalctl -fu lnd
```

**Bitcoin shortcuts:**

```bash
bcli getblockchaininfo
btclog
```

---

## 7) Reset / Reinstall

```bash
sudo systemctl stop lnd
sudo rm -rf /data/lnd /etc/lnd
sudo userdel -r lnd 2>/dev/null || true
sudo rm -f /etc/systemd/system/lnd.service
sudo systemctl daemon-reload
```

---

## 8) Donations

- ⚡ Lightning: `davidebtc@lnbits.davidebtc.me`
- ₿ On-chain: `bc1qu8wqn73c6wa7gw2ks6m3rscgntscpu3czvz0h8`
