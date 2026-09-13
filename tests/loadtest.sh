#!/bin/bash
# loadtest.sh
#
# Full CPU load on all threads for N seconds, then a cooldown phase.
# Samples once per second: CPU package temperature, package power (RAPL),
# accumulated package throttle time and, if an it87 hwmon device is present,
# fan RPM and PWM values. Writes a CSV and prints a summary.
#
# Requires: root (RAPL energy counters are root-only), stress-ng
# Usage: loadtest.sh [label] [load_seconds] [cooldown_seconds]
# Output directory: $LOADTEST_DIR (default /root/loadtests)
set -u

die() { echo "ERROR: $*" >&2; exit 1; }

LABEL="${1:-test}"; LOAD="${2:-20}"; COOL="${3:-40}"
[[ "$LABEL" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "label may only contain letters, digits, '.', '_' and '-'"
[[ "$LOAD" =~ ^[1-9][0-9]{0,2}$ ]] || die "load_seconds must be 1-999"
[[ "$COOL" =~ ^(0|[1-9][0-9]{0,2})$ ]] || die "cooldown_seconds must be 0-999"
[ "$(id -u)" = 0 ] || die "must run as root"
command -v stress-ng >/dev/null || die "stress-ng not installed"

HW_CORE=$(grep -lx 'coretemp' /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | xargs -r dirname)
HW_IT=$(grep -l '^it8' /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | xargs -r dirname)
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
THR=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms
[ -n "$HW_CORE" ] || die "coretemp sensor not found"
[ -r "$RAPL" ] || die "$RAPL not readable"
[ -r "$THR" ] || die "$THR not readable"

OUT_DIR="${LOADTEST_DIR:-/root/loadtests}"
OUT="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-$LABEL.csv"
mkdir -p "$OUT_DIR"

fans() {
  [ -n "$HW_IT" ] || return 0
  local s="" f
  for f in "$HW_IT"/fan*_input; do [ -f "$f" ] && s="$s$(cat "$f")/"; done
  for f in "$HW_IT"/pwm[0-9]; do [ -f "$f" ] && s="$s p$(cat "$f")"; done
  echo "$s"
}

echo "t,phase,temp_c,watts,throttle_ms,fans" | tee "$OUT"
e0=$(cat $RAPL); th0=$(cat $THR)
stress-ng --cpu 0 --timeout "${LOAD}s" --quiet &
SPID=$!
trap 'kill $SPID 2>/dev/null' EXIT
trap 'exit 130' INT TERM
for t in $(seq 1 $((LOAD + COOL))); do
  sleep 1
  e1=$(cat $RAPL); th1=$(cat $THR)
  phase=load; [ "$t" -gt "$LOAD" ] && phase=cool
  # The energy counter wraps around; skip the sample instead of printing a negative value.
  watts=$(awk -v a="$e0" -v b="$e1" 'BEGIN { if (b < a) print ""; else printf "%.1f", (b - a) / 1000000 }')
  printf "%d,%s,%d,%s,%d,%s\n" "$t" "$phase" $(( $(cat "$HW_CORE/temp1_input") / 1000 )) \
    "$watts" $((th1 - th0)) "$(fans)" | tee -a "$OUT"
  e0=$e1
done
wait $SPID 2>/dev/null
echo "saved: $OUT"
awk -F, 'NR>1 && $2=="load"{n++; s+=$3; if($3>m)m=$3; if($4!=""){w+=$4; wn++}} NR>1{th=$5}
  END{printf "load: avg %.1fC max %dC avg %.1fW | throttled total %d ms\n", s/n, m, (wn ? w/wn : 0), th}' "$OUT"
awk -F, 'NR>1{last=$3} END{print "temp at end of test: " last "C"}' "$OUT"
