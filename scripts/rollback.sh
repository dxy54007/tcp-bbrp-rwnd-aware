#!/usr/bin/env bash
# shellcheck disable=SC2317  # trap handlers and callbacks are invoked indirectly
# One-click rollback for the tcp_bbrp out-of-tree kernel module.
#
# Restores the module file, boot configuration, and runtime congestion-control
# state saved by install.sh.  It does not restart proxy services and does not
# touch routes or initcwnd/initrwnd.  The in-tree tcp_bbr.ko is never modified.
#
# License: GPL-2.0 (same as the rest of the repository).

set -u
set -o pipefail
umask 022
export LC_ALL=C

SCRIPT_VERSION="3.0.0"
SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    SELF="$(readlink -f -- "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi

MODULE_NAME="tcp_bbrp"
CC_NAME="bbrp"
MARKER="# Managed by tcp-bbrp install.sh"

STATE_ROOT="/var/lib/tcp-bbrp"
BACKUP_ROOT="/var/backups/tcp-bbrp"
LOG_ROOT="/var/log/tcp-bbrp"
LOCK_FILE="/run/lock/tcp-bbrp.lock"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"

# Command-line options.
STATE_ARG=""
STATE_GIVEN=0
LIST_STATES=0
AUTO=0
ASSUME_YES=0
DRY_RUN=0
KEEP_CONFIG=0
KEEP_MODULE=0
RUNTIME_ONLY=0
REMOVE_MODULE=0
PURGE=0
FORCE=0

# Runtime / state.
STATE_DIR=""
STATE_VALID=0
KVER="$(uname -r)"
ARCH="$(uname -m)"
DEST=""
MODULES_CONF=""
SYSCTL_CONF=""
ORIG_CC=""
ORIG_QDISC=""
ORIG_CC_AVAILABLE=0
ORIG_MODULE_LOADED=0
HAD_MODULES_CONF=0
HAD_SYSCTL_CONF=0
HAD_DEST=0
INSTALLED_KO_SHA256=""
WANT_FQ=0
MODULE_UNLOAD_SUPPORTED=1
CC_APPLIED=0

# Plan / results.
TARGET_CC=""
PURGED=0
BEFORE_CC=""
BEFORE_QDISC=""
SAFETY_DIR=""
LOG_FILE=""
WARN_COUNT=0
CRITICAL=0
LOCK_DIR=""

# ---------------------------------------------------------------------------
# Logging and small helpers
# ---------------------------------------------------------------------------

section() {
    printf '\n== %s ==\n' "$*"
}

ok() {
    printf '  [ OK ] %s\n' "$*"
}

info() {
    printf '  [INFO] %s\n' "$*"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf '  [WARN] %s\n' "$*" >&2
}

err() {
    printf 'ERROR: %s\n' "$*" >&2
}

critical() {
    CRITICAL=1
    printf '  [FAIL] %s\n' "$*" >&2
}

die() {
    err "$*"
    exit 1
}

usage_die() {
    err "$*"
    printf 'Run %s --help for usage.\n' "$0" >&2
    exit 2
}

usage() {
    cat <<'EOF'
tcp_bbrp rollback (Debian / Ubuntu)

Usage:
  curl -fsSL https://raw.githubusercontent.com/dxy54007/tcp-bbrp-rwnd-aware/main/scripts/rollback.sh -o /tmp/bbrp-rollback.sh
  bash /tmp/bbrp-rollback.sh [options]

Default behaviour:
  Restore the pre-install module file and boot configuration from the state
  snapshot, switch the runtime CC/qdisc back, and unload tcp_bbrp if possible.
  Proxy services are never restarted; routes and initcwnd/initrwnd are never
  touched.  Restart your listener manually if you want it to use the restored CC.

Options:
  --state DIR        Use a specific snapshot instead of "current".
                     A snapshot other than the current one requires --force.
  --list             List saved snapshots and exit.
  --runtime-only     Switch runtime CC/qdisc only; keep all files and module.
  --keep-config      Keep boot files and the loaded module (same as runtime-only).
  --keep-module      Keep the module file; boot persistence is still removed.
  --remove           Remove the module file instead of restoring a pre-install copy.
  --purge            Delete the selected snapshot after a successful full rollback.
  --auto             Non-interactive mode used by install.sh.
  -y, --yes          Do not ask for confirmation.
  --dry-run          Print the plan and change nothing.
  --force            Continue past safety refusals (old snapshot, modified module).
  -h, --help         Show this help.

Exit codes: 0 clean, 1 critical failure, 2 usage/state error, 3 warnings.
EOF
}

