#!/bin/bash
# singlecore-test.sh
#
# 20 s of load pinned to one core (default cpu0, a P-core on Alder Lake).
# Single-core bursts concentrate the heat on one core and cause the short
# 95-100 C spikes that a package power limit alone does not prevent.
# Prints per-second temperatures and a summary (avg/max temp, watts, MHz, throttle time).
#
# Requires: stress-ng
# Usage: singlecore-test.sh [label] [cpu]
set -u
LABEL="${1:-single}"; CPU="${2:-0}"; SECS=20
H=$(grep -l '^coretemp$' /sys/class/hwmon/hwmon*/name | head -1 | xargs dirname)
T=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms
R=/sys/class/powercap/intel-rapl:0/energy_uj
FREQ=/sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_cur_freq

t0=$(cat $T); e0=$(cat $R); sum=0; max=0; fsum=0; temps=""; n=$((SECS - 1))
stress-ng --cpu 1 --taskset "$CPU" --timeout "${SECS}s" --quiet &
SPID=$!
trap 'kill $SPID 2>/dev/null' EXIT INT TERM
for _ in $(seq $n); do
  sleep 1
  v=$(( $(cat "$H/temp1_input") / 1000 ))
  f=$(( $(cat "$FREQ") / 1000 ))
  sum=$((sum + v)); fsum=$((fsum + f)); [ $v -gt $max ] && max=$v
  temps="$temps $v"
done
e1=$(cat $R)
wait
echo "$LABEL single-core: temps:$temps"
echo "$LABEL single-core: avg $((sum / n))C max ${max}C avg $(( (e1 - e0) / (n * 1000000) ))W avg $((fsum / n))MHz throttled $(( $(cat $T) - t0 ))ms"
