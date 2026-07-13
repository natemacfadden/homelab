#!/usr/bin/env bash
#
# setup_head.sh - home lab HEAD NODE (always-on Debian box).
# Installs Ray head, Prometheus, and a nightly cron stub; keeps the box awake
# with the lid closed. Run as your normal user with sudo rights:
#   bash scripts/setup_head.sh
# Idempotent: safe to re-run (re-running restarts ray-head and prometheus).
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./common.sh

PROMETHEUS_VERSION="3.5.0"
PROM_DIR="/opt/prometheus"
RAY_PORT=6379
# Prometheus scrape targets: edit to match your workers (Tailscale names or
# static IPs that resolve from this box), then re-run. This list is the source
# of truth; the script regenerates prometheus.yml from it.
NODE_TARGETS=(ws1 ws2 bigbox macbook localhost)

preflight

echo "== [1/6] Base packages =="
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip curl git tmux cron

echo "== [2/6] Python venv + Ray =="
setup_venv

echo "== [3/6] Prometheus =="
sudo mkdir -p "$PROM_DIR"
if ! "$PROM_DIR/prometheus" --version 2>/dev/null | grep -q "$PROMETHEUS_VERSION"; then
  curl -fL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}.tar.gz" \
    | sudo tar xz -C "$PROM_DIR" --strip-components=1
fi
targets=$(printf "'%s:9100', " "${NODE_TARGETS[@]}")
sudo tee "$PROM_DIR/prometheus.yml" >/dev/null <<EOF
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: ray            # Ray writes its own service-discovery file
    file_sd_configs:
      - files: ['/tmp/ray/prom_metrics_service_discovery.json']
  - job_name: nodes          # node_exporter on each worker
    static_configs:
      - targets: [${targets%, }]
EOF

echo "== [4/6] systemd services (Ray head + Prometheus) =="
write_service ray-head <<EOF
[Unit]
Description=Ray head node
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
User=$USER
ExecStart=$LAB_DIR/venv/bin/ray start --head --port=$RAY_PORT --dashboard-host=0.0.0.0 --metrics-export-port=8080
ExecStop=$LAB_DIR/venv/bin/ray stop
Restart=on-failure
Environment=RAY_task_events_max_num_task_in_gcs=10000   # prune GCS task metadata
[Install]
WantedBy=multi-user.target
EOF
write_service prometheus <<EOF
[Unit]
Description=Prometheus
After=network-online.target
[Service]
User=$USER
ExecStart=$PROM_DIR/prometheus --config.file=$PROM_DIR/prometheus.yml --storage.tsdb.path=$LAB_DIR/prometheus-data --storage.tsdb.retention.time=15d
Restart=on-failure
MemoryMax=1G
[Install]
WantedBy=multi-user.target
EOF

echo "== [5/6] Always-on (ignore lid, disable sleep) =="
# This laptop is an always-on server: closing the lid must not suspend it, or
# the whole cluster loses its head.
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/homelab-headless.conf >/dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
sudo systemctl restart systemd-logind
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "== [6/6] Tailscale + nightly cron stub =="
install_tailscale
mkdir -p "$LAB_DIR/jobs"
cat > "$LAB_DIR/jobs/nightly_trawl.sh" <<EOF
#!/usr/bin/env bash
# Pick the next repo (your scoring logic here), then submit it to Ray.
source $LAB_DIR/venv/bin/activate
# ray job submit --address http://localhost:8265 -- python trawl.py --repo "\$REPO"
EOF
chmod +x "$LAB_DIR/jobs/nightly_trawl.sh"
# Rebuild the crontab, keeping existing lines except our job. The `|| true`
# guards stop set -e aborting on a fresh box (no crontab yet, grep finds nothing).
{
  crontab -l 2>/dev/null | grep -v nightly_trawl || true
  echo "0 2 * * * $LAB_DIR/jobs/nightly_trawl.sh >> $LAB_DIR/jobs/trawl.log 2>&1"
} | crontab -

IP=$(hostname -I | awk '{print $1}')
echo
echo "DONE. HEAD_IP for workers: $IP"
echo "  Ray dashboard  http://$IP:8265"
echo "  Prometheus     http://$IP:9090"
