Perfetto 👍 capito: per adesso ti preparo **solo un nuovo `README.md` unico** da scaricare, con dentro:

* Descrizione completa dello stack (Bitcoin, LND, Electrs, ThunderHub, Mempool, Tor/I2P/DNS-over-Tor come prerequisiti).
* Specifica che **siamo in beta test**.
* Spiegazione di come funziona `/data/*` per i dati e `/usr/local/bin` per i binari.
* Dettagli su **pruned/full node**, alias `bcli`/`btclog`.
* Indicazione dei comandi base per avvio/verifica.
* Link donazioni (Lightning Address + on-chain).

---

### Ecco il file `README.md` pronto da scaricare

````markdown
# BTC Node Installer (Beta)

⚠️ **This project is currently in beta testing.**  
Expect breaking changes and incomplete features. Use at your own risk.

---

## Overview

This repository provides a **modular installer** for a self-hosted Bitcoin node and its ecosystem:

- **Bitcoin Core** (full or pruned node)
- **LND** (Lightning Network Daemon)
- **Electrs** (Electrum server)
- **ThunderHub** (Lightning web dashboard)
- **Mempool.space** (block explorer & mempool visualizer)
- **Monitoring stack** (Prometheus + Grafana planned)
- **Privacy tools** (Tor, I2P, DNS-over-Tor)

---

## Installation

Clone the repository:

```bash
git clone https://github.com/asyscom/btc-node-installer.git
cd btc-node-installer
````

Run the interactive menu:

```bash
sudo ./menu.sh
```

Each component can be installed separately.
Bitcoin Core, LND and Electrs require significant sync time, so they are handled in **dedicated scripts**.

---

## Data & Binaries

* **Binaries**: installed into `/usr/local/bin`
* **Configuration**: under `/etc/<service>/`
* **Data directories**: stored under `/data/` (can be customized in `.env`)

Example defaults:

* Bitcoin: `/data/bitcoin`
* LND: `/data/lnd`
* Electrs: `/data/electrs`
* Mempool: `/data/mempool`

---

## Bitcoin Core

### Modes

* **Pruned node**

  * Keeps only the last *N GB* of blocks
  * `txindex=0` enforced
  * ⚠️ Electrs & Mempool cannot index full history

* **Full node**

  * Keeps entire blockchain
  * `txindex=1` enabled (required by Electrs & Mempool)

### Service

* Service: `bitcoind.service`
* Config: `/etc/bitcoin/bitcoin.conf`
* Data: `/data/bitcoin`

### Operator shortcuts

After installation and re-login, two global aliases are available:

```bash
# Blockchain info
bcli getblockchaininfo

# Follow debug log
btclog
```

These wrap:

```bash
sudo -u bitcoin bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/data/bitcoin ...
sudo -u bitcoin tail -f /data/bitcoin/debug.log
```

---

## Other Components

* **LND**
  Installed as `lnd.service`, data in `/data/lnd`.
  Manages Lightning channels and wallets.

* **Electrs**
  Installed as `electrs.service`, data in `/data/electrs`.
  Requires full node (`txindex=1`).

* **ThunderHub**
  Web interface for managing LND.

* **Mempool**
  Installed as `mempool.service`, data in `/data/mempool`.
  Requires full node.

* **Privacy (Tor/I2P/DNS-over-Tor)**
  Installer offers optional setup for enhanced privacy.

---

## Status

This project is **beta quality**:

* Expect bugs and incomplete automation.
* Only experienced Linux users should test at this stage.
* Contributions are welcome.

---

## Donations

If you find this project useful, you can support development:

* ⚡ Lightning: `davidebtc@lnbits.davidebtc.me`
* ₿ On-chain: `bc1qu8wqn73c6wa7gw2ks6m3rscgntscpu3czvz0h8`

```

---


