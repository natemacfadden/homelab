#!/usr/bin/env bash
# Quick git sync report for every repo under a root (default ~/github).
# Fetches each remote first (skip with --no-fetch), then flags dirty working
# trees and ahead/behind vs upstream.
#   repos-status.sh [--no-fetch] [root]
set -uo pipefail

fetch=1
root="$HOME/github"
for a in "$@"; do
  case "$a" in
    --no-fetch) fetch=0 ;;
    *) root="$a" ;;
  esac
done

printf '%-18s %-16s %-10s %s\n' REPO BRANCH TREE REMOTE
printf '%-18s %-16s %-10s %s\n' ------ ------ ---- ------
for d in "$root"/*/; do
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  name=$(basename "$d")
  [ "$fetch" = 1 ] && timeout 20 git -C "$d" fetch -q 2>/dev/null
  branch=$(git -C "$d" symbolic-ref --short -q HEAD || echo '(detached)')
  n=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  tree=$([ "$n" -eq 0 ] && echo clean || echo "dirty:$n")
  if ab=$(git -C "$d" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    behind=$(echo "$ab" | awk '{print $1}')
    ahead=$(echo "$ab" | awk '{print $2}')
    if [ "$ahead" = 0 ] && [ "$behind" = 0 ]; then
      remote='up-to-date'
    else
      remote="ahead:$ahead behind:$behind"
    fi
  else
    remote='no upstream'
  fi
  printf '%-18s %-16s %-10s %s\n' "$name" "$branch" "$tree" "$remote"
done
