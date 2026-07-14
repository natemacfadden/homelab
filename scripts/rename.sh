#!/usr/bin/env bash
#
# rename.sh - rename this machine (OS hostname + Tailscale name) and restart Ray
# so it picks up the new name; works on Linux (hostnamectl/systemd) and macOS
# (scutil/launchd), run on the box you're renaming:
#   bash scripts/rename.sh head01
#
# it only renames the machine you run it on; references to its old name on other
# machines still need updating by hand (see the reminder printed at the end)
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./common.sh   # for the fail-loud ERR trap

NEW=${1:-}
if [[ -z "$NEW" ]]; then
  echo "Usage: bash scripts/rename.sh <new-name>   (e.g. head01, compute01)" >&2
  exit 1
fi
if ! [[ "$NEW" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Invalid name '$NEW': use lowercase letters, digits, and hyphens (not at the ends)." >&2
  exit 1
fi
sudo -v || { echo "This script needs sudo." >&2; exit 1; }

OLD=$(hostname)
echo "Renaming '$OLD' -> '$NEW'"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "== macOS hostname =="
  sudo scutil --set ComputerName "$NEW"
  sudo scutil --set HostName "$NEW"
  sudo scutil --set LocalHostName "$NEW"

  echo "== Tailscale name =="
  if command -v tailscale >/dev/null 2>&1; then
    sudo tailscale set --hostname="$NEW" && echo "Set Tailscale name to '$NEW'."
  else
    echo "Tailscale CLI not found - rename this device in the Tailscale admin console"
    echo "(or enable the CLI in the Tailscale app settings)."
  fi

  echo "== Restart Ray worker =="
  launchctl kickstart -k "gui/$(id -u)/com.homelab.ray-worker" 2>/dev/null \
    || echo "(ray-worker launchd job not loaded; nothing to restart)"
else
  echo "== OS hostname =="
  sudo hostnamectl set-hostname "$NEW"

  echo "== /etc/hosts =="
  if grep -qE '^127\.0\.1\.1' /etc/hosts; then
    sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$NEW" | sudo tee -a /etc/hosts >/dev/null
  fi

  echo "== Tailscale name =="
  # `tailscale set` changes one flag; `up` would revert unspecified ones
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    sudo tailscale set --hostname="$NEW"
    echo "Set Tailscale name to '$NEW'."
  else
    echo "Tailscale not connected; skipped. Run later: sudo tailscale set --hostname=$NEW"
  fi

  echo "== Restart Ray =="
  if systemctl cat ray-head.service   >/dev/null 2>&1; then sudo systemctl restart ray-head;   fi
  if systemctl cat ray-worker.service >/dev/null 2>&1; then sudo systemctl restart ray-worker; fi
fi

echo
echo "DONE. '$OLD' is now '$NEW'."
echo "Update OLD-name references on OTHER machines: worker HEAD_IP=$NEW, and"
echo "NODE_TARGETS in setup_head.sh (then re-run it)."
