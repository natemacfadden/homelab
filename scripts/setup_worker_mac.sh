#!/usr/bin/env bash
#
# setup_worker_mac.sh - join a macOS worker (e.g. the MacBook) to the Ray cluster
# macOS has no systemd or apt, so this uses uv for the pinned Python and launchd
# (the macOS service manager) to keep the worker running and restart it on boot
#
# prerequisite: install the Tailscale app (same account) and sign in, so the head
# node's name resolves
#
#   HEAD_IP=head01 RESOURCES='{"mac": 1}' bash scripts/setup_worker_mac.sh
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./common.sh

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS. On Linux use scripts/setup_worker.sh." >&2
  exit 1
fi
if [[ -z "${HEAD_IP:-}" ]]; then
  echo "Set HEAD_IP, e.g.: HEAD_IP=head01 RESOURCES='{\"mac\": 1}' bash scripts/setup_worker_mac.sh" >&2
  exit 1
fi
RESOURCES="${RESOURCES:-}"
if [[ -z "$RESOURCES" ]]; then RESOURCES='{"mac": 1}'; fi   # default tag: mac
RAY_PORT=6379
LABEL="com.homelab.ray-worker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# fail fast if the head isn't reachable - usually Tailscale isn't connected here
if ! nc -z -G 3 "$HEAD_IP" "$RAY_PORT" 2>/dev/null; then
  cat >&2 <<EOF
ERROR: can't reach the Ray head at $HEAD_IP:$RAY_PORT.

Most likely Tailscale isn't connected on this Mac. Open the Tailscale app, sign
in (same account as the cluster), toggle it On, then re-run this script.

If you used a name like 'head01' that won't resolve, MagicDNS isn't active yet -
use the head's 100.x Tailscale IP as HEAD_IP instead (tailscale ip -4 on head01).
EOF
  exit 1
fi

echo "== [1/2] Python venv + Ray (uv, pinned Python) =="
setup_venv

echo "== [2/2] launchd worker service =="
mkdir -p "$HOME/Library/LaunchAgents"
# --block keeps ray in the foreground for launchd; KeepAlive restarts it (launchd
# passes an argv array, so the resources JSON needs no shell quoting)
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <!-- caffeinate -s: stay awake while running, but only on AC (not battery) -->
    <string>/usr/bin/caffeinate</string>
    <string>-s</string>
    <string>$LAB_DIR/venv/bin/ray</string>
    <string>start</string>
    <string>--address=$HEAD_IP:$RAY_PORT</string>
    <string>--resources=$RESOURCES</string>
    <string>--metrics-export-port=8080</string>
    <string>--block</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- Ray needs this opt-in for a multi-node cluster on macOS -->
    <key>RAY_ENABLE_WINDOWS_OR_OSX_CLUSTER</key><string>1</string>
    <!-- shed tasks at 80% whole-machine memory (matches the Linux workers) -->
    <key>RAY_memory_usage_threshold</key><string>0.80</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LAB_DIR/ray-worker.log</string>
  <key>StandardErrorPath</key><string>$LAB_DIR/ray-worker.log</string>
</dict>
</plist>
EOF

# reload: wait for the old instance to unload before bootstrap, or launchd races
# and returns "Input/output error" (exit 5)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in {1..10}; do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.3
done
launchctl bootstrap "gui/$(id -u)" "$PLIST"

if [[ "${INSTALL_SSH:-1}" == "1" ]]; then
  echo "== OpenSSH / Remote Login (INSTALL_SSH=1; set INSTALL_SSH=0 to skip) =="
  # enable Remote Login; needs Full Disk Access, else flip the toggle by hand
  if sudo systemsetup -setremotelogin on 2>/dev/null; then
    echo ">> Remote Login enabled."
  else
    echo ">> Enable by hand: System Settings > General > Sharing > Remote Login." >&2
  fi
  # harden only if a key exists and sshd_config includes the drop-in dir (Ventura+)
  keys="$HOME/.ssh/authorized_keys"
  if [[ -s "$keys" ]] && grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config 2>/dev/null; then
    printf 'PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
      | sudo tee /etc/ssh/sshd_config.d/homelab.conf >/dev/null
    sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
    echo ">> Hardened to key-only auth."
  else
    echo ">> SSH auth left unchanged (add a key to $keys, then re-run to harden)."
  fi
fi

echo
echo "Started. Giving it a few seconds, then the tail of its log:"
sleep 6
tail -n 15 "$LAB_DIR/ray-worker.log" 2>/dev/null || true
echo
echo "DONE. On the head, 'ray status' should now list this node (tag $RESOURCES)."
echo "Log: $LAB_DIR/ray-worker.log   Stop: launchctl bootout gui/$(id -u)/$LABEL"
echo
echo "The worker runs under launchd, so it survives closing the shell and reboots."
echo "caffeinate keeps the Mac awake while it runs, but only on AC power (on battery"
echo "it sleeps normally). To also run with the LID CLOSED while plugged in, run once:"
echo "  sudo pmset -c disablesleep 1     (AC only; undo: sudo pmset -c disablesleep 0)"
