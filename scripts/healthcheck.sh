#!/usr/bin/env bash
#
# healthcheck.sh - verify a node's homelab services are up. Run it on the node.
# Auto-detects head vs worker from which systemd units exist. Exits non-zero if
# any check fails, so it's usable from cron or CI.
#
set -uo pipefail   # deliberately NOT -e: run every check, then report.
LAB_DIR="$HOME/raylab"
fail=0

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

if has_unit ray-head.service; then
  echo "# head node"
  check "ray-head active"              systemctl is-active --quiet ray-head
  check "prometheus active"            systemctl is-active --quiet prometheus
  check "Ray dashboard :8265 responds" curl -fsS -o /dev/null http://localhost:8265
  check "Prometheus :9090 healthy"     curl -fsS -o /dev/null http://localhost:9090/-/healthy
  check "ray status"                   "$LAB_DIR/venv/bin/ray" status
fi

if has_unit ray-worker.service; then
  echo "# worker node"
  check "ray-worker active"    systemctl is-active --quiet ray-worker
  check "node_exporter active" systemctl is-active --quiet node_exporter
fi

echo
if [[ $fail -eq 0 ]]; then echo "All checks passed."; else echo "Some checks FAILED." >&2; fi
exit $fail
