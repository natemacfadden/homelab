#!/usr/bin/env bash
# Track which reviews you've read/handled. State lives in a .status file inside
# each review dir (absent = new); this only reads dirs and writes tiny status
# files in COMPLETED reviews, so it never touches the running review loop.
#
#   reviews.sh [list]      inbox: every review + status, newest first
#   reviews.sh new         only reviews still marked new
#   reviews.sh mark <repo/stamp> <read|handled> ["note"]   (or <repo> <stamp> ...)
#   reviews.sh show <repo/stamp>      print the MEMO
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
scores_of() {
  # Overall + per-axis (P/C/E/T/D/H, rounded) from the reconciled-scores table.
  # Score is column 2 of each "| Axis | score | range |" row; Overall is bolded.
  awk '
    /^##+.*[Rr]econciled [Ss]cores/ { intbl=1; next }
    intbl && (/^---/ || /^##/) { exit }
    intbl && /^\|/ {
      split($0, c, "|"); axis=c[2]; score=c[3]
      gsub(/[ *]/, "", axis); gsub(/[ *]/, "", score)
      if (axis == "" || score == "" || axis == "Axis" || score ~ /^-+$/) next
      if (axis ~ /[Oo]verall/) { overall=score; next }
      val[++k]=score
    }
    END {
      if (overall == "") overall="?"
      s=""; for (i=1;i<=k;i++) s=s (i>1?"/":"") sprintf("%d", val[i]+0.5)
      printf "%s %s", overall, (s=="" ? "-" : s)
    }
  ' "$1/MEMO.md" 2>/dev/null
}

cmd="${1:-list}"
case "$cmd" in
  mark)
    # accept "repo/stamp state [note]" or "repo stamp state [note]"
    if [[ "${2:-}" == */* ]]; then
      repo="${2%/*}"; stamp="${2##*/}"; state="${3:?read|handled}"; note="${*:4}"
    else
      repo="${2:?repo}"; stamp="${3:?stamp}"; state="${4:?read|handled}"; note="${*:5}"
    fi
    dir="$ARCHIVE/$repo/$stamp"
    [ -d "$dir" ] || { echo "no such review: $dir" >&2; exit 1; }
    case "$state" in read|handled|new) ;; *)
      echo "state must be new|read|handled" >&2; exit 1 ;; esac
    printf '%s %s %s\n' "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$note" \
      > "$dir/.status"
    echo "$repo/$stamp -> $state${note:+  ($note)}"
    ;;
  list|new)
    printf '%-8s %-32s %-6s %-14s %s\n' \
      STATUS REPO/REVIEW SCORE P/C/E/T/D/H VERDICT
    find "$ARCHIVE" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | while read -r d; do
      [ -f "$d/MEMO.md" ] || continue
      st=$(status_of "$d")
      [ "$cmd" = new ] && [ "$st" != new ] && continue
      repo=$(basename "$(dirname "$d")"); stamp=$(basename "$d")
      sc=$(scores_of "$d"); overall=${sc%% *}; cluster=${sc#* }
      # lead with the stamp as a hidden sort key -> newest first, then strip it
      printf '%s\t%-8s %-32s %-6s %-14s %s\n' \
        "$stamp" "$st" "$repo/$stamp" "$overall" "$cluster" "$(verdict_of "$d")"
    done | sort -r | cut -f2-
    ;;
  show)
    if [[ "${2:-}" == */* ]]; then repo="${2%/*}"; stamp="${2##*/}"
    else repo="${2:?repo}"; stamp="${3:?stamp}"; fi
    cat "$ARCHIVE/$repo/$stamp/MEMO.md"
    ;;
  *)
    echo "usage: reviews.sh [list|new|mark <repo/stamp> <read|handled> [note]|show <repo/stamp>]" >&2
    exit 1 ;;
esac
