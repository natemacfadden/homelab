#!/usr/bin/env bash
#
# live CPU / RAM / disk / GPU graphs for the whole fleet - fleettop, pointed at
# head01 plus the WORKERS list in scripts/deploy.sh:
#
#   ./lab top                  live graphs (v toggles bars, q quits)
#   ./lab top --once           one text snapshot
#
# Any other fleettop flags pass through (fleettop --help). Install it once:
#
#   pip install git+https://github.com/natemacfadden/fleettop
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v fleettop >/dev/null || {
  echo "fleettop isn't installed: pip install git+https://github.com/natemacfadden/fleettop" >&2
  exit 1
}
# host column of the uncommented rows in deploy.sh's WORKERS=( ... )
mapfile -t workers < <(sed -n '/^WORKERS=(/,/^)/p' deploy.sh | grep -E '^\s*"' \
  | sed -E 's/^\s*"\s*([^ |]+).*/\1/')
exec fleettop "${HEAD_HOST:-head01}" "${workers[@]}" "$@"
