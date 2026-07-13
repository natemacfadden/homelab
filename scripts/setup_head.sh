#!/usr/bin/env bash
#
# setup_head.sh - Home lab HEAD NODE (Chromebook C302, Debian, 4 GB RAM)
#
# Installs: Python venv + Ray (head), Prometheus, Tailscale, tmux, cron stub.
# Configures the box to stay on with the lid closed (always-on headless role).
# Does NOT install: Docker (not needed here), Grafana (runs on a workstation),
#                   desktop packages (headless box).
#
# Run as your normal user (needs sudo rights):  bash setup_head.sh
# Safe to re-run: every step is idempotent, and services are restarted so config
# edits (e.g. NODE_TARGETS below) actually take effect. Re-run to catch rot.
#
set -euo pipefail

# ----- config: pinned versions (bump deliberately, then re-run) --------------
RAY_VERSION="2.48.0"          # pip install "ray[default]==$RAY_VERSION"
PROMETHEUS_VERSION="3.5.0"    # LTS line
LAB_DIR="$HOME/raylab"
PROM_DIR="/opt/prometheus"
RAY_PORT=6379

# node_exporter targets Prometheus scrapes. Edit to match your workers, then
# re-run - this list is the source of truth. Use Tailscale names (stable) or
# static IPs; whatever you put here must resolve/route FROM the head node.
NODE_TARGETS=(ws1 ws2 bigbox macbook localhost)

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

echo "== [1/7] Base packages =="
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip curl git tmux cron

echo "== [2/7] Python venv + Ray =="
mkdir -p "$LAB_DIR"
[[ -x "$LAB_DIR/venv/bin/python" ]] || python3 -m venv "$LAB_DIR/venv"
# shellcheck disable=SC1091
source "$LAB_DIR/venv/bin/activate"
pip install --upgrade pip
pip install "ray[default]==$RAY_VERSION"   # [default] = includes the dashboard
deactivate

echo "== [3/7] Prometheus =="
sudo mkdir -p "$PROM_DIR"
if ! "$PROM_DIR/prometheus" --version 2>/dev/null | grep -q "$PROMETHEUS_VERSION"; then
  curl -fL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}.tar.gz" \
    | sudo tar xz -C "$PROM_DIR" --strip-components=1
fi
# Regenerate config from NODE_TARGETS (the tracked source of truth).
targets_yaml=$(printf "'%s:9100', " "${NODE_TARGETS[@]}")
targets_yaml="[${targets_yaml%, }]"
sudo tee "$PROM_DIR/prometheus.yml" >/dev/null <<EOF
global:
  scrape_interval: 15s
scrape_configs:
  # Ray exports its metrics via a service-discovery file it writes itself:
  - job_name: ray
    file_sd_configs:
      - files: ['/tmp/ray/prom_metrics_service_discovery.json']
  # node_exporter on every machine (installed by setup_worker.sh):
  - job_name: nodes
    static_configs:
      - targets: ${targets_yaml}
EOF

echo "== [4/7] systemd services (Ray head + Prometheus) =="
sudo tee /etc/systemd/system/ray-head.service >/dev/null <<EOF
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
# GCS memory hygiene: prune finished-task metadata more aggressively.
Environment=RAY_task_events_max_num_task_in_gcs=10000

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/prometheus.service >/dev/null <<EOF
[Unit]
Description=Prometheus
After=network-online.target

[Service]
User=$USER
ExecStart=$PROM_DIR/prometheus --config.file=$PROM_DIR/prometheus.yml --storage.tsdb.path=$LAB_DIR/prometheus-data --storage.tsdb.retention.time=15d
Restart=on-failure
# Belt-and-braces on a 4 GB box:
MemoryMax=1G

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ray-head prometheus
# restart (not just start) so re-runs pick up edited units / prometheus.yml:
sudo systemctl restart ray-head prometheus

echo "== [5/7] Always-on (ignore lid, disable sleep) =="
# This is a laptop acting as an always-on headless server: closing the lid must
# NOT suspend it, or the whole cluster loses its head.
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/homelab-headless.conf >/dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
sudo systemctl restart systemd-logind
# Belt-and-braces: refuse system sleep/suspend entirely.
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "== [6/7] Tailscale =="
command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
echo ">> Run 'sudo tailscale up' once, manually, to authenticate."

echo "== [7/7] Nightly repo-trawler cron stub =="
mkdir -p "$LAB_DIR/jobs"
cat > "$LAB_DIR/jobs/nightly_trawl.sh" <<EOF
#!/usr/bin/env bash
# Pick the next repo (your scoring logic goes here), then submit to Ray.
source $LAB_DIR/venv/bin/activate
# ray job submit --address http://localhost:8265 -- python trawl.py --repo "\$REPO"
EOF
chmod +x "$LAB_DIR/jobs/nightly_trawl.sh"
# Rebuild the crontab: keep existing lines except our job, then (re)add it.
# The `|| true` guards stop set -e/pipefail aborting when there's no crontab yet
# or grep matches nothing (both exit non-zero, harmlessly, on a fresh box).
{
  crontab -l 2>/dev/null | grep -v nightly_trawl || true
  echo "0 2 * * * $LAB_DIR/jobs/nightly_trawl.sh >> $LAB_DIR/jobs/trawl.log 2>&1"
} | crontab -

IP=$(hostname -I | awk '{print $1}')
echo
echo "DONE. This node's IP (use as HEAD_IP on workers): $IP"
echo
echo "Checks:"
echo "  systemctl status ray-head prometheus   # both active?"
echo "  http://$IP:8265                        # Ray dashboard, from any browser"
echo "  http://$IP:9090                        # Prometheus UI"
echo "  crontab -l                             # nightly job registered"
