#!/bin/bash
# cpu-thermal-limits.sh
#
# Keeps an Intel CPU cool by capping package power (RAPL PL1/PL2) and the
# maximum CPU frequency. Written for a UGREEN DXP480T Plus (i5-1235U) running
# Proxmox VE, where the firmware defaults (25 W / 55 W, 4.4 GHz) push the CPU
# to 100 C and into constant thermal throttling.
#
# Settings are parsed (not sourced) from /etc/default/cpu-thermal-limits:
#   POWER_LIMIT_W=15     package power limit in watts (PL1 and PL2), empty = leave untouched
#   MAX_FREQ_MHZ=3000    max frequency per core in MHz, empty = leave untouched
#
# Usage:
#   cpu-thermal-limits.sh apply     apply configured limits (default)
#   cpu-thermal-limits.sh reset     restore hardware max frequency and the power limits saved on first apply
#   cpu-thermal-limits.sh status    show current limits

set -eu

CONFIG=/etc/default/cpu-thermal-limits
STATE_DIR=/var/lib/cpu-thermal-limits
RAPL_DOMAINS="/sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0"

POWER_LIMIT_W=15
MAX_FREQ_MHZ=3000

# Sanity bounds: refuse values that would make the machine unusable.
POWER_MIN_W=5;    POWER_MAX_W=65
FREQ_MIN_MHZ=800; FREQ_MAX_MHZ=6000

log() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Read the config without sourcing it: only the two known keys are accepted,
# so the file cannot execute code as root.
read_config() {
    [ -f "$CONFIG" ] || return 0
    local owner mode key value
    owner=$(stat -c %u "$CONFIG"); mode=$(stat -c %a "$CONFIG")
    [ "$owner" = 0 ] || die "$CONFIG must be owned by root"
    [ $(( 8#$mode & 8#022 )) = 0 ] || die "$CONFIG must not be writable by group or others"
    while IFS='=' read -r key value; do
        key="${key//[[:space:]]/}"
        value="${value%%#*}"; value="${value//[[:space:]]/}"; value="${value//\"/}"
        case "$key" in
            ''|\#*) ;;
            POWER_LIMIT_W) POWER_LIMIT_W="$value" ;;
            MAX_FREQ_MHZ)  MAX_FREQ_MHZ="$value" ;;
            *) log "WARN: ignoring unknown key '$key' in $CONFIG" ;;
        esac
    done < "$CONFIG"
}

validate() {
    if [ -n "$POWER_LIMIT_W" ]; then
        [[ "$POWER_LIMIT_W" =~ ^[0-9]+$ ]] || die "POWER_LIMIT_W must be an integer, got '$POWER_LIMIT_W'"
        [ "$POWER_LIMIT_W" -ge "$POWER_MIN_W" ] && [ "$POWER_LIMIT_W" -le "$POWER_MAX_W" ] \
            || die "POWER_LIMIT_W must be between $POWER_MIN_W and $POWER_MAX_W"
    fi
    if [ -n "$MAX_FREQ_MHZ" ]; then
        [[ "$MAX_FREQ_MHZ" =~ ^[0-9]+$ ]] || die "MAX_FREQ_MHZ must be an integer, got '$MAX_FREQ_MHZ'"
        [ "$MAX_FREQ_MHZ" -ge "$FREQ_MIN_MHZ" ] && [ "$MAX_FREQ_MHZ" -le "$FREQ_MAX_MHZ" ] \
            || die "MAX_FREQ_MHZ must be between $FREQ_MIN_MHZ and $FREQ_MAX_MHZ"
    fi
}

[ "$(id -u)" = 0 ] || die "must run as root"
read_config
validate

wait_for_rapl() {
    # RAPL drivers are loaded by udev; wait up to 60 s for at least the MSR interface.
    local i
    for i in $(seq 60); do
        [ -d /sys/class/powercap/intel-rapl:0 ] && return 0
        sleep 1
    done
    return 1
}

save_firmware_defaults() {
    # Remember the original power limits once, so "reset" can restore them.
    mkdir -p "$STATE_DIR"
    local d name c
    for d in $RAPL_DOMAINS; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        for c in 0 1; do
            [ -f "$STATE_DIR/$name-c$c" ] || cat "$d/constraint_${c}_power_limit_uw" > "$STATE_DIR/$name-c$c"
        done
    done
}

apply_power_limit() {
    [ -n "$POWER_LIMIT_W" ] || return 0
    local uw=$(( POWER_LIMIT_W * 1000000 )) d ok=0
    wait_for_rapl || { log "ERROR: RAPL interface not available"; return 1; }
    save_firmware_defaults
    for d in $RAPL_DOMAINS; do
        [ -d "$d" ] || continue
        echo "$uw" > "$d/constraint_0_power_limit_uw"
        echo "$uw" > "$d/constraint_1_power_limit_uw"
        if [ "$(cat "$d/constraint_0_power_limit_uw")" = "$uw" ] && [ "$(cat "$d/constraint_1_power_limit_uw")" = "$uw" ]; then
            ok=1
        else
            log "WARN: $d did not accept ${POWER_LIMIT_W} W"
        fi
    done
    [ "$ok" = 1 ] || { log "ERROR: power limit not applied"; return 1; }
    log "power limit: ${POWER_LIMIT_W} W"
}

apply_max_freq() {
    [ -n "$MAX_FREQ_MHZ" ] || return 0
    local khz=$(( MAX_FREQ_MHZ * 1000 )) c hw v bad=0
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        hw=$(cat "$c/cpuinfo_max_freq")
        v=$khz
        [ "$v" -gt "$hw" ] && v=$hw
        echo "$v" > "$c/scaling_max_freq"
        [ "$(cat "$c/scaling_max_freq")" = "$v" ] || bad=1
    done
    [ "$bad" = 0 ] || { log "ERROR: max frequency not applied on all cores"; return 1; }
    log "max frequency: ${MAX_FREQ_MHZ} MHz"
}

reset_limits() {
    local c d name
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        cat "$c/cpuinfo_max_freq" > "$c/scaling_max_freq"
    done
    for d in $RAPL_DOMAINS; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        [ -f "$STATE_DIR/$name-c0" ] && cat "$STATE_DIR/$name-c0" > "$d/constraint_0_power_limit_uw"
        [ -f "$STATE_DIR/$name-c1" ] && cat "$STATE_DIR/$name-c1" > "$d/constraint_1_power_limit_uw"
    done
    log "limits reset to hardware/firmware defaults"
}

show_status() {
    local d c
    for d in $RAPL_DOMAINS; do
        [ -d "$d" ] || continue
        echo "$d: PL1=$(( $(cat "$d/constraint_0_power_limit_uw") / 1000000 )) W PL2=$(( $(cat "$d/constraint_1_power_limit_uw") / 1000000 )) W"
    done
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        printf "%s: max %s MHz (hw %s MHz)\n" "$(basename "$c")" \
            $(( $(cat "$c/cpufreq/scaling_max_freq") / 1000 )) $(( $(cat "$c/cpufreq/cpuinfo_max_freq") / 1000 ))
    done | sort -V
}

case "${1:-apply}" in
    apply)  apply_power_limit; apply_max_freq ;;
    reset)  reset_limits ;;
    status) show_status ;;
    *)      echo "usage: $0 [apply|reset|status]" >&2; exit 2 ;;
esac