ensure_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
    if [[ ! -f "$SELF" ]]; then
        err "root is required; download the script to a file and run it with sudo"
        exit 1
    fi
    if command -v sudo >/dev/null 2>&1; then
        info "root is required; re-running with sudo"
        exec sudo -- bash "$SELF" "$@"
    fi
    err "root is required; run this script with sudo"
    exit 1
}

setup_logging() {
    (( DRY_RUN )) && return 0
    command -v tee >/dev/null 2>&1 || return 0
    install -d -m 750 "$LOG_ROOT" 2>/dev/null || {
        warn "cannot create $LOG_ROOT; continuing without a log file"
        return 0
    }
    LOG_FILE="$LOG_ROOT/rollback-$STAMP.log"
    if ! ( umask 077; : > "$LOG_FILE" ) 2>/dev/null; then
        warn "cannot write $LOG_FILE; continuing without a log file"
        LOG_FILE=""
        return 0
    fi
    exec > >(tee -a "$LOG_FILE") 2>&1
}

acquire_lock() {
    (( DRY_RUN )) && return 0
    install -d -m 755 "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE"
        if ! flock -n 9; then
            die "another install/rollback is already running"
        fi
    else
        LOCK_DIR="$LOCK_FILE.d"
        if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
            die "another install/rollback is already running (lock: $LOCK_DIR)"
        fi
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    fi
}

cleanup() {
    if [[ -n "${LOCK_DIR:-}" && -d "${LOCK_DIR:-}" ]]; then
        rm -f -- "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir -- "$LOCK_DIR" 2>/dev/null || true
        LOCK_DIR=""
    fi
    exec 9>&- || true
}

on_signal() {
    local sig="$1"
    err "received SIG$sig; the rollback may be incomplete"
    [[ -n "$STATE_DIR" ]] && err "state: $STATE_DIR"
    err "inspect the current configuration and re-run rollback.sh before rebooting"
    exit 130
}

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

need_arg() {
    [[ $# -ge 2 && -n "$2" ]] || usage_die "option $1 requires an argument"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --state)
                need_arg "$@"
                STATE_ARG="$2"
                STATE_GIVEN=1
                shift 2
                ;;
            --list)
                LIST_STATES=1
                shift
                ;;
            --runtime-only)
                RUNTIME_ONLY=1
                KEEP_CONFIG=1
                KEEP_MODULE=1
                shift
                ;;
            --keep-config)
                KEEP_CONFIG=1
                KEEP_MODULE=1
                shift
                ;;
            --keep-module)
                KEEP_MODULE=1
                shift
                ;;
            --remove)
                REMOVE_MODULE=1
                shift
                ;;
            --purge)
                PURGE=1
                shift
                ;;
            --auto)
                AUTO=1
                ASSUME_YES=1
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage_die "unknown option: $1"
                ;;
            *)
                usage_die "unexpected argument: $1"
                ;;
        esac
    done

    [[ $# -eq 0 ]] || usage_die "unexpected argument(s): $*"

    if (( AUTO )); then
        (( PURGE )) && usage_die "--auto cannot be combined with --purge"
    fi
    if (( RUNTIME_ONLY || KEEP_CONFIG )) && (( PURGE )); then
        usage_die "--purge cannot be combined with --runtime-only/--keep-config"
    fi
    if (( REMOVE_MODULE && KEEP_MODULE )); then
        usage_die "--remove and --keep-module are mutually exclusive"
    fi
}

# ---------------------------------------------------------------------------
# State discovery
# ---------------------------------------------------------------------------

state_field() {
    local dir="$1" key="$2"
    [[ -r "$dir/meta.env" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090,SC1091
        . "$dir/meta.env" >/dev/null 2>&1 || exit 1
        case "$key" in
            STATUS|KVER|ARCH|ORIG_CC|ORIG_QDISC|CREATED_AT|CC_APPLIED|DISTRO_ID|DISTRO_VERSION)
                printf '%s' "${!key:-}"
                ;;
            *)
                return 1
                ;;
        esac
    )
}

