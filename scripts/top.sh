#!/usr/bin/env bash
#
# live utilization dashboard for the whole fleet, nvtop-style: CPU, load, RAM,
# disks (usage per filesystem, read/write rate), and every GPU (util, memory,
# temp, power), fetched over SSH in parallel:
#
#   ./lab top                  live, refreshing every 2s; q or Ctrl-C quits
#   ./lab top -n 5             refresh every 5s
#   ./lab top --once           print one snapshot and exit (pipeable, no color)
#
# Needs nothing installed on the boxes and doesn't depend on the head or
# Prometheus being up. Hosts are head01 plus the WORKERS list in
# scripts/deploy.sh; this box is read locally. A box that doesn't answer within
# a few seconds shows as offline.
#
# GPUs: NVIDIA via nvidia-smi, AMD via sysfs (memory is VRAM + GTT, so the
# Strix Halo's unified memory counts). Apple GPUs need sudo powermetrics, so the
# Mac shows CPU and RAM only.
#
# env:
#   HOSTS      space-separated override of the host list
#   HEAD_HOST  the head's name (default head01)
#
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PROBE=top_probe.sh   # runs on each box; see its header for the output format

hosts() {
  if [[ -n "${HOSTS:-}" ]]; then printf '%s\n' $HOSTS; return; fi
  echo "${HEAD_HOST:-head01}"
  # host column of the uncommented rows in deploy.sh's WORKERS=( ... )
  sed -n '/^WORKERS=(/,/^)/p' deploy.sh | grep -E '^\s*"' \
    | sed -E 's/^\s*"\s*([^ |]+).*/\1/'
}

# reuse one SSH connection per box across refreshes, so a frame costs ~1s of
# sampling rather than a fresh handshake to every box
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=3
          -o ControlMaster=auto -o ControlPersist=60
          -o "ControlPath=${XDG_RUNTIME_DIR:-/tmp}/labtop-%r@%h:%p")

probe() {
  local host=$1 short=${1#*@}
  if [[ "$short" == "$(hostname -s)" ]]; then
    bash "$PROBE"
  else
    ssh "${SSH_OPTS[@]}" "$host" "bash -s" <"$PROBE"
  fi
}

# colors only on a terminal
if [[ -t 1 ]]; then
  B=$'\e[1m' DIM=$'\e[2m' R=$'\e[0m' RED=$'\e[31m' YEL=$'\e[33m' GRN=$'\e[32m' CYN=$'\e[36m'
else
  B= DIM= R= RED= YEL= GRN= CYN=
fi
BAR=20

gib() { awk -v m="$1" 'BEGIN { printf "%.1f", m / 1024 }'; }
trim() { echo $1; }
isnum() { [[ "$1" =~ ^[0-9.]+$ ]]; }

# bar <percent>: a colored [####----] gauge; non-numbers give an empty gauge
bar() {
  local p=$1 n c fill
  if ! isnum "$p"; then printf '[%*s]' $BAR ''; return; fi
  p=${p%.*}; (( p > 100 )) && p=100
  n=$(( p * BAR / 100 ))
  if (( p >= 80 )); then c=$RED; elif (( p >= 50 )); then c=$YEL; else c=$GRN; fi
  printf -v fill '%*s' $n ''; fill=${fill// /█}
  printf '[%s%s%s%s%*s%s]' "$c" "$fill" "$R" "$DIM" $((BAR - n)) '' "$R" | sed "s/ /·/g"
}

pct() { awk -v u="$1" -v t="$2" 'BEGIN { printf "%d", (t > 0) ? 100 * u / t : 0 }'; }
# KiB -> human, e.g. 1.2T / 640G / 87M
human() { awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1
  while (k >= 1024 && i < 4) { k /= 1024; i++ }
  printf (k < 10 ? "%.1f%s" : "%.0f%s"), k, u[i] }'; }
unit() { isnum "$1" && printf '%.0f%s' "$1" "$2" || printf '%s' "$1"; }

render() {
  local dir=$1 host short out
  while read -r host; do
    short=${host#*@}
    out="$dir/$short"
    if [[ ! -s "$out" ]] || ! grep -q '^cpu=' "$out"; then
      printf '%s%-16s%s %soffline%s\n\n' "$B" "$short" "$R" "$RED" "$R"
      continue
    fi
    local cpu load ncpu used total
    cpu=$(sed -n 's/^cpu=//p' "$out"); load=$(sed -n 's/^load=//p' "$out")
    ncpu=$(sed -n 's/^ncpu=//p' "$out")
    read -r used total < <(sed -n 's/^mem=//p' "$out")
    printf '%s%-16s%s CPU %s %4s%%  load %s/%s\n' "$B" "$short" "$R" \
      "$(bar "$cpu")" "$cpu" "$load" "$ncpu"
    printf '%-16s RAM %s %4s%%  %s/%s GiB\n' "" \
      "$(bar "$(pct "$used" "$total")")" "$(pct "$used" "$total")" "$(gib "$used")" "$(gib "$total")"
    local mnt du dt io rd wr
    while IFS=',' read -r mnt du dt; do
      [[ -z "$mnt" ]] && continue
      printf '%-16s DSK %s %4s%%  %s/%s  %s%s%s\n' "" "$(bar "$(pct "$du" "$dt")")" \
        "$(pct "$du" "$dt")" "$(human "$du")" "$(human "$dt")" "$DIM" "$mnt" "$R"
    done < <(sed -n 's/^disk=//p' "$out")
    io=$(sed -n 's/^io=//p' "$out")
    if [[ -n "$io" ]]; then
      read -r rd wr <<<"$io"
      printf '%-16s I/O read %s/s  write %s/s\n' "" "$(human "$rd")" "$(human "$wr")"
    fi
    local name util gu gt temp pw
    while IFS=',' read -r name util gu gt temp pw; do
      [[ -z "$name" ]] && continue
      util=$(trim "$util"); temp=$(trim "$temp"); pw=$(trim "$pw")
      printf '  %s%-14.14s%s GPU %s %5s   VRAM %s %s/%s GiB  %5s %5s\n' "$CYN" "$(trim "$name")" "$R" \
        "$(bar "$util")" "$(unit "$util" %)" "$(bar "$(pct "$gu" "$gt")")" \
        "$(gib "$gu")" "$(gib "$gt")" "$(unit "$temp" C)" "$(unit "$pw" W)"
    done < <(sed -n 's/^gpu=//p' "$out")
    echo
  done < <(hosts)
}

snapshot() {
  local dir host
  dir=$(mktemp -d)
  while read -r host; do
    probe "$host" >"$dir/${host#*@}" 2>/dev/null &
  done < <(hosts)
  wait
  render "$dir"
  rm -rf "$dir"
}

every=2 once=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) once=1 ;;
    -n) every=$2; shift ;;
    *) echo "unknown option '$1' (see ./lab top --help)" >&2; exit 1 ;;
  esac
  shift
done

if (( once )) || [[ ! -t 1 ]]; then
  snapshot
  exit
fi

# alternate screen, hidden cursor; put the terminal back however we exit
tput smcup; tput civis
trap 'tput cnorm; tput rmcup' EXIT
trap 'exit 0' INT TERM
while :; do
  frame=$(snapshot)
  printf '\e[H\e[J%s%s%s  every %ss  %sq to quit%s\n\n%s\n' \
    "$B" "$(date +%T)" "$R" "$every" "$DIM" "$R" "$frame"
  # sleep that also wakes on q
  if read -rsn1 -t "$every" key && [[ "$key" == q ]]; then exit 0; fi
done
