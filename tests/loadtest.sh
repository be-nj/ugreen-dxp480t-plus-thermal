#!/bin/bash
# loadtest.sh
#
# Full CPU load on all threads for N seconds, then a cooldown phase.
# Samples once per second: CPU package temperature, package power (RAPL),
# accumulated package throttle time and, if an it87 hwmon device is present,
# fan RPM and PWM values. Writes a CSV and prints a summary.
#
# Requires: stress-ng, bc
# Usage: loadtest.sh [label] [load_seconds] [cooldown_seconds]
# Output directory: $LOADTEST_DIR (default /root/loadtests)
set -u
LABEL="${1:-test}"; LOAD="${2:-20}"; COOL="${3:-40}"
OUT_DIR="${LOADTEST_DIR:-/root/loadtests}"
OUT="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-$LABEL.csv"
mkdir -p "$OUT_DIR"

HW_CORE=$(grep -l '^coretemp$' /sys/class/hwmon/hwmon*/name | head -1 | xargs dirname)
HW_IT=$(grep -l '^it8' /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | xargs -r dirname)
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
THR=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms

fans() {
  [ -n "$HW_IT" ] || { echo ""; return; }
  local s="" f
  for f in "$HW_IT"/fan*_input; do [ -f "$f" ] && s="$s$(cat "$f")/"; done
  for f in "$HW_IT"/pwm[0-9]; do [ -f "$f" ] && s="$s p$(cat "$f")"; done
  echo "$s"
}

echo "t,phase,temp_c,watts,throttle_ms,fans" | tee "$OUT"
e0=$(cat $RAPL); th0=$(cat $THR)
stress-ng --cpu 0 --timeout "${LOAD}s" --quiet &
SPID=$!
trap 'kill $SPID 2>/dev/null' EXIT INT TERM
for t in $(seq 1 $((LOAD + COOL))); do
  sleep 1
  e1=$(cat $RAPL); th1=$(cat $THR)
  phase=load; [ "$t" -gt "$LOAD" ] && phase=cool
  printf "%d,%s,%d,%.1f,%d,%s\n" "$t" "$phase" $(( $(cat "$HW_CORE/temp1_input") / 1000 )) \
    "$(echo "($e1-$e0)/1000000" | bc -l)" $((th1 - th0)) "$(fans)" | tee -a "$OUT"
  e0=$e1
done
wait $SPID 2>/dev/null
echo "saved: $OUT"
awk -F, 'NR>1 && $2=="load"{n++; s+=$3; if($3>m)m=$3; w+=$4} NR>1{th=$5} END{printf "load: avg %.1fC max %dC avg %.1fW | throttled total %d ms\n", s/n, m, w/n, th}' "$OUT"
awk -F, 'NR>1 && $2=="cool"{last=$3} END{print "temp at end of cooldown: " last "C"}' "$OUT"
