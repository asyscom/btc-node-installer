# Modular BTC Node Installer

Interactive modular installer for **Bitcoin Core**, **LND**, **Electrs**, **ThunderHub**, **Monitoring**, and **Mempool**.

> **Note:** there is also an **automatic script** ready to use on GitHub.  
> Repository: **(replace with your repo URL, e.g., https://github.com/asyscom/btc-node-installer)**

## Structure
```
lib/common.sh
scripts/00-prereqs.sh
scripts/10-bitcoin-core.sh
scripts/20-lnd.sh
scripts/30-electrs.sh
scripts/40-thunderhub.sh
scripts/50-monitoring.sh
scripts/60-mempool.sh
menu.sh
.env.example
systemd/*.service
docs/guide.md
```
Each module is **idempotent** and safe to re-run. State flags live in `/var/lib/btc-node-installer/state/`.

## Quick Start
```bash
git clone https://github.com/asyscom/btc-node-installer
cd btc-node-installer
cp .env.example .env   # optional, tweak versions/ports
sudo ./menu.sh         # interactive menu
# or run individual modules:
sudo ./scripts/10-bitcoin-core.sh
```

## Requirements
- Linux with systemd, sudo privileges
- Ports: 8333 (BTC), 9735 (LND), 3000 (ThunderHub), 4080 (Mempool backend) + optional 80/443 (Nginx)
- Sufficient disk for IBD (>= 1 TB recommended, SSD/NVMe)

### Pruned mode
During Bitcoin Core installation you will be asked whether to enable **pruned mode** and how many **GB** to allocate. If pruning is enabled, `txindex` will be disabled automatically and some features (Electrs/Mempool full history) may be limited.

## License
MIT
