#!/usr/bin/env bash
#
# setup_worker.sh - Home lab WORKER NODE (Debian/Ubuntu Linux boxes)
#
# Usage:
#   HEAD_IP=192.168.1.50 RESOURCES='{"cuda": 1}'        bash setup_worker.sh   # ws1
#   HEAD_IP=192.168.1.50 RESOURCES='{"big_memory": 1}'  bash setup_worker.sh   # big box
#   HEAD_IP=192.168.1.50 RESOURCES='{"small_task": 1}'  bash setup_worker.sh   # ws2
#
# Optional:  INSTALL_DOCKER=1  INSTALL_GRAFANA=1  (Grafana on ONE box only, e.g. ws1)
#
# Installs: Python venv + Ray (worker, joins head), node_exporter, Tailscale,
#           tmux; optionally rootless Docker and Grafana.
# Memory protection is layered here: Ray's monitor kills greedy tasks at 80%,
# and a systemd cgroup cap (MemoryMax=95%) is the kernel-enforced backstop.
# Safe to re-run: every step is idempotent.
#
# For the MacBook (no Docker, no systemd): brew install python tmux; then
#   python3 -m venv ~/raylab/venv && pip install "ray[default]==<PIN>"
#   ray start --address=$HEAD_IP:6379 --resources='{"mac": 1}'
#
set -euo pipefail

# ----- config (set these on the command line, see Usage above) ---------------
# HEAD_IP   : IP or Tailscale name of the head node - where this worker joins.
# RESOURCES : Ray custom resource tag this box advertises, e.g. '{"cuda": 1}'.
#             Tasks requesting that tag get scheduled here. One tag per role.
: "${HEAD_IP:?Set HEAD_IP=<head node address>}"
RESOURCES="${RESOURCES:-{}}"   # default: no special tags (generic worker)
RAY_VERSION="2.48.0"           # keep identical to the head node's pin
RAY_PORT=6379                  # must match the head node's port
NODE_EXPORTER_VERSION="1.9.1"
LAB_DIR="$HOME/raylab"

# ----- preflight -------------------------------------------------------------
if [[ ${EUID} -eq 0 ]]; then
  echo "Run as your normal user (with sudo rights), not root." >&2
  exit 1
fi
sudo -v || { echo "This script needs sudo." >&2; exit 1; }

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

echo "== [1/5] Base packages =="
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip curl git tmux uidmap

echo "== [2/5] Python venv + Ray =="
mkdir -p "$LAB_DIR"
[[ -x "$LAB_DIR/venv/bin/python" ]] || python3 -m venv "$LAB_DIR/venv"
# shellcheck disable=SC1091
source "$LAB_DIR/venv/bin/activate"
pip install --upgrade pip
pip install "ray[default]==$RAY_VERSION"
deactivate

echo "== [3/5] Ray worker service (with layered memory limits) =="
sudo tee /etc/systemd/system/ray-worker.service >/dev/null <<EOF
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
# Layer 1 - Ray's graceful, retryable task killing at 80% node memory:
Environment=RAY_memory_usage_threshold=0.80
# Layer 2 - kernel cgroup hard wall; OOM-kills the service before the box dies:
MemoryMax=95%

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable ray-worker
sudo systemctl restart ray-worker   # restart so re-runs pick up unit edits

echo "== [4/5] node_exporter (feeds Prometheus on the head) =="
if ! /usr/local/bin/node_exporter --version 2>/dev/null | grep -q "$NODE_EXPORTER_VERSION"; then
  curl -fL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
    | sudo tar xz -C /usr/local/bin --strip-components=1 --wildcards '*/node_exporter'
fi
sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<EOF
[Unit]
Description=Prometheus node_exporter
[Service]
User=$USER
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl restart node_exporter

echo "== [5/5] Tailscale =="
command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
echo ">> Run 'sudo tailscale up' once, manually, to authenticate."

if [[ "${INSTALL_DOCKER:-0}" == "1" ]]; then
  echo "== Optional: rootless Docker =="
  command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
  dockerd-rootless-setuptool.sh install
  # Tasks call:  docker run -v \$HOME/results:/results python:3.12 ...
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
  echo ">> Grafana at http://<this-ip>:3000 - add Prometheus data source http://$HEAD_IP:9090"
fi

echo
echo "DONE. Checks:"
echo "  systemctl status ray-worker node_exporter"
echo "  Head dashboard http://$HEAD_IP:8265 should now list this node."
