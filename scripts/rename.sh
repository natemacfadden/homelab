#!/usr/bin/env bash
#
# rename.sh - rename THIS machine and restart Ray so it picks up the new name.
# Sets the OS hostname, /etc/hosts, and the Tailscale/MagicDNS name together.
# Run it on the box you're renaming:
#   bash scripts/rename.sh head01
#
# It only renames the machine you run it on. References to its OLD name on other
# machines still need updating by hand - see the reminder printed at the end.
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./common.sh

NEW=${1:-}
if [[ -z "$NEW" ]]; then
  echo "Usage: bash scripts/rename.sh <new-name>   (e.g. head01, compute01)" >&2
  exit 1
fi
if ! [[ "$NEW" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Invalid name '$NEW': use lowercase letters, digits, and hyphens (not at the ends)." >&2
  exit 1
fi

preflight
OLD=$(hostname)
if [[ "$OLD" == "$NEW" ]]; then
  echo "Already named '$NEW'; nothing to do."
  exit 0
fi
echo "Renaming '$OLD' -> '$NEW'"

echo "== [1/4] OS hostname =="
sudo hostnamectl set-hostname "$NEW"

echo "== [2/4] /etc/hosts =="
if grep -qE '^127\.0\.1\.1' /etc/hosts; then
  sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$NEW" | sudo tee -a /etc/hosts >/dev/null
fi

echo "== [3/4] Tailscale name =="
# `tailscale set` changes one setting without resetting others (unlike
# `tailscale up`, which is declarative and would revert unspecified flags).
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  sudo tailscale set --hostname="$NEW"
  echo "Tailscale/MagicDNS name set to '$NEW'."
else
  echo "Tailscale not connected; skipped. Run later: sudo tailscale set --hostname=$NEW"
fi

echo "== [4/4] Restart Ray =="
if systemctl cat ray-head.service >/dev/null 2>&1; then
  sudo systemctl restart ray-head
fi
if systemctl cat ray-worker.service >/dev/null 2>&1; then
  sudo systemctl restart ray-worker
fi

echo
echo "DONE. '$OLD' is now '$NEW'."
echo
echo "Update references to the OLD name on OTHER machines:"
echo "  - any worker pointing at this head: re-run with HEAD_IP=$NEW"
echo "  - NODE_TARGETS in setup_head.sh, then re-run setup_head.sh"