list_states() {
    section "Saved rollback states"
    local current="" d found=0 st sk cc created marker
    current="$(readlink -f -- "$STATE_ROOT/current" 2>/dev/null || true)"

    printf '  %-30s %-16s %-34s %-8s %s\n' "SNAPSHOT" "STATUS" "KERNEL" "CC" "CREATED"
    if [[ -d "$BACKUP_ROOT" ]]; then
        while IFS= read -r d; do
            [[ -r "$d/meta.env" ]] || continue
            found=1
            st="$(state_field "$d" STATUS || true)"
            sk="$(state_field "$d" KVER || true)"
            cc="$(state_field "$d" ORIG_CC || true)"
            created="$(state_field "$d" CREATED_AT || true)"
            if [[ -z "$created" ]]; then
                created="$(date -r "$d" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true)"
            fi
            marker=" "
            [[ -n "$current" && "$current" == "$d" ]] && marker="*"
            printf '  %s %-29s %-16s %-34s %-8s %s\n' \
                "$marker" "$(basename -- "$d")" "${st:-?}" "${sk:-?}" "${cc:-?}" "${created:-?}"
        done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
    fi

    if (( found == 0 )); then
        info "no snapshots found in $BACKUP_ROOT"
    fi
    if [[ -n "$current" ]]; then
        info "current -> $current"
    else
        info "no current snapshot symlink"
    fi
}

