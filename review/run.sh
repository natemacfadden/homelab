#!/usr/bin/env bash
# General runner for distributed reviews. Sets up env, then dispatches to
# driver.py - or manages the nightly cron / stops a run.
#
#   run.sh                one review, weighted pick (also what --nightly runs)
#   run.sh <repo>         review a specific repo once
#   run.sh --loop [N]     review continuously, stalest-first
#   run.sh --nightly      install a cron job: one review nightly at 3am
#   run.sh --stop         stop a running loop/review AND remove the nightly cron
#
# Run on the box with the repos + manifest + raylab venv (ray) + node.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/run.sh"
PIDFILE="${REVIEW_PIDFILE:-$HOME/github/repo-review-out/_cron/driver.pid}"
CRON_TAG="# homelab review nightly"
MODEL_URL="${REVIEW_MODEL_URL:-http://127.0.0.1:8000/v1/models}"
VENV="${RAYLAB_VENV:-$HOME/raylab/venv}"

case "${1:-}" in
  --nightly)
    line="0 3 * * * /bin/bash -lc '$SELF'"
    ( crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | grep -vF "$SELF"
      echo "$CRON_TAG"; echo "$line" ) | crontab -
    echo "scheduled nightly review: $line"
    exit 0 ;;
  --stop)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      kill -TERM "$(cat "$PIDFILE")" \
        && echo "sent graceful stop to running review (pid $(cat "$PIDFILE"))"
    else
      echo "no running review"
    fi
    if crontab -l 2>/dev/null | grep -qF "$SELF"; then
      crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | grep -vF "$SELF" | crontab -
      echo "removed nightly cron"
    else
      echo "no nightly cron scheduled"
    fi
    exit 0 ;;
esac

# --- run a review (single / specific / loop) --------------------------------
LOGDIR="$HOME/github/repo-review-out/_cron"
mkdir -p "$LOGDIR"
ts="$(date -u +%Y-%m-%dT%H%M%SZ)"

run_review() {
  echo "=== review $ts (args: $*) ==="
  if ! curl -sf -m 5 "$MODEL_URL" >/dev/null; then
    echo "model server not reachable at $MODEL_URL - skipping this run"
    return 0
  fi
  [ -f "$VENV/bin/activate" ] && source "$VENV/bin/activate"
  REVIEW_PIDFILE="$PIDFILE" python "$HERE/driver.py" "$@"
}

# interactive -> live to the terminal (heartbeat); cron/redirected -> log file
if [ -t 1 ]; then
  run_review "$@"
else
  run_review "$@" >"$LOGDIR/$ts.log" 2>&1
fi
