#!/usr/bin/env bash
#
# healthcheck.sh - verify a node's homelab services are up; run it on the node
# auto-detects head/worker (systemd) or macOS worker (launchd), exits non-zero if
# any check fails (usable from cron or CI), and confirms the node actually joined
# the cluster, not just that its service is running
#
set -uo pipefail   # deliberately not -e: run every check, then report
LAB_DIR="$HOME/raylab"
PY=""
[[ -x "$LAB_DIR/venv/bin/python" ]] && PY="$LAB_DIR/venv/bin/python"
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

# like check, but appends the command's last stdout line as a detail; stderr is
# dropped, so helpers print their summary to stdout
report() {
  local name=$1; shift
  local out rc
  out=$("$@" 2>/dev/null); rc=$?
  out=$(printf '%s' "$out" | tail -n1)
  if [[ $rc -eq 0 ]]; then
    printf 'ok    %s%s\n' "$name" "${out:+ — $out}"
  else
    printf 'FAIL  %s%s\n' "$name" "${out:+ — $out}"
    fail=1
  fi
}

has_unit() { systemctl cat "$1" >/dev/null 2>&1; }
MAC_LABEL="com.homelab.ray-worker"
MAC_PLIST="$HOME/Library/LaunchAgents/$MAC_LABEL.plist"
launchd_loaded()  { launchctl print "gui/$(id -u)/$MAC_LABEL" >/dev/null 2>&1; }
launchd_running() { launchctl print "gui/$(id -u)/$MAC_LABEL" 2>/dev/null | grep -qE 'pid = [0-9]+'; }

# head address this worker joins, read from its service definition (systemd unit
# on linux, launchd plist on macOS); prints "host:port"
worker_head_addr() {
  local a
  a=$(systemctl cat ray-worker.service 2>/dev/null \
        | sed -n 's/.*--address=\([^ ]*\).*/\1/p' | head -n1)
  if [[ -z "$a" && -f "$MAC_PLIST" ]]; then
    a=$(sed -n 's|.*--address=\([^<]*\)</string>.*|\1|p' "$MAC_PLIST" | head -n1)
  fi
  printf '%s' "$a"
}

# tcp-reachability of the head's GCS, via the venv python (portable; macOS lacks
# timeout and a usable /dev/tcp)
tcp_reachable() {
  "$PY" - "$1" <<'PY'
import socket, sys
h, _, p = sys.argv[1].rpartition(":")
try:
    socket.create_connection((h, int(p)), timeout=5).close()
except Exception as e:
    sys.stderr.write(str(e)); sys.exit(1)
PY
}

# does the head's node list show this node alive? uses the state API (list_nodes),
# which unlike ray.init(address=...) needs no local raylet, so it works as an
# external probe and also catches a down head or version mismatch; matches our own
# ips/hostname against the nodes and reports present / registered-but-dead / missing
cluster_member() {
  "$PY" - "$1" <<'PY'
import socket, subprocess, sys
addr = sys.argv[1]
host, _, port = addr.rpartition(":")
ips = set()
# the local source ip used to reach the head - matches what Ray registers as
# node_ip, and works on macOS where `hostname -I` doesn't exist
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((host, int(port or 6379)))
    ips.add(s.getsockname()[0]); s.close()
except Exception:
    pass
for cmd in (["hostname", "-I"], ["tailscale", "ip", "-4"]):
    try:
        ips.update(subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).split())
    except Exception:
        pass
hn = socket.gethostname().split(".")[0]
try:
    from ray.util.state import list_nodes
    nodes = list_nodes(address=addr, limit=10000, raise_on_missing_output=False)
except Exception as e:
    sys.stdout.write(f"cannot query head at {addr}: {type(e).__name__} (head down, or Ray/Python version mismatch)")
    sys.exit(1)
def is_me(n):
    return n.get("node_ip") in ips or str(n.get("node_name", "")).split(".")[0] == hn
alive = [n for n in nodes if n.get("state") == "ALIVE"]
if any(is_me(n) for n in alive):
    sys.stdout.write(f"{len(alive)} node(s) alive; this node present")
    sys.exit(0)
if any(is_me(n) for n in nodes):
    sys.stdout.write(f"{len(alive)} node(s) alive; this node REGISTERED BUT DEAD (dropped; restart ray-worker)")
    sys.exit(1)
sys.stdout.write(f"{len(alive)} node(s) alive; this node MISSING from cluster (never joined)")
sys.exit(1)
PY
}

# head-side node count, parsed from `ray status`; informational, to spot a head
# serving an empty cluster
cluster_count() {
  "$LAB_DIR/venv/bin/ray" status 2>/dev/null | awk '
    /^Active:/   { inactive = 1; next }
    /^[A-Za-z]/  { inactive = 0 }
    inactive && /node_/ { c++ }
    END { printf "%d node(s) active", c+0; exit (c+0 > 0 ? 0 : 1) }'
}

# worker cluster checks (linux + macOS): is the head reachable, and did we join?
cluster_checks() {
  local addr; addr=$(worker_head_addr)
  if [[ -z "$PY" ]]; then
    printf 'warn  skipping cluster checks (no venv Python at %s/venv)\n' "$LAB_DIR" >&2
    return
  fi
  if [[ -z "$addr" ]]; then
    printf 'warn  skipping cluster checks (no --address found in the worker service)\n' >&2
    return
  fi
  check  "head GCS $addr reachable" tcp_reachable "$addr"
  report "joined Ray cluster"       cluster_member "$addr"
}

if has_unit ray-head.service; then
  ran=1
  echo "# head node"
  check  "ray-head active"              systemctl is-active --quiet ray-head
  check  "prometheus active"            systemctl is-active --quiet prometheus
  check  "Ray dashboard :8265 responds" curl -fsS -o /dev/null http://localhost:8265
  check  "Prometheus :9090 healthy"     curl -fsS -o /dev/null http://localhost:9090/-/healthy
  check  "ray status"                   "$LAB_DIR/venv/bin/ray" status
  report "cluster nodes" cluster_count
fi

if has_unit ray-worker.service; then
  ran=1
  echo "# worker node"
  check "ray-worker active"    systemctl is-active --quiet ray-worker
  check "node_exporter active" systemctl is-active --quiet node_exporter
  cluster_checks
fi

# macOS worker: launchd, not systemd; node_exporter isn't installed there
if [[ "$(uname -s)" == "Darwin" ]] && launchd_loaded; then
  ran=1
  echo "# macOS worker"
  check "ray-worker (launchd) loaded"  launchd_loaded
  check "ray-worker running"           launchd_running
  cluster_checks
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
