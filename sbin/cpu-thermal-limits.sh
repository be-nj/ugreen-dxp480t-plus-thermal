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
#   cpu-thermal-limits.sh apply       apply configured limits (default); only changed values are written and logged
#   cpu-thermal-limits.sh reset       restore the values saved before the first apply in this boot
#   cpu-thermal-limits.sh check       validate the config without changing anything
#   cpu-thermal-limits.sh wait-rapl   wait up to 60 s for the RAPL interface if a power limit is configured (ExecStartPre)
#   cpu-thermal-limits.sh status      show current limits

set -eu

CONFIG=/etc/default/cpu-thermal-limits
# Original values are kept in /run, so every normal boot records the firmware
# values afresh (a BIOS update may change them).
RUN_DIR=/run/cpu-thermal-limits
STATE_DIR=$RUN_DIR/saved
RAPL_MSR=/sys/class/powercap/intel-rapl:0
RAPL_MMIO=/sys/class/powercap/intel-rapl-mmio:0

POWER_LIMIT_W=15
MAX_FREQ_MHZ=3000

# Sanity bounds: refuse values that would make the machine unusable.
POWER_MIN_W=5;    POWER_MAX_W=65
FREQ_MIN_MHZ=800; FREQ_MAX_MHZ=6000

log() { echo "$*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Read a sysfs value that must be an unsigned integer; prints nothing and fails otherwise.
read_uint() {
    local v
    v=$(cat "$1" 2>/dev/null) || return 1
    is_uint "$v" || return 1
    echo "$v"
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Read the config without sourcing it, so the file cannot execute code as root.
# Strict on purpose: any line that is not empty, a comment or one of the two
# known keys stops the script, instead of silently falling back to defaults.
read_config() {
    [ -e "$CONFIG" ] || return 0
    [ ! -L "$CONFIG" ] || die "$CONFIG must not be a symlink"
    [ -f "$CONFIG" ] || die "$CONFIG is not a regular file"
    local owner mode line key value n=0 seen=" "
    owner=$(stat -c %u "$CONFIG"); mode=$(stat -c %a "$CONFIG")
    [ "$owner" = 0 ] || die "$CONFIG must be owned by root"
    [ $(( 8#$mode & 8#022 )) = 0 ] || die "$CONFIG must not be writable by group or others"

    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [ "$n" = 1 ] && line="${line#$'\xEF\xBB\xBF'}"       # UTF-8 BOM
        line="${line%$'\r'}"                                 # CRLF
        line="${line#"${line%%[![:space:]]*}"}"              # leading whitespace
        line="${line%"${line##*[![:space:]]}"}"              # trailing whitespace
        case "$line" in ''|\#*) continue ;; esac
        line="${line#export }"
        [[ "$line" == *=* ]] || die "$CONFIG line $n: expected KEY=VALUE"
        key="${line%%=*}"; value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
        case "$key" in
            POWER_LIMIT_W|MAX_FREQ_MHZ) ;;
            *) die "$CONFIG line $n: unknown key '$key'" ;;
        esac
        [[ "$seen" != *" $key "* ]] || die "$CONFIG line $n: duplicate key '$key'"
        seen="$seen$key "
        printf -v "$key" '%s' "$value"
    done < "$CONFIG"
}

# check_int NAME VALUE MIN MAX: empty is allowed; otherwise a plain decimal
# integer without leading zeros (bash would read "015" as octal) within bounds.
check_int() {
    [ -n "$2" ] || return 0
    [[ "$2" =~ ^[1-9][0-9]{0,4}$ ]] || die "$1 must be a positive whole number (no sign, no spaces, no leading zeros), got '$2'"
    [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || die "$1 must be between $3 and $4, got '$2'"
}

# ---------------------------------------------------------------------------
# Saved original values (written once, before the first change)
# ---------------------------------------------------------------------------

# save_once NAME SOURCE_FILE: store the integer in SOURCE_FILE as $STATE_DIR/NAME,
# unless something was saved already (never overwrite an original with a value
# that may already be capped). Written atomically.
save_once() {
    local dst="$STATE_DIR/$1" v
    [ -e "$dst" ] && return 0
    v=$(read_uint "$2") || { warn "cannot read $2"; return 1; }
    { mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"; } || return 1
    printf '%s\n' "$v" > "$dst.tmp" && mv -f "$dst.tmp" "$dst" || { warn "cannot write $dst"; return 1; }
}

# restore NAME TARGET_FILE: write the saved value back. Fails if nothing valid was saved.
restore() {
    local src="$STATE_DIR/$1" v
    [ -f "$src" ] || return 2
    v=$(read_uint "$src") || { warn "saved value $src is invalid"; return 1; }
    write_value "$v" "$2"
    [ "$(cat "$2" 2>/dev/null)" = "$v" ] || { warn "could not restore $2"; return 1; }
}

rapl_domains() {
    local d
    for d in "$RAPL_MSR" "$RAPL_MMIO"; do [ -d "$d" ] && echo "$d"; done
    return 0
}

# cpufreq directories of online CPUs. An offline CPU keeps its cpufreq link, but
# reads and writes fail with EBUSY, so it is skipped.
cpufreq_dirs() {
    local c online
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -f "$c/scaling_max_freq" ] || continue
        online="$(dirname "$c")/online"
        if [ -f "$online" ] && [ "$(cat "$online" 2>/dev/null)" = 0 ]; then continue; fi
        echo "$c"
    done
    return 0
}

# write_value VALUE FILE: write and report the kernel's error message (e.g. a
# read-only mount) instead of discarding it; the caller verifies by reading back.
write_value() {
    local err
    err=$( { printf '%s\n' "$1" > "$2"; } 2>&1 ) || warn "writing $2: ${err##*: }"
    return 0
}

# ---------------------------------------------------------------------------
# apply / reset / status
# ---------------------------------------------------------------------------

wait_for_rapl() {
    # RAPL drivers are loaded by udev. The MSR interface is required and may take
    # a while at boot; the MMIO interface is optional and gets a short grace period.
    # Under systemd this runs in ExecStartPre: the sandbox of ExecStart is built
    # afterwards, so directories that appear during the wait are writable there.
    for _ in $(seq 60); do
        [ -d "$RAPL_MSR" ] && break
        sleep 1
    done
    [ -d "$RAPL_MSR" ] || return 1
    for _ in 1 2 3 4 5; do
        [ -d "$RAPL_MMIO" ] && break
        sleep 1
    done
    return 0
}

# set_value FILE VALUE: write only if different. Sets CHANGED=1 when a write
# happened; returns 1 if the file does not hold VALUE afterwards.
CHANGED=0
set_value() {
    local cur
    cur=$(cat "$1" 2>/dev/null) || cur=""
    [ "$cur" = "$2" ] && return 0
    write_value "$2" "$1"
    CHANGED=1
    [ "$(cat "$1" 2>/dev/null)" = "$2" ]
}

# Fails only if no RAPL interface holds the limit afterwards (the lower of the
# two interfaces wins, so one is enough).
apply_power_limit() {
    [ -n "$POWER_LIMIT_W" ] || return 0
    local uw=$(( POWER_LIMIT_W * 1000000 )) d c ok=0
    [ -d "$RAPL_MSR" ] || { warn "RAPL interface $RAPL_MSR not available"; return 1; }
    for d in $(rapl_domains); do
        for c in 0 1; do
            save_once "$(basename "$d")-c$c" "$d/constraint_${c}_power_limit_uw" \
                || { warn "not changing $d: original value could not be saved"; continue 2; }
        done
        if set_value "$d/constraint_0_power_limit_uw" "$uw" && set_value "$d/constraint_1_power_limit_uw" "$uw"; then
            ok=1
        else
            warn "$d did not accept ${POWER_LIMIT_W} W"
        fi
    done
    [ "$ok" = 1 ] || { warn "power limit not applied"; return 1; }
}

# A core that refuses the value is only a warning, so a problem with the
# frequency cap never rolls back the (more important) power limit. Fails only
# if no core holds the cap.
apply_max_freq() {
    [ -n "$MAX_FREQ_MHZ" ] || return 0
    local khz=$(( MAX_FREQ_MHZ * 1000 )) c hw v ok=0
    for c in $(cpufreq_dirs); do
        save_once "$(basename "$(dirname "$c")")-max_freq" "$c/scaling_max_freq" || continue
        hw=$(read_uint "$c/cpuinfo_max_freq") || { warn "cannot read $c/cpuinfo_max_freq"; continue; }
        v=$khz
        if [ "$v" -gt "$hw" ]; then v=$hw; fi
        if set_value "$c/scaling_max_freq" "$v"; then ok=1; else warn "$c did not accept $v kHz"; fi
    done
    [ "$ok" = 1 ] || { warn "max frequency not applied on any core"; return 1; }
}

reset_limits() {
    local d c rc=0 restored=0 r
    for c in $(cpufreq_dirs); do
        r=0; restore "$(basename "$(dirname "$c")")-max_freq" "$c/scaling_max_freq" || r=$?
        case "$r" in 0) restored=1 ;; 1) rc=1 ;; esac
    done
    for d in $(rapl_domains); do
        for c in 0 1; do
            r=0; restore "$(basename "$d")-c$c" "$d/constraint_${c}_power_limit_uw" || r=$?
            case "$r" in 0) restored=1 ;; 1) rc=1 ;; esac
        done
    done
    if [ "$rc" != 0 ]; then
        warn "some values could not be restored"
        return 1
    fi
    if [ "$restored" = 0 ]; then
        log "nothing to restore (limits were never applied)"
    else
        log "limits restored to the values saved before the first apply"
    fi
}

show_status() {
    local d c v1 v2 cur hw
    for d in $(rapl_domains); do
        v1=$(read_uint "$d/constraint_0_power_limit_uw") || v1=""
        v2=$(read_uint "$d/constraint_1_power_limit_uw") || v2=""
        awk -v d="$d" -v a="$v1" -v b="$v2" 'function w(x) { return x == "" ? "n/a" : sprintf("%g W", x / 1000000) }
            BEGIN { printf "%s: PL1=%s PL2=%s\n", d, w(a), w(b) }'
    done
    for c in $(cpufreq_dirs); do
        cur=$(read_uint "$c/scaling_max_freq") && cur="$((cur / 1000)) MHz" || cur="n/a"
        hw=$(read_uint "$c/cpuinfo_max_freq") && hw="$((hw / 1000)) MHz" || hw="n/a"
        printf "%s: max %s (hw %s)\n" "$(basename "$(dirname "$c")")" "$cur" "$hw"
    done | sort -V
}

# Serialize apply and reset (e.g. a manual run and the service).
take_lock() {
    mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
    exec 9>"$RUN_DIR/lock" || die "cannot open $RUN_DIR/lock"
    flock -w 60 9 || die "timed out waiting for $RUN_DIR/lock"
}

load_config() {
    read_config
    check_int POWER_LIMIT_W "$POWER_LIMIT_W" "$POWER_MIN_W" "$POWER_MAX_W"
    check_int MAX_FREQ_MHZ "$MAX_FREQ_MHZ" "$FREQ_MIN_MHZ" "$FREQ_MAX_MHZ"
}

do_apply() {
    load_config
    # Try both limits even if one fails, then report failure.
    local rc=0
    apply_power_limit || rc=1
    apply_max_freq || rc=1
    # Log only real changes, so the 15-minute re-apply shows when firmware reset a value.
    if [ "$CHANGED" = 1 ]; then
        log "applied: POWER_LIMIT_W=${POWER_LIMIT_W:-unchanged} MAX_FREQ_MHZ=${MAX_FREQ_MHZ:-unchanged}"
    elif [ -t 1 ]; then
        log "limits already in place"
    fi
    return "$rc"
}

[ "$(id -u)" = 0 ] || die "must run as root"

case "${1:-apply}" in
    apply)
        take_lock
        do_apply
        ;;
    reset)
        # During shutdown or reboot keep the limits: the guests are still shutting
        # down, and a normal boot starts from the firmware values anyway.
        if [ "$(systemctl is-system-running 2>/dev/null)" = stopping ]; then
            log "system is shutting down, keeping limits"
            exit 0
        fi
        take_lock
        reset_limits
        ;;
    check)
        load_config
        log "config OK: POWER_LIMIT_W=${POWER_LIMIT_W:-unchanged} MAX_FREQ_MHZ=${MAX_FREQ_MHZ:-unchanged}"
        ;;
    wait-rapl)
        load_config
        [ -z "$POWER_LIMIT_W" ] || wait_for_rapl || die "RAPL interface $RAPL_MSR not available"
        ;;
    status) show_status ;;
    *)      echo "usage: $0 [apply|reset|check|wait-rapl|status]" >&2; exit 2 ;;
esac
