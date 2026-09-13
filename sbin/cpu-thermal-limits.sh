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
#   cpu-thermal-limits.sh reset     restore the values saved before the first apply
#   cpu-thermal-limits.sh status    show current limits

set -eu

CONFIG=/etc/default/cpu-thermal-limits
STATE_DIR=/var/lib/cpu-thermal-limits
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
# unless a valid saved value already exists. Written atomically.
save_once() {
    local dst="$STATE_DIR/$1" v
    if [ -f "$dst" ] && is_uint "$(cat "$dst" 2>/dev/null)"; then
        return 0
    fi
    v=$(read_uint "$2") || { warn "cannot read $2"; return 1; }
    mkdir -p "$STATE_DIR" || return 1
    printf '%s\n' "$v" > "$dst.tmp" && mv -f "$dst.tmp" "$dst" || { warn "cannot write $dst"; return 1; }
}

# restore NAME TARGET_FILE: write the saved value back. Fails if nothing valid was saved.
restore() {
    local src="$STATE_DIR/$1" v
    [ -f "$src" ] || return 2
    v=$(read_uint "$src") || { warn "saved value $src is invalid"; return 1; }
    echo "$v" 2>/dev/null > "$2" || true
    [ "$(cat "$2" 2>/dev/null)" = "$v" ] || { warn "could not restore $2"; return 1; }
}

rapl_domains() {
    local d
    for d in "$RAPL_MSR" "$RAPL_MMIO"; do [ -d "$d" ] && echo "$d"; done
    return 0
}

cpufreq_dirs() {
    local c
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do [ -f "$c/scaling_max_freq" ] && echo "$c"; done
    return 0
}

# ---------------------------------------------------------------------------
# apply / reset / status
# ---------------------------------------------------------------------------

wait_for_rapl() {
    # RAPL drivers are loaded by udev. The MSR interface is required and may take
    # a while at boot; the MMIO interface is optional and gets a short grace period.
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

apply_power_limit() {
    [ -n "$POWER_LIMIT_W" ] || return 0
    local uw=$(( POWER_LIMIT_W * 1000000 )) d c ok=0
    wait_for_rapl || { warn "RAPL interface $RAPL_MSR not available"; return 1; }
    for d in $(rapl_domains); do
        for c in 0 1; do
            save_once "$(basename "$d")-c$c" "$d/constraint_${c}_power_limit_uw" \
                || { warn "not changing $d: original value could not be saved"; continue 2; }
        done
        echo "$uw" 2>/dev/null > "$d/constraint_0_power_limit_uw" || true
        echo "$uw" 2>/dev/null > "$d/constraint_1_power_limit_uw" || true
        if [ "$(cat "$d/constraint_0_power_limit_uw")" = "$uw" ] && [ "$(cat "$d/constraint_1_power_limit_uw")" = "$uw" ]; then
            ok=1
        else
            warn "$d did not accept ${POWER_LIMIT_W} W"
        fi
    done
    [ "$ok" = 1 ] || { warn "power limit not applied"; return 1; }
    log "power limit: ${POWER_LIMIT_W} W"
}

apply_max_freq() {
    [ -n "$MAX_FREQ_MHZ" ] || return 0
    local khz=$(( MAX_FREQ_MHZ * 1000 )) c hw v bad=0 found=0
    for c in $(cpufreq_dirs); do
        found=1
        save_once "$(basename "$(dirname "$c")")-max_freq" "$c/scaling_max_freq" || { bad=1; continue; }
        hw=$(read_uint "$c/cpuinfo_max_freq") || { bad=1; continue; }
        v=$khz
        if [ "$v" -gt "$hw" ]; then v=$hw; fi
        echo "$v" 2>/dev/null > "$c/scaling_max_freq" || true
        [ "$(cat "$c/scaling_max_freq" 2>/dev/null)" = "$v" ] || { warn "$c did not accept $v kHz"; bad=1; }
    done
    [ "$found" = 1 ] || { warn "no cpufreq interface found"; return 1; }
    [ "$bad" = 0 ] || { warn "max frequency not applied on all cores"; return 1; }
    log "max frequency: ${MAX_FREQ_MHZ} MHz"
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