resolve_state_dir() {
    if (( STATE_GIVEN )); then
        [[ -d "$STATE_ARG" ]] || usage_die "state directory not found: $STATE_ARG"
        STATE_DIR="$(readlink -f -- "$STATE_ARG" 2>/dev/null || printf '%s' "$STATE_ARG")"
    elif [[ -L "$STATE_ROOT/current" ]]; then
        STATE_DIR="$(readlink -f -- "$STATE_ROOT/current" 2>/dev/null || true)"
        if [[ -z "$STATE_DIR" || ! -d "$STATE_DIR" ]]; then
            warn "$STATE_ROOT/current does not point at a usable directory"
            STATE_DIR=""
        fi
    fi

    if [[ -z "$STATE_DIR" && -d "$BACKUP_ROOT" ]]; then
        local d
        while IFS= read -r d; do
            [[ -r "$d/meta.env" ]] || continue
            STATE_DIR="$d"
        done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
    fi

    [[ -n "$STATE_DIR" ]] || return 0
    [[ -d "$STATE_DIR" ]] || usage_die "state directory not found: $STATE_DIR"
    case "$STATE_DIR" in
        "$BACKUP_ROOT"/*|"$STATE_ROOT"/*)
            ;;
        *)
            if (( FORCE )); then
                warn "state directory is outside $BACKUP_ROOT; continuing because of --force"
            else
                usage_die "refusing a state directory outside $BACKUP_ROOT (use --force to override)"
            fi
            ;;
    esac
    [[ -r "$STATE_DIR/meta.env" ]] || usage_die "missing or unreadable $STATE_DIR/meta.env"
}

int_or_zero() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$1" ;;
    esac
}

load_state() {
    local meta="$STATE_DIR/meta.env"
    [[ -r "$meta" ]] || usage_die "cannot read $meta"

    unset META_VERSION STATUS CREATED_AT UPDATED_AT INSTALLER_VERSION
    unset DISTRO_ID DISTRO_VERSION KVER ARCH DEST MODULES_CONF SYSCTL_CONF
    unset ORIG_CC ORIG_QDISC ORIG_CC_AVAILABLE ORIG_MODULE_LOADED
    unset HAD_MODULES_CONF HAD_SYSCTL_CONF HAD_DEST INSTALLED_KO_SHA256
    unset WANT_FQ MODULE_UNLOAD_SUPPORTED SECURE_BOOT SIG_ENFORCE CC_APPLIED

    set +u
    # shellcheck disable=SC1090,SC1091
    if ! . "$meta"; then
        set -u
        usage_die "cannot load $meta"
    fi
    set -u

    if [[ "${META_VERSION:-0}" =~ ^[0-9]+$ ]] && (( META_VERSION > 2 )); then
        usage_die "state format $META_VERSION is newer than this rollback script supports"
    fi

    STATE_VALID=1
    KVER="${KVER:-$(uname -r)}"
    ARCH="${ARCH:-$(uname -m)}"
    DEST="${DEST:-/lib/modules/$KVER/extra/$MODULE_NAME.ko}"
    MODULES_CONF="${MODULES_CONF:-/etc/modules-load.d/tcp_bbrp.conf}"
    SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.d/zz-bbrp.conf}"

    ORIG_CC="${ORIG_CC:-}"
    ORIG_QDISC="${ORIG_QDISC:-}"
    [[ "$ORIG_CC" == "unknown" ]] && ORIG_CC=""
    [[ "$ORIG_QDISC" == "unknown" ]] && ORIG_QDISC=""

    ORIG_CC_AVAILABLE="$(int_or_zero "${ORIG_CC_AVAILABLE:-0}")"
    ORIG_MODULE_LOADED="$(int_or_zero "${ORIG_MODULE_LOADED:-0}")"
    HAD_MODULES_CONF="$(int_or_zero "${HAD_MODULES_CONF:-0}")"
    HAD_SYSCTL_CONF="$(int_or_zero "${HAD_SYSCTL_CONF:-0}")"
    HAD_DEST="$(int_or_zero "${HAD_DEST:-0}")"
    WANT_FQ="$(int_or_zero "${WANT_FQ:-0}")"
    MODULE_UNLOAD_SUPPORTED="$(int_or_zero "${MODULE_UNLOAD_SUPPORTED:-1}")"
    CC_APPLIED="$(int_or_zero "${CC_APPLIED:-0}")"
    INSTALLED_KO_SHA256="${INSTALLED_KO_SHA256:-}"

    if [[ -n "$INSTALLED_KO_SHA256" && ! "$INSTALLED_KO_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
        warn "ignoring malformed INSTALLED_KO_SHA256 in $meta"
        INSTALLED_KO_SHA256=""
    fi

    validate_state_values
}

validate_state_values() {
    [[ "$KVER" =~ ^[A-Za-z0-9._+~-]+$ ]] || usage_die "invalid kernel version in state: $KVER"
    [[ "$DEST" == /lib/modules/* ]] || usage_die "module path is outside /lib/modules: $DEST"
    [[ "$(basename -- "$DEST")" == "$MODULE_NAME.ko" ]] || usage_die "unexpected module file name: $DEST"
    [[ "$MODULES_CONF" == /etc/* ]] || usage_die "invalid modules-load path in state: $MODULES_CONF"
    [[ "$(basename -- "$MODULES_CONF")" == "tcp_bbrp.conf" ]] || usage_die "unexpected modules-load file name: $MODULES_CONF"
    [[ "$SYSCTL_CONF" == /etc/* ]] || usage_die "invalid sysctl path in state: $SYSCTL_CONF"
    [[ "$(basename -- "$SYSCTL_CONF")" == "zz-bbrp.conf" ]] || usage_die "unexpected sysctl file name: $SYSCTL_CONF"
    if [[ "$KVER" != "$(uname -r)" ]]; then
        warn "snapshot was created for kernel $KVER; running kernel is $(uname -r)"
    fi
}

check_selected_state_safety() {
    (( STATE_VALID )) || return 0
    (( FORCE )) && return 0
    local current=""
    current="$(readlink -f -- "$STATE_ROOT/current" 2>/dev/null || true)"
    if [[ -n "$current" && "$current" != "$STATE_DIR" ]]; then
        usage_die "the selected snapshot is not the current one ($current); use --force to override"
    fi
}

init_no_state() {
    STATE_VALID=0
    KVER="$(uname -r)"
    ARCH="$(uname -m)"
    DEST="/lib/modules/$KVER/extra/$MODULE_NAME.ko"
    MODULES_CONF="/etc/modules-load.d/tcp_bbrp.conf"
    SYSCTL_CONF="/etc/sysctl.d/zz-bbrp.conf"
    ORIG_CC=""
    ORIG_QDISC=""
    ORIG_CC_AVAILABLE=0
    ORIG_MODULE_LOADED=0
    HAD_MODULES_CONF=0
    HAD_SYSCTL_CONF=0
    HAD_DEST=0
    INSTALLED_KO_SHA256=""
    WANT_FQ=0
    MODULE_UNLOAD_SUPPORTED=1
    CC_APPLIED=0
}

# ---------------------------------------------------------------------------
# Read-only system helpers
# ---------------------------------------------------------------------------

current_cc() {
    cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
}

current_qdisc() {
    cat /proc/sys/net/core/default_qdisc 2>/dev/null || true
}

available_cc() {
    cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true
}

module_is_loaded() {
    lsmod 2>/dev/null | awk '$1 == "'"$MODULE_NAME"'" {found=1} END {exit !found}'
}

module_hash_matches() {
    [[ -n "$INSTALLED_KO_SHA256" && -f "$DEST" ]] || return 1
    local sum
    sum="$(sha256sum -- "$DEST" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$sum" == "$INSTALLED_KO_SHA256" ]]
}

is_managed_modules_conf() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -qF -- "$MARKER" "$file" 2>/dev/null && return 0
    awk '
        /^[[:space:]]*(#|$)/ { next }
        /^[[:space:]]*tcp_bbrp[[:space:]]*$/ { seen = 1; next }
        /^[[:space:]]*tcp_bbr[[:space:]]*$/ { next }
        { bad = 1 }
        END { exit !(seen && !bad) }
    ' "$file" 2>/dev/null
}

is_managed_sysctl_conf() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -qF -- "$MARKER" "$file" 2>/dev/null && return 0
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            n = split(line, a, "=")
            if (n != 2) { bad = 1; next }
            key = a[1]; val = a[2]
            gsub(/[[:space:]]/, "", key)
            gsub(/[[:space:]]/, "", val)
            if (key == "net.ipv4.tcp_congestion_control" && val == "bbrp") { seen = 1; next }
            if (key == "net.core.default_qdisc" && val == "fq") { next }
            bad = 1
        }
        END { exit !(seen && !bad) }
    ' "$file" 2>/dev/null
}

ensure_bbr_available() {
    grep -qw bbr <<<"$(available_cc)" && return 0
    command -v modprobe >/dev/null 2>&1 || return 1
    modprobe tcp_bbr >/dev/null 2>&1 || return 1
    grep -qw bbr <<<"$(available_cc)"
}

choose_target_cc() {
    local avail want c
    avail="$(available_cc)"
    want="$ORIG_CC"

    if [[ -n "$want" && "$want" != "$CC_NAME" ]] && grep -qw -- "$want" <<<"$avail"; then
        printf '%s' "$want"
        return 0
    fi
    [[ -n "$want" && "$want" != "$CC_NAME" ]] && warn "original CC '$want' is not available; falling back"

    for c in bbr cubic; do
        if grep -qw -- "$c" <<<"$avail"; then
            printf '%s' "$c"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Mutating helpers
# ---------------------------------------------------------------------------

atomic_restore() {
    local src="$1" dest="$2" dir tmp
    [[ -f "$src" ]] || return 1
    dir="$(dirname -- "$dest")"
    install -d -m 755 "$dir" || return 1
    tmp="$(mktemp "$dir/.tcp-bbrp-restore.XXXXXX")" || return 1
    if ! cp -a -- "$src" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
    return 0
}

remove_managed_file() {
    local file="$1" kind="$2"
    [[ -e "$file" || -L "$file" ]] || return 0
    if [[ "$kind" == "modules" ]]; then
        if is_managed_modules_conf "$file"; then
            if (( DRY_RUN )); then
                info "[DRY] rm -f $file"
            else
                rm -f -- "$file" || { critical "cannot remove $file"; return 1; }
                ok "removed $file"
            fi
        else
            warn "$file is not managed by tcp-bbrp; left in place"
        fi
    else
        if is_managed_sysctl_conf "$file"; then
            if (( DRY_RUN )); then
                info "[DRY] rm -f $file"
            else
                rm -f -- "$file" || { critical "cannot remove $file"; return 1; }
                ok "removed $file"
            fi
        else
            warn "$file is not managed by tcp-bbrp; left in place"
        fi
    fi
    return 0
}

restore_boot_file() {
    local dest="$1" backup="$2" had="$3" kind="$4"
    if (( had )); then
        if [[ -f "$backup" ]]; then
            if (( DRY_RUN )); then
                info "[DRY] restore $backup -> $dest"
            else
                atomic_restore "$backup" "$dest" || { critical "cannot restore $dest from $backup"; return 1; }
                ok "restored $dest"
            fi
        else
            warn "backup missing: $backup"
        fi
    else
        remove_managed_file "$dest" "$kind" || return 1
    fi
    return 0
}

restore_boot_files() {
    section "Rollback: boot configuration"
    restore_boot_file "$MODULES_CONF" "${STATE_DIR:+$STATE_DIR/modules-load.conf}" "$HAD_MODULES_CONF" modules || return 1
    restore_boot_file "$SYSCTL_CONF" "${STATE_DIR:+$STATE_DIR/sysctl.conf}" "$HAD_SYSCTL_CONF" sysctl || return 1
    return 0
}

unload_module() {
    section "Rollback: unload module"
    if ! module_is_loaded; then
        info "$MODULE_NAME is not loaded"
        return 0
    fi
    if (( KEEP_MODULE )); then
        info "$MODULE_NAME is kept loaded (--keep-module/--runtime-only)"
        return 0
    fi
    if (( ! MODULE_UNLOAD_SUPPORTED )); then
        warn "CONFIG_MODULE_UNLOAD is disabled; reboot to unload $MODULE_NAME"
        return 0
    fi

    for _ in 1 2 3 4 5; do
        if ! module_is_loaded; then
            break
        fi
        if modprobe -r "$MODULE_NAME" >/dev/null 2>&1; then
            ok "unloaded $MODULE_NAME"
            return 0
        fi
        sleep 1
    done

    if module_is_loaded; then
        warn "$MODULE_NAME is still in use by existing sockets; it will not load after reboot"
    fi
    return 0
}

restore_module_file() {
    section "Rollback: module file"
    if (( KEEP_MODULE )); then
        info "module file kept: $DEST"
        return 0
    fi

    if [[ ! -e "$DEST" && ! -L "$DEST" ]]; then
        info "no installed module file at $DEST"
        return 0
    fi

    if (( REMOVE_MODULE )); then
        if (( DRY_RUN )); then
            info "[DRY] rm -f $DEST"
        else
            rm -f -- "$DEST" || { critical "cannot remove $DEST"; return 1; }
            ok "removed $DEST"
        fi
    elif (( HAD_DEST )); then
        local backup="$STATE_DIR/tcp_bbrp.ko.orig"
        if [[ -f "$backup" ]]; then
            if (( DRY_RUN )); then
                info "[DRY] restore $backup -> $DEST"
            else
                atomic_restore "$backup" "$DEST" || { critical "cannot restore $DEST from $backup"; return 1; }
                ok "restored the pre-install module file"
            fi
        else
            warn "backup missing: $backup"
        fi
    else
        if (( FORCE )) || module_hash_matches || [[ -z "$INSTALLED_KO_SHA256" ]]; then
            if (( DRY_RUN )); then
                info "[DRY] rm -f $DEST"
            else
                rm -f -- "$DEST" || { critical "cannot remove $DEST"; return 1; }
                ok "removed $DEST"
            fi
        else
            warn "$DEST does not match the installed module hash; use --force to remove it"
        fi
    fi

    if (( ! DRY_RUN )); then
        depmod -a "$KVER" >/dev/null 2>&1 || warn "depmod -a $KVER failed"
    fi
    return 0
}

switch_runtime() {
    section "Rollback: runtime congestion control"
    BEFORE_CC="$(current_cc)"
    BEFORE_QDISC="$(current_qdisc)"

    # Nothing to roll back if bbrp was never applied and we have no original
    # state to restore.  This also avoids switching a healthy cubic/bbr host.
    if [[ "$BEFORE_CC" != "$CC_NAME" && -z "$ORIG_CC" ]]; then
        info "runtime CC is ${BEFORE_CC:-unknown}; no CC change needed"
        return 0
    fi

    ensure_bbr_available || true
    TARGET_CC="$(choose_target_cc || true)"
    if [[ -z "$TARGET_CC" ]]; then
        if [[ "$BEFORE_CC" == "$CC_NAME" ]]; then
            critical "no fallback congestion-control algorithm is available"
            return 1
        fi
        info "no runtime CC change needed (current: ${BEFORE_CC:-unknown})"
    elif [[ "$BEFORE_CC" == "$TARGET_CC" ]]; then
        info "runtime CC is already $TARGET_CC"
    else
        if (( DRY_RUN )); then
            info "[DRY] sysctl -w net.ipv4.tcp_congestion_control=$TARGET_CC"
        else
            if ! sysctl -w "net.ipv4.tcp_congestion_control=$TARGET_CC" >/dev/null; then
                critical "cannot switch the runtime CC to $TARGET_CC; no files were changed"
                return 1
            fi
            ok "runtime CC: $BEFORE_CC -> $TARGET_CC"
        fi
    fi

    if (( WANT_FQ )) && [[ -n "$ORIG_QDISC" && "$ORIG_QDISC" != "unknown" ]]; then
        if [[ "$BEFORE_QDISC" == "$ORIG_QDISC" ]]; then
            info "runtime qdisc is already $ORIG_QDISC"
        else
            if (( DRY_RUN )); then
                info "[DRY] sysctl -w net.core.default_qdisc=$ORIG_QDISC"
            else
                if sysctl -w "net.core.default_qdisc=$ORIG_QDISC" >/dev/null; then
                    ok "runtime qdisc: $BEFORE_QDISC -> $ORIG_QDISC"
                else
                    warn "cannot restore net.core.default_qdisc=$ORIG_QDISC"
                fi
            fi
        fi
    fi
    return 0
}

create_safety_copy() {
    (( DRY_RUN )) && return 0
    (( RUNTIME_ONLY || KEEP_CONFIG )) && return 0
    SAFETY_DIR="$BACKUP_ROOT/rollback-$STAMP"
    install -d -m 700 "$SAFETY_DIR" 2>/dev/null || { warn "cannot create $SAFETY_DIR"; SAFETY_DIR=""; return 0; }
    local f
    for f in "$DEST" "$MODULES_CONF" "$SYSCTL_CONF"; do
        if [[ -e "$f" || -L "$f" ]]; then
            cp -a -- "$f" "$SAFETY_DIR/$(basename -- "$f")" 2>/dev/null || warn "cannot back up $f"
        fi
    done
    [[ -d "$SAFETY_DIR" ]] && info "safety copy: $SAFETY_DIR"
}

mark_state_rolled_back() {
    (( STATE_VALID )) || return 0
    (( DRY_RUN )) && return 0
    [[ -w "$STATE_DIR/meta.env" ]] || return 0
    local tmp
    tmp="$(mktemp "$STATE_DIR/.meta.XXXXXX")" || return 0
    awk '
        BEGIN { done = 0 }
        /^STATUS=/ { print "STATUS=rolled-back"; done = 1; next }
        { print }
        END { if (!done) print "STATUS=rolled-back" }
    ' "$STATE_DIR/meta.env" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 0; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$STATE_DIR/meta.env" 2>/dev/null || true
}

purge_state() {
    (( PURGE )) || return 0
    (( STATE_VALID )) || return 0
    (( CRITICAL )) && return 0
    if module_is_loaded && (( ! KEEP_MODULE )); then
        warn "module is still loaded; snapshot kept for a later retry"
        return 0
    fi
    if (( DRY_RUN )); then
        info "[DRY] rm -rf $STATE_DIR"
        return 0
    fi
    local current=""
    current="$(readlink -f -- "$STATE_ROOT/current" 2>/dev/null || true)"
    if [[ -n "$current" && "$current" == "$STATE_DIR" ]]; then
        rm -f -- "$STATE_ROOT/current" 2>/dev/null || true
    fi
    rm -rf -- "$STATE_DIR" || { warn "cannot remove $STATE_DIR"; return 0; }
    PURGED=1
    ok "purged snapshot $STATE_DIR"
}

# ---------------------------------------------------------------------------
# Plan and summary
# ---------------------------------------------------------------------------

print_plan() {
    section "Rollback plan (no changes made)"
    if (( STATE_VALID )); then
        printf '  snapshot:    %s\n' "$STATE_DIR"
        printf '  original CC: %s\n' "${ORIG_CC:-unknown}"
        printf '  original qdisc: %s\n' "${ORIG_QDISC:-unknown}"
    else
        printf '  snapshot:    none (conservative cleanup)\n'
        printf '  original CC: unknown; fall back to bbr/cubic\n'
    fi
    printf '  runtime:     %s -> %s\n' "${BEFORE_CC:-?}" "${TARGET_CC:-no change}"
    printf '  boot files:  %s ; %s\n' "$MODULES_CONF" "$SYSCTL_CONF"
    printf '  module file: %s\n' "$DEST"
    if (( RUNTIME_ONLY || KEEP_CONFIG )); then
        printf '  mode:        runtime only; files and module kept\n'
    elif (( KEEP_MODULE )); then
        printf '  mode:        restore boot files; keep module\n'
    elif (( REMOVE_MODULE )); then
        printf '  mode:        restore boot files; remove module file\n'
    else
        printf '  mode:        full restore\n'
    fi
    printf '\nNo changes were made.  Re-run without --dry-run to roll back.\n'
}

print_summary() {
    if (( CRITICAL )); then
        section "Rollback incomplete (rollback.sh $SCRIPT_VERSION)"
    else
        section "Rollback complete (rollback.sh $SCRIPT_VERSION)"
    fi
    printf '  runtime CC:   %s\n' "$(current_cc)"
    printf '  default qdisc: %s\n' "$(current_qdisc)"
    if module_is_loaded; then
        printf '  module:       loaded (may remain until existing sockets close or reboot)\n'
    else
        printf '  module:       not loaded\n'
    fi
    if (( STATE_VALID )) && (( ! PURGED )); then
        printf '  snapshot:     %s\n' "$STATE_DIR"
    fi
    [[ -n "$SAFETY_DIR" ]] && printf '  safety copy:  %s\n' "$SAFETY_DIR"
    [[ -n "${LOG_FILE:-}" ]] && printf '  log:          %s\n' "$LOG_FILE"
    printf '\nNo proxy service was restarted.  If a listener must use the restored CC,\n'
    printf 'restart it manually.  Routes and initcwnd/initrwnd were not touched.\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    ensure_root "$@"
    setup_logging
    acquire_lock

    if (( LIST_STATES )); then
        list_states
        exit 0
    fi

    resolve_state_dir
    if [[ -n "$STATE_DIR" ]]; then
        load_state
        check_selected_state_safety
    else
        init_no_state
        info "no snapshot found; using conservative cleanup"
    fi

    BEFORE_CC="$(current_cc)"
    BEFORE_QDISC="$(current_qdisc)"

    if (( DRY_RUN )); then
        if [[ "$BEFORE_CC" != "$CC_NAME" && -z "$ORIG_CC" ]]; then
            TARGET_CC=""
        else
            TARGET_CC="$(choose_target_cc || true)"
        fi
        print_plan
        exit 0
    fi

    if (( ! ASSUME_YES )); then
        printf 'Roll back tcp_bbrp now? [y/N] '
        local ans=""
        read -r ans || ans=""
        [[ "$ans" =~ ^[Yy]$ ]] || { info "cancelled"; exit 0; }
    fi

    create_safety_copy || true

    if ! switch_runtime; then
        print_summary
        exit 1
    fi

    if (( RUNTIME_ONLY || KEEP_CONFIG )); then
        print_summary
        (( WARN_COUNT > 0 )) && exit 3
        exit 0
    fi

    restore_boot_files || true
    unload_module || true
    restore_module_file || true

    if (( ! CRITICAL )); then
        mark_state_rolled_back
        purge_state
    fi

    print_summary

    if (( CRITICAL )); then
        exit 1
    fi
    if (( WARN_COUNT > 0 )); then
        exit 3
    fi
    exit 0
}

main "$@"
