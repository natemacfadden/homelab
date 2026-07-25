#!/usr/bin/env bash
#
# provision this box as the head node (always-on Debian box): Ray head,
# Prometheus, a nightly cron stub, and lid-close/sleep disabled. Run as your
# normal user with sudo rights:
#
#   ./lab setup --head
#
# Prints the address to use as HEAD_IP on the workers, and saves it to ~/ip.txt.
# Do this box first - the workers need that address.
#
# env:
#   INSTALL_SSH   0 to skip OpenSSH (default 1). Password auth is left alone
#                 unless you set SSH_KEY_ONLY=1, so a run can't lock you out;
#                 SSH_TAILSCALE_ONLY=1 binds sshd to the Tailscale IP.
#   PYTHON_VERSION / RAY_VERSION are pinned in scripts/common.sh and must match
#                 on every node - Ray refuses to join otherwise.
#
# edit-and-re-run config: the Prometheus scrape list is the NODE_TARGETS array
# at the top of scripts/setup_head.sh.
# Idempotent: re-running restarts ray-head and prometheus (see the note it
# prints about workers reconnecting).
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./common.sh

PROMETHEUS_VERSION="3.5.0"
PROM_DIR="/opt/prometheus"
RAY_PORT=6379
# node_exporter scrape targets; regenerates prometheus.yml on re-run. Linux
# workers only - the mac and this box don't run node_exporter. Stale names here
# kill host metrics silently, since Ray's own targets stay up. Check after a
# rename: http://<head>:9090/targets
NODE_TARGETS=(compute01 compute02 compute03)

preflight

echo "== [1/6] Base packages =="
apt_get update
apt_get install -y python3 python3-venv python3-pip curl git tmux cron

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
# --block keeps ray in the foreground so systemd tracks the head's processes and
# restarts them when one dies; the old Type=forking exited 0 and hid raylet death
# (GCS kept serving while the head dropped out of its own cluster)
write_service ray-head <<EOF
[Unit]
Description=Ray head node
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
User=$USER
ExecStart=$LAB_DIR/venv/bin/ray start --head --port=$RAY_PORT --dashboard-host=0.0.0.0 --metrics-export-port=8080 --block
ExecStop=$LAB_DIR/venv/bin/ray stop
Restart=always
RestartSec=10
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
# always-on server: a lid-close suspend would take the cluster's head down
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/homelab-headless.conf >/dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
sudo systemctl restart systemd-logind
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "== [6/6] Tailscale =="
install_tailscale

# Legacy cleanup: review/ replaced the old nightly_trawl.sh cron stub. Doing it
# here means an older install gets cleaned by the next setup run.
if crontab -l 2>/dev/null | grep -q nightly_trawl; then
  crontab -l 2>/dev/null | grep -v nightly_trawl | crontab -
  echo "removed the legacy nightly_trawl cron (superseded by ./review nightly)"
fi
rm -f "$LAB_DIR/jobs/nightly_trawl.sh"

if [[ "${INSTALL_SSH:-1}" == "1" ]]; then install_ssh; fi

LAN_IP=$(hostname -I | awk '{print $1}')
TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
HEAD_ADDR=${TS_IP:-$LAN_IP}   # prefer the stable Tailscale IP when it's up
echo
{
  echo "Head node addresses:"
  echo "  LAN IP:        $LAN_IP"
  if [[ -n "$TS_IP" ]]; then
    echo "  Tailscale IP:  $TS_IP  (stable; preferred as HEAD_IP)"
  else
    echo "  Tailscale IP:  not up yet - run 'sudo tailscale up', then re-run this script"
  fi
  echo
  echo "Use as HEAD_IP on workers: $HEAD_ADDR"
  echo "  Ray dashboard  http://$HEAD_ADDR:8265"
  echo "  Prometheus     http://$HEAD_ADDR:9090"
} | tee "$HOME/ip.txt"
echo "(also saved to $HOME/ip.txt)"

# restarting the head resets Ray, so existing workers drop; they come back on
# their own. Say so here, or it reads as a broken cluster.
echo
echo "Note: this restarted Ray, so any existing workers just dropped. They"
echo "reconnect on their own over a minute or two - nudge a straggler with"
echo "'sudo systemctl restart ray-worker' on that box, and confirm with './lab check'."

echo
run_healthcheck
