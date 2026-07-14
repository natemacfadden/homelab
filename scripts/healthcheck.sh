#!/usr/bin/env bash
#
# healthcheck.sh - verify a node's homelab services are up. Run it on the node.
# Auto-detects head/worker (systemd) or macOS worker (launchd). Exits non-zero if
# any check fails, so it's usable from cron or CI.
#
set -uo pipefail   # deliberately NOT -e: run every check, then report.
LAB_DIR="$HOME/raylab"
fail=0
ran=0

check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    fail=1
  fi
}
has_unit() { systemctl cat "$1" >/dev/null 2>&1; }
MAC_LABEL="com.homelab.ray-worker"
launchd_loaded()  { launchctl print "gui/$(id -u)/$MAC_LABEL" >/dev/null 2>&1; }
launchd_running() { launchctl print "gui/$(id -u)/$MAC_LABEL" 2>/dev/null | grep -qE 'pid = [0-9]+'; }

if has_unit ray-head.service; then
  ran=1
  echo "# head node"
  check "ray-head active"              systemctl is-active --quiet ray-head
  check "prometheus active"            systemctl is-active --quiet prometheus
  check "Ray dashboard :8265 responds" curl -fsS -o /dev/null http://localhost:8265
  check "Prometheus :9090 healthy"     curl -fsS -o /dev/null http://localhost:9090/-/healthy
  check "ray status"                   "$LAB_DIR/venv/bin/ray" status
fi

if has_unit ray-worker.service; then
  ran=1
  echo "# worker node"
  check "ray-worker active"    systemctl is-active --quiet ray-worker
  check "node_exporter active" systemctl is-active --quiet node_exporter
fi

# macOS worker: launchd, not systemd. node_exporter isn't installed there.
if [[ "$(uname -s)" == "Darwin" ]] && launchd_loaded; then
  ran=1
  echo "# macOS worker"
  check "ray-worker (launchd) loaded"  launchd_loaded
  check "ray-worker running"           launchd_running
fi

echo
if [[ $ran -eq 0 ]]; then
  script=scripts/setup_worker.sh
  [[ "$(uname -s)" == "Darwin" ]] && script=scripts/setup_worker_mac.sh
  echo "No homelab services found on this node (run $script first)." >&2
  exit 1
fi
if [[ $fail -eq 0 ]]; then echo "All checks passed."; else echo "Some checks FAILED." >&2; fi
exit $fail
