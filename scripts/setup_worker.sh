#!/usr/bin/env bash
#
# setup_worker.sh - home lab WORKER NODE (Debian/Ubuntu).
# Installs a Ray worker that joins the head, plus node_exporter; optionally
# rootless Docker and Grafana. Layered memory limits: Ray kills greedy tasks at
# 80%, and a systemd cgroup cap (95%) is the kernel backstop.
#
# Usage (HEAD_IP required; RESOURCES is this box's Ray tag):
#   HEAD_IP=192.168.1.50 RESOURCES='{"cuda": 1}' bash scripts/setup_worker.sh
#   ... add INSTALL_DOCKER=1 and/or INSTALL_GRAFANA=1 (Grafana on ONE box only)
# Idempotent: safe to re-run.
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./common.sh

: "${HEAD_IP:?Set HEAD_IP=<head node address>}"
RESOURCES="${RESOURCES:-{}}"   # default: no special tags (generic worker)
RAY_PORT=6379                  # must match the head node's port
NODE_EXPORTER_VERSION="1.9.1"

preflight

echo "== [1/4] Base packages + Ray =="
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip curl git tmux uidmap
setup_venv

echo "== [2/4] Ray worker service (layered memory limits) =="
write_service ray-worker <<EOF
[Unit]
Description=Ray worker (joins $HEAD_IP)
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
User=$USER
ExecStart=$LAB_DIR/venv/bin/ray start --address=$HEAD_IP:$RAY_PORT --resources='$RESOURCES' --metrics-export-port=8080
ExecStop=$LAB_DIR/venv/bin/ray stop
Restart=on-failure
Environment=RAY_memory_usage_threshold=0.80   # graceful, retryable task kills
MemoryMax=95%                                  # kernel cgroup hard wall
[Install]
WantedBy=multi-user.target
EOF

echo "== [3/4] node_exporter =="
if ! /usr/local/bin/node_exporter --version 2>/dev/null | grep -q "$NODE_EXPORTER_VERSION"; then
  curl -fL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
    | sudo tar xz -C /usr/local/bin --strip-components=1 --wildcards '*/node_exporter'
fi
write_service node_exporter <<EOF
[Unit]
Description=Prometheus node_exporter
[Service]
User=$USER
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

echo "== [4/4] Tailscale =="
install_tailscale

if [[ "${INSTALL_DOCKER:-0}" == "1" ]]; then
  echo "== Optional: rootless Docker =="
  command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
  dockerd-rootless-setuptool.sh install
fi

if [[ "${INSTALL_GRAFANA:-0}" == "1" ]]; then
  echo "== Optional: Grafana (this box serves the dashboards) =="
  sudo apt-get install -y apt-transport-https software-properties-common
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | sudo tee /etc/apt/keyrings/grafana.asc >/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
    | sudo tee /etc/apt/sources.list.d/grafana.list
  sudo apt-get update && sudo apt-get install -y grafana
  sudo systemctl enable --now grafana-server
  echo ">> Grafana http://<this-ip>:3000 - add Prometheus source http://$HEAD_IP:9090"
fi

echo
echo "DONE. The head dashboard http://$HEAD_IP:8265 should now list this node."
echo
run_healthcheck
