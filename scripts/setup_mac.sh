#!/usr/bin/env bash
#
# setup_mac.sh - join a macOS worker (e.g. the MacBook) to the Ray cluster.
# macOS has no systemd or apt, so this uses uv for the pinned Python and launchd
# (the macOS service manager) to keep the worker running and restart it on boot.
#
# Prerequisite: install the Tailscale app (same account) and sign in, so the head
# node's name resolves.
#
#   HEAD_IP=head01 RESOURCES='{"mac": 1}' bash scripts/setup_mac.sh
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./common.sh

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS. On Linux use scripts/setup_worker.sh." >&2
  exit 1
fi
if [[ -z "${HEAD_IP:-}" ]]; then
  echo "Set HEAD_IP, e.g.: HEAD_IP=head01 RESOURCES='{\"mac\": 1}' bash scripts/setup_mac.sh" >&2
  exit 1
fi
RESOURCES="${RESOURCES:-}"
if [[ -z "$RESOURCES" ]]; then RESOURCES='{"mac": 1}'; fi   # default tag: mac
RAY_PORT=6379
LABEL="com.homelab.ray-worker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "== [1/2] Python venv + Ray (uv, pinned Python) =="
setup_venv

echo "== [2/2] launchd worker service =="
mkdir -p "$HOME/Library/LaunchAgents"
# --block keeps ray in the foreground so launchd can supervise it; KeepAlive
# restarts it on crash or reboot. launchd passes an argv array, so the resources
# JSON needs no shell quoting.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$LAB_DIR/venv/bin/ray</string>
    <string>start</string>
    <string>--address=$HEAD_IP:$RAY_PORT</string>
    <string>--resources=$RESOURCES</string>
    <string>--metrics-export-port=8080</string>
    <string>--block</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LAB_DIR/ray-worker.log</string>
  <key>StandardErrorPath</key><string>$LAB_DIR/ray-worker.log</string>
</dict>
</plist>
EOF

# Reload the agent (bootout is a no-op the first time).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Started. Giving it a few seconds, then the tail of its log:"
sleep 6
tail -n 15 "$LAB_DIR/ray-worker.log" 2>/dev/null || true
echo
echo "DONE. On the head, 'ray status' should now list this node (tag $RESOURCES)."
echo "Log: $LAB_DIR/ray-worker.log   Stop: launchctl bootout gui/$(id -u)/$LABEL"
