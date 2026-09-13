#!/bin/bash
# singlecore-test.sh
#
# 20 s of load pinned to one core (default cpu0, a P-core on Alder Lake).
# Single-core bursts concentrate the heat on one core and cause the short
# 95-100 C spikes that a package power limit alone does not prevent.
# Prints per-second temperatures and a summary (avg/max temp, watts, MHz, throttle time).
#
# Requires: root (RAPL energy counters are root-only), stress-ng
# Usage: singlecore-test.sh [label] [cpu]
set -u
export LC_ALL=C   # EPOCHREALTIME and awk must use "." as decimal separator

die() { echo "ERROR: $*" >&2; exit 1; }

LABEL="${1:-single}"; CPU="${2:-0}"; SECS=20
[[ "$LABEL" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "label may only contain letters, digits, '.', '_' and '-'"
[[ "$CPU" =~ ^(0|[1-9][0-9]{0,3})$ ]] || die "cpu must be a CPU number"
[ "$(id -u)" = 0 ] || die "must run as root"
command -v stress-ng >/dev/null || die "stress-ng not installed"

H=$(grep -lx 'coretemp' /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | xargs -r dirname)
T=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms
R=/sys/class/powercap/intel-rapl:0/energy_uj
FREQ=/sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_cur_freq
[ -n "$H" ] || die "coretemp sensor not found"
[ -r "$FREQ" ] || die "cpu$CPU not found"
[ -r "$R" ] || die "$R not readable"
[ -r "$T" ] || die "$T not readable"

t0=$(cat $T); e0=$(cat $R); ts0=$EPOCHREALTIME; sum=0; max=0; fsum=0; temps=""; n=$((SECS - 1))
stress-ng --cpu 1 --taskset "$CPU" --timeout "${SECS}s" --quiet &
SPID=$!
stop_load() { if [ -n "$SPID" ] && kill -0 "$SPID" 2>/dev/null; then kill "$SPID" 2>/dev/null; fi; }
trap stop_load EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for _ in $(seq $n); do
  sleep 1
  v=$(( $(cat "$H/temp1_input") / 1000 ))
  f=$(( $(cat "$FREQ") / 1000 ))
  sum=$((sum + v)); fsum=$((fsum + f)); [ $v -gt $max ] && max=$v
  temps="$temps $v"
done
e1=$(cat $R); ts1=$EPOCHREALTIME
wait "$SPID" 2>/dev/null; SPID=""
watts=$(awk -v a="$e0" -v b="$e1" -v t0="$ts0" -v t1="$ts1" 'BEGIN { if (b < a || t1 <= t0) print "?"; else printf "%.1f", (b - a) / 1000000 / (t1 - t0) }')
echo "$LABEL single-core: temps:$temps"
echo "$LABEL single-core: avg $((sum / n))C max ${max}C avg ${watts}W avg $((fsum / n))MHz throttled $(( $(cat $T) - t0 ))ms"
