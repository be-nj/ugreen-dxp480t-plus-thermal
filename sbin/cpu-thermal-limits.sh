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
    while IFS='=' read -r key value || [ -n "$key" ]; do
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

# check_int NAME VALUE MIN MAX: empty is allowed; otherwise a plain decimal
# integer without leading zeros (bash would read "015" as octal) within bounds.
check_int() {
    [ -n "$2" ] || return 0
    [[ "$2" =~ ^[1-9][0-9]{0,4}$ ]] || die "$1 must be a positive whole number (no sign, no leading zeros), got '$2'"
    [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || die "$1 must be between $3 and $4, got '$2'"
}

wait_for_rapl() {
    # RAPL drivers are loaded by udev; wait up to 60 s for both interfaces.
    # The MMIO interface does not exist on every platform, so only the MSR one is required.
    local i d missing
    for i in $(seq 60); do
        missing=0
        for d in $RAPL_DOMAINS; do [ -d "$d" ] || missing=1; done
        [ "$missing" = 0 ] && return 0
        sleep 1
    done
    [ -d /sys/class/powercap/intel-rapl:0 ]
}

save_firmware_defaults() {
    # Remember the original power limits once, so "reset" can restore them.
    mkdir -p "$STATE_DIR"
    local d name c
    for d in $RAPL_DOMAINS; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        for c in 0 1; do
            if [ ! -f "$STATE_DIR/$name-c$c" ]; then
                cat "$d/constraint_${c}_power_limit_uw" > "$STATE_DIR/$name-c$c"
            fi
        done
    done
}

apply_power_limit() {
    [ -n "$POWER_LIMIT_W" ] || return 0
    local uw=$(( POWER_LIMIT_W * 1000000 )) d ok=0
    if ! wait_for_rapl; then
        log "ERROR: RAPL interface not available"
        return 1
    fi
    save_firmware_defaults
    for d in $RAPL_DOMAINS; do
        [ -d "$d" ] || continue
        echo "$uw" > "$d/constraint_0_power_limit_uw" || true
        echo "$uw" > "$d/constraint_1_power_limit_uw" || true
        if [ "$(cat "$d/constraint_0_power_limit_uw")" = "$uw" ] && [ "$(cat "$d/constraint_1_power_limit_uw")" = "$uw" ]; then
            ok=1
        else
            log "WARN: $d did not accept ${POWER_LIMIT_W} W"
        fi
    done
    if [ "$ok" != 1 ]; then
        log "ERROR: power limit not applied"
        return 1
    fi
    log "power limit: ${POWER_LIMIT_W} W"
}

apply_max_freq() {
    [ -n "$MAX_FREQ_MHZ" ] || return 0
    local khz=$(( MAX_FREQ_MHZ * 1000 )) c hw v bad=0 found=0
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -f "$c/scaling_max_freq" ] || continue
        found=1
        hw=$(cat "$c/cpuinfo_max_freq")
        v=$khz
        if [ "$v" -gt "$hw" ]; then v=$hw; fi
        echo "$v" > "$c/scaling_max_freq" || true
        if [ "$(cat "$c/scaling_max_freq")" != "$v" ]; then bad=1; fi
    done
    if [ "$found" = 0 ]; then
        log "ERROR: no cpufreq interface found"
        return 1
    fi
    if [ "$bad" != 0 ]; then
        log "ERROR: max frequency not applied on all cores"
        return 1
    fi
    log "max frequency: ${MAX_FREQ_MHZ} MHz"
}

reset_limits() {
    local c d name i
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -f "$c/scaling_max_freq" ] || continue
        cat "$c/cpuinfo_max_freq" > "$c/scaling_max_freq" || true
    done
    for d in $RAPL_DOMAINS; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        for i in 0 1; do
            if [ -f "$STATE_DIR/$name-c$i" ]; then
                cat "$STATE_DIR/$name-c$i" > "$d/constraint_${i}_power_limit_uw" || true
            fi
        done
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
        [ -f "$c/cpufreq/scaling_max_freq" ] || continue
        printf "%s: max %s MHz (hw %s MHz)\n" "$(basename "$c")" \
            $(( $(cat "$c/cpufreq/scaling_max_freq") / 1000 )) $(( $(cat "$c/cpufreq/cpuinfo_max_freq") / 1000 ))
    done | sort -V
}

[ "$(id -u)" = 0 ] || die "must run as root"

case "${1:-apply}" in
    apply)
        read_config
        check_int POWER_LIMIT_W "$POWER_LIMIT_W" "$POWER_MIN_W" "$POWER_MAX_W"
        check_int MAX_FREQ_MHZ "$MAX_FREQ_MHZ" "$FREQ_MIN_MHZ" "$FREQ_MAX_MHZ"
        # Try both limits even if one fails, then report failure.
        rc=0
        apply_power_limit || rc=1
        apply_max_freq || rc=1
        exit "$rc"
        ;;
    reset)  reset_limits ;;
    status) show_status ;;
    *)      echo "usage: $0 [apply|reset|status]" >&2; exit 2 ;;
esac
