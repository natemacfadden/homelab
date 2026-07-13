# homelab

Install scripts for a five-node Ray cluster: one head node and four workers,
with Prometheus, Tailscale, and optional Grafana/Docker on workers. You install
the OS yourself; the two scripts handle everything after that. Both are
idempotent, so re-running them is safe.

Architecture and machine roles: [docs/PLAN.md](docs/PLAN.md).

```
scripts/setup_head.sh     Ray head + Prometheus + cron
scripts/setup_worker.sh   Ray worker + node_exporter (+ optional Docker/Grafana)
scripts/common.sh         shared helpers sourced by both
scripts/healthcheck.sh    verify a node's services are up
scripts/rename.sh         rename a machine (hostname + Tailscale) and restart Ray
```

## Head node

Run on the always-on box. It also configures the machine to stay on with the lid
closed.

```bash
bash scripts/setup_head.sh
```

When it finishes it prints the address to use as HEAD_IP on the workers (the
head's Tailscale IP if Tailscale is up, otherwise its LAN IP) and saves the same
info to ~/ip.txt.

## Worker nodes

Run on each other box. Two environment variables are passed on the command line:

- HEAD_IP: the head node's IP or Tailscale name.
- RESOURCES: the Ray tag this box advertises, so matching tasks land here.

```bash
# ws1: CUDA GPU; also runs the trawler (Docker) and dashboards (Grafana)
HEAD_IP=192.168.1.50 RESOURCES='{"cuda": 1}' INSTALL_DOCKER=1 INSTALL_GRAFANA=1 bash scripts/setup_worker.sh

# big box: 128 GB unified memory
HEAD_IP=192.168.1.50 RESOURCES='{"big_memory": 1}' bash scripts/setup_worker.sh

# ws2: small / intermittent tasks
HEAD_IP=192.168.1.50 RESOURCES='{"small_task": 1}' bash scripts/setup_worker.sh
```

Optional flags, both off by default: INSTALL_DOCKER=1 on workers that run
containerized tasks; INSTALL_GRAFANA=1 on one box only.

The MacBook has no systemd, so it isn't scripted. Join it by hand:

```bash
brew install python tmux
python3 -m venv ~/raylab/venv
~/raylab/venv/bin/pip install "ray[default]==2.48.0"
~/raylab/venv/bin/ray start --address=<head-ip>:6379 --resources='{"mac": 1}'
```

## Deploy to the headless head node

```bash
rsync -av --exclude .git ./ user@head-ip:~/homelab/
ssh user@head-ip 'cd ~/homelab && bash scripts/setup_head.sh'
```

## Config and restarts

- Prometheus scrape targets live in the NODE_TARGETS array at the top of
  setup_head.sh. Edit it and re-run the script to apply.
- Pinned versions (Ray, Prometheus, node_exporter) live at the top of each
  script. Keep the Ray version the same on the head and all workers.
- Every node must run the same Python minor version (Ray enforces this). The
  scripts build the venv from /usr/bin/python3 so an active conda/pyenv env can't
  slip in a different Python; override with PYTHON=/path/to/python3 if a box needs
  it. A re-run rebuilds a venv that was built from the wrong Python.
- Re-running either script applies changes and restarts the affected services.

```bash
sudo systemctl restart ray-head prometheus       # head
sudo systemctl restart ray-worker node_exporter   # worker
```

Then, once per box: sudo tailscale up.

## Renaming a machine

Run on the box you're renaming; it sets the OS hostname, the Tailscale/MagicDNS
name, and restarts Ray:

```bash
bash scripts/rename.sh head01
```

It only renames that machine. Afterwards, update references to the old name:
any worker's HEAD_IP, and NODE_TARGETS in setup_head.sh (then re-run it).

## Health check

Each setup script runs this automatically at the end to confirm the install. You
can also run it any time on a node:

```bash
bash scripts/healthcheck.sh
```

It auto-detects head vs worker, checks the systemd services, the dashboard/
Prometheus ports, and `ray status`, and exits non-zero if anything is down, so you
can wire it into cron or CI.

## URLs

- Ray dashboard: http://<head-ip>:8265
- Prometheus: http://<head-ip>:9090
- Grafana (ws1): http://<ws1-ip>:3000, add Prometheus source http://<head-ip>:9090
