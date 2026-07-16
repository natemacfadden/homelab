#!/usr/bin/env bash
# Peek at the running distributed review: find the review task on its Ray
# worker and show just the engine's phase lines (which lens, verdict, etc.) -
# the Ray worker log is otherwise buried in internals.
#   watch.sh        one-shot snapshot
#   watch.sh -f     follow live
# Needs the raylab venv active (ray on PATH): source ~/raylab/venv/bin/activate
set -uo pipefail

FOLLOW=""
[ "${1:-}" = "-f" ] && FOLLOW="--follow"

read -r PID NODE < <(
  RAY_ADDRESS=auto ray list tasks --filter 'name=review' \
    --filter 'state=RUNNING' --detail --format json 2>/dev/null \
  | python -c "import json,sys;t=json.load(sys.stdin);print(t[0]['worker_pid'],t[0]['node_id']) if t else print('','')" 2>/dev/null
)

if [ -z "${PID:-}" ]; then
  echo "no running review task (it may have finished)."
  exit 0
fi

echo "== review on worker pid $PID =="
RAY_ADDRESS=auto ray logs worker --pid "$PID" --node-id "$NODE" --tail -1 $FOLLOW 2>/dev/null \
  | grep --line-buffered -aE \
    'starting|detect|review (start|done|FAILED)|reconciled|synthesis|VERDICT|flavor '
