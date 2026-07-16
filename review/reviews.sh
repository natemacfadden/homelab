#!/usr/bin/env bash
# Track which reviews you've read/handled. State lives in a .status file inside
# each review dir (absent = new); this only reads dirs and writes tiny status
# files in COMPLETED reviews, so it never touches the running review loop.
#
#   reviews.sh [list]      inbox: every review + status, newest first
#   reviews.sh new         only reviews still marked new
#   reviews.sh mark <repo> <stamp> <read|handled> ["note"]
#   reviews.sh show <repo> <stamp>    print the MEMO
set -uo pipefail
ARCHIVE="${REVIEW_ARCHIVE:-$HOME/github/repo-review-out}"

status_of() {
  local f="$1/.status"
  if [ -f "$f" ]; then head -1 "$f" | awk '{print $1}'; else echo new; fi
}
verdict_of() {
  # first **bold** at or after the Verdict heading - handles both
  # "## Verdict: **Hire**" and "## Verdict" + a bolded verdict in the next para.
  awk '
    /^#+[[:space:]]*[Vv]erdict/ { grab = 1 }
    grab && match($0, /\*\*[^*]+\*\*/) {
      print substr($0, RSTART + 2, RLENGTH - 4); exit
    }
  ' "$1/MEMO.md" 2>/dev/null | cut -c1-32
}

cmd="${1:-list}"
case "$cmd" in
  mark)
    repo="${2:?repo}"; stamp="${3:?stamp}"; state="${4:?read|handled}"
    note="${*:5}"
    dir="$ARCHIVE/$repo/$stamp"
    [ -d "$dir" ] || { echo "no such review: $dir" >&2; exit 1; }
    case "$state" in read|handled|new) ;; *)
      echo "state must be new|read|handled" >&2; exit 1 ;; esac
    printf '%s %s %s\n' "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$note" \
      > "$dir/.status"
    echo "$repo/$stamp -> $state${note:+  ($note)}"
    ;;
  list|new)
    printf '%-8s %-16s %-20s %s\n' STATUS REPO REVIEW VERDICT
    find "$ARCHIVE" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | while read -r d; do
      [ -f "$d/MEMO.md" ] || continue
      st=$(status_of "$d")
      [ "$cmd" = new ] && [ "$st" != new ] && continue
      printf '%-8s %-16s %-20s %s\n' \
        "$st" "$(basename "$(dirname "$d")")" "$(basename "$d")" "$(verdict_of "$d")"
    done | sort -k3 -r
    ;;
  show)
    repo="${2:?repo}"; stamp="${3:?stamp}"
    cat "$ARCHIVE/$repo/$stamp/MEMO.md"
    ;;
  *)
    echo "usage: reviews.sh [list|new|mark <repo> <stamp> <read|handled> [note]|show <repo> <stamp>]" >&2
    exit 1 ;;
esac
