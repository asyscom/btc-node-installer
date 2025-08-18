# Text Guide — Modular Bitcoin Node Installation

> **Automatic script** available on GitHub: **(insert the repo URL here, e.g., https://github.com/asyscom/btc-node-installer)**

This guide walks you through installing a complete Bitcoin node with optional components,
using a suite of **modular and idempotent** scripts. You can run modules individually,
so long-running sync/indexing (Bitcoin Core, Electrs) won't block the whole process.

## Step 1 — Prepare
1. Clone the repository and (optionally) copy `.env.example` to `.env` to customize versions/ports:
   ```bash
   git clone https://github.com/asyscom/btc-node-installer
   cd btc-node-installer
   cp .env.example .env
   ```

2. Start the **interactive menu**:
   ```bash
   sudo ./menu.sh
   ```
   Or run individual modules (e.g., Bitcoin Core):
   ```bash
   sudo ./scripts/10-bitcoin-core.sh
   ```

## Step 2 — Recommended Order
1. `00-prereqs.sh`
2. `10-bitcoin-core.sh` → start Bitcoin Core sync (or pruned mode)
3. When you want: `20-lnd.sh`, `30-electrs.sh`
4. `40-thunderhub.sh`, `50-monitoring.sh`
5. `60-mempool.sh` once `bitcoind` is running with ZMQ/RPC ready

Each module displays useful commands to check status (e.g., `bitcoin-cli getblockchaininfo`).

## Privacy & Sync Notes
- Tor/I2P provide stronger privacy but slower IBD.
- A “fast sync” toggle can temporarily avoid `onlynet` during IBD, then re-enable it later (you can adapt this in your config).

## Common Issues
- **Slow disk** → prefer SSD/NVMe.
- **Closed ports** → configure UFW/router based on `.env` settings.

### Pruned mode
During Bitcoin Core installation you will be asked whether to enable **pruned mode** and how many **GB** to allocate. If pruning is enabled, `txindex` will be disabled automatically and some features (Electrs/Mempool full history) may be limited.
