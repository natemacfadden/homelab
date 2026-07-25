#!/usr/bin/env bash
#
# push this repo to every worker and provision it, so you don't SSH into each
# box by hand; run from your laptop or the head:
#
#   HEAD_IP=head01 ./lab deploy            provision/update all workers
#   ./lab deploy --check                   run the healthcheck on each instead
#
# the fleet list is the WORKERS array at the top of scripts/deploy.sh - edit it
# there (one row per worker: host | RESOURCES | extra flags | linux|mac)
#
# needs passwordless (key) SSH to each host - see the README "Deploy to all
# workers" section for the one-time ssh-copy-id setup. --check runs whatever is
# already on each box, so deploy at least once before relying on it.
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # repo root
source ./scripts/common.sh               # for the fail-loud ERR trap

# --- manifest (edit me): host | RESOURCES | extra flags | os ----------------
# same idea as NODE_TARGETS in scripts/setup_head.sh - this list is the source
# of truth for who's in the fleet.
# one row per worker: SSH host, the Ray tag it advertises, any INSTALL_* flags,
# and linux|mac (which setup script to run); use "user@host" to override SSH_USER
WORKERS=(
  "compute01    | {\"amd\": 1, \"big_memory\": 1} |                                    | linux"
  "compute02    | {\"cuda\": 1}                   |                                    | linux"
  "compute03    | {\"amd\": 1, \"small_task\": 1} |                                    | linux"
  "natemacfadden@computemac01 | {\"mac\": 1}      |                                    | mac"
)
SSH_USER="${SSH_USER:-$USER}"            # override if the login differs per box
# ----------------------------------------------------------------------------

MODE=run
[[ "${1:-}" == "--check" ]] && MODE=check
if [[ "$MODE" == "run" && -z "${HEAD_IP:-}" ]]; then
  echo "Set HEAD_IP (workers need it to join): HEAD_IP=head01 ./lab deploy" >&2
  exit 1
fi

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

fail=0
for row in "${WORKERS[@]}"; do
  IFS='|' read -r host res flags os <<<"$row"
  host=$(trim "$host"); res=$(trim "$res"); flags=$(trim "$flags"); os=$(trim "$os")
  # host may be "user@host"; otherwise fall back to SSH_USER
  target="$host"; [[ "$host" != *@* ]] && target="$SSH_USER@$host"
  echo "== $host ($os) =="

  if [[ "$MODE" == "check" ]]; then
    ssh "$target" 'cd ~/homelab && ./lab check' || fail=1
    continue
  fi

  # push the repo (tar over ssh - no rsync needed on either end), then run its
  # setup script with this box's config
  if ! tar czf - --exclude=.git . | ssh "$target" 'mkdir -p ~/homelab && tar xzf - -C ~/homelab'; then
    echo "  copy failed - check SSH to $host (see README)" >&2; fail=1; continue
  fi
  role=--worker
  [[ "$os" == "mac" ]] && role=--worker-mac
  # -t gives sudo a tty so it can prompt for a password (interactive per host);
  # set up passwordless sudo on the workers to make this hands-off (see README)
  if ! ssh -t "$target" "cd ~/homelab && HEAD_IP='$HEAD_IP' RESOURCES='$res' $flags ./lab setup $role"; then
    echo "  setup failed on $host" >&2; fail=1
  fi
done

echo
[[ $fail -eq 0 ]] && echo "All hosts OK." || echo "Some hosts FAILED." >&2
exit $fail
