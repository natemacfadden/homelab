#!/usr/bin/env bash
# Run ds4-server in the foreground with the SAME flags as the systemd unit.
# Use this instead of a bare ./ds4-server (which defaults to a 32k context).
# Don't run while the systemd instance is active (port clash):
#   sudo systemctl stop ds4-server
set -euo pipefail

exec /home/nate/github/ds4/ds4-server \
  -m /home/nate/github/ds4/ds4flash.gguf \
  --host 0.0.0.0 --port 8000 \
  --ctx 131072 \
  --kv-disk-dir /home/nate/.ds4/kv-disk --kv-disk-space-mb 16384 \
  "$@"
