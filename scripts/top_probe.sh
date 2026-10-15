# Sent over ssh by scripts/top.sh and run on each box with bash (3.2 on the
# Mac, so nothing newer). Prints key=value lines and one 'gpu=' line per GPU:
#   gpu=<name>, <util%>, <used MiB>, <total MiB>, <temp C>, <power W>
#   disk=<mount>, <used KiB>, <size KiB>      one per real filesystem
#   io=<read KiB/s> <write KiB/s>             all physical disks, Linux only
# A field the box can't report is '-'.

if [ "$(uname)" = Darwin ]; then
  # second sample; the first covers time since boot
  echo "cpu=$(top -l 2 -n 0 -s 1 | awk '/CPU usage/ { u = $3 + $5 } END { printf "%d", u }')"
  echo "load=$(sysctl -n vm.loadavg | awk '{ print $2 }')"
  echo "ncpu=$(sysctl -n hw.ncpu)"
  total=$(sysctl -n hw.memsize)
  free=$(memory_pressure | awk '/free percentage/ { sub("%", "", $5); print $5 }')
  echo "mem=$(awk -v t="$total" -v f="$free" 'BEGIN { printf "%d %d", t * (100 - f) / 100 / 1048576, t / 1048576 }')"
  # the APFS data volume is where everything but the sealed OS lives
  df -Pk /System/Volumes/Data | awk 'NR > 1 { printf "disk=/, %d, %d\n", $3, $3 + $4 }'
  exit 0
fi

# sectors read/written across whole disks (not partitions, loops, or dm)
diskio() {
  awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|mmcblk[0-9]+)$/ { r += $6; w += $10 }
       END { printf "%d %d", r, w }' /proc/diskstats
}
read -r _ a b c d e f g h _ < /proc/stat; t1=$((a+b+c+d+e+f+g+h)); i1=$((d+e))
read -r r1 w1 < <(diskio)
sleep 1
read -r _ a b c d e f g h _ < /proc/stat; t2=$((a+b+c+d+e+f+g+h)); i2=$((d+e))
read -r r2 w2 < <(diskio)
echo "io=$(( (r2 - r1) / 2 )) $(( (w2 - w1) / 2 ))"   # 512-byte sectors over 1s
dt=$((t2 - t1)); [ "$dt" -gt 0 ] || dt=1
echo "cpu=$(( 100 * (dt - (i2 - i1)) / dt ))"
echo "load=$(cut -d' ' -f1 /proc/loadavg)"
echo "ncpu=$(nproc)"
echo "mem=$(awk '/MemTotal/ { t = $2 } /MemAvailable/ { a = $2 } END { printf "%d %d", (t - a) / 1024, t / 1024 }' /proc/meminfo)"
# size is used + available, so root's reserved blocks don't read as free space
df -Pk 2>/dev/null | awk 'NR > 1 && $1 ~ /^\/dev\// && $6 !~ /^\/boot/ && !seen[$1]++ {
  printf "disk=%s, %d, %d\n", $6, $3, $3 + $4 }'

# nvidia-smi can be installed with no driver loaded (compute03), hence -L
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
    --format=csv,noheader,nounits | sed 's/NVIDIA GeForce //; s/^/gpu=/'
fi

for card in /sys/class/drm/card[0-9]*; do
  case "$card" in *-*) continue ;; esac   # connectors, e.g. card1-DP-1
  dev=$card/device
  [ -r "$dev/gpu_busy_percent" ] || continue
  mib() { echo $(( $(cat "$dev/$1" 2>/dev/null || echo 0) / 1048576 )); }
  used=$(mib mem_info_vram_used); total=$(mib mem_info_vram_total)
  # an APU's VRAM is a small carve-out and the real allocations live in GTT
  if [ "$total" -lt 4096 ]; then
    used=$((used + $(mib mem_info_gtt_used))); total=$((total + $(mib mem_info_gtt_total)))
  fi
  # a runtime-suspended GPU answers EBUSY to every sensor; don't wake it
  if [ "$(cat "$dev/power/runtime_status" 2>/dev/null)" = suspended ]; then
    util=sleep; temp=-; pw=-
  else
    util=$(cat "$dev/gpu_busy_percent" 2>/dev/null || echo -)
    hw=$(ls -d "$dev"/hwmon/hwmon* 2>/dev/null | head -n1)
    temp=$(cat "$hw/temp1_input" 2>/dev/null) && temp=$((temp / 1000)) || temp=-
    pw=$(cat "$hw/power1_average" 2>/dev/null || cat "$hw/power1_input" 2>/dev/null) \
      && pw=$((pw / 1000000)) || pw=-
  fi
  # codename from lspci, e.g. "Navi 22", "Strix Halo"
  name=$(lspci -s "$(basename "$(readlink -f "$dev")")" 2>/dev/null \
    | sed -n 's/.*\[AMD\/ATI\] \([^[]*\) \[.*/\1/p')
  echo "gpu=AMD ${name:-GPU}, $util, $used, $total, $temp, $pw"
done
