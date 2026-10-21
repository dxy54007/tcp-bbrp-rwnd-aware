#!/usr/bin/env bash
# shellcheck disable=SC2317  # trap handlers and callback functions are invoked indirectly
# One-click rollback for the tcp_bbrp out-of-tree kernel module.
#
# The script restores the state recorded by install.sh in
# /var/backups/tcp-bbrp/<stamp>/ (the "current" symlink points at the most
# recent one).  The in-tree tcp_bbr.ko is never touched.
#
# Safety model
# ------------
# * The default is a full restore: boot persistence files and the module file
#   are restored to their pre-install contents, the runtime CC/qdisc are put
#   back, affected services are restarted, and the module is unloaded when no
#   longer in use.
# * Files that were not created by the installer are never deleted.  Managed
#   files are recognised by the install.sh marker or by their exact legacy
#   contents.
# * A failure while switching the runtime CC aborts before any file is
#   changed, because a half-removed boot configuration is worse than a working
#   bbrp installation.
# * If no state exists, the script falls back to a conservative cleanup and
#   prints exactly what it will remove before doing it.
# * A safety copy of every file that is about to be changed is stored in
#   /var/backups/tcp-bbrp/rollback-<stamp>/.
#
# Exit codes: 0 = clean rollback, 1 = critical failure,
#             2 = usage/state error, 3 = rollback completed with warnings.
#
# License: GPL-2.0 (same as the rest of the repository).

set -u
set -o pipefail
umask 022
export LC_ALL=C

SCRIPT_VERSION="2.0.0"
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
RESTART_MODE="auto"     # auto | none | force
RESTART_FLAG=""
RESET_ROUTE=0
FORCE=0

# Runtime / state.
STATE_DIR=""
STATE_VALID=0
STATE_STATUS=""
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
SERVICES_TO_RESTART=()
SERVICES_RESTARTED=()
NEW_PACKAGES=()

# Plan / results.
TARGET_CC=""
RUNTIME_WILL_CHANGE=0
RUNTIME_WILL_SWITCH=0
RUNTIME_WILL_QDISC=0
RUNTIME_CHANGED=0
PURGED=0
BEFORE_CC=""
BEFORE_QDISC=""
BEFORE_MODULE=0
SERVICE_TARGETS=()
SERVICE_FAILURES=()
SAFETY_DIR=""
LOG_FILE=""
WARN_COUNT=0
CRITICAL=0
LOCK_DIR=""

KNOWN_SERVICES=(
    x-ui
    3x-ui
    xray
    v2ray
    v2raya
    sing-box
    hysteria-server
    hysteria
    trojan-go
    shadowsocks-libev
)

# ---------------------------------------------------------------------------
# Logging and small helpers
# ---------------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

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
  sudo ./scripts/rollback.sh [options]

Default behaviour:
  Restore the pre-install module file and boot configuration from the state
  snapshot, switch the runtime CC/qdisc back, restart affected services, and
  unload tcp_bbrp when no longer in use.  If the module did not exist before
  the installation, the installed module file is removed.

Options:
  --state DIR        Use a specific snapshot directory instead of "current".
                     A snapshot other than the current one requires --force.
  --list             List saved snapshots and exit.
  --runtime-only     Switch runtime CC/qdisc and restart services only; keep
                     all files and leave the module loaded.
  --keep-config      Keep /etc/modules-load.d and /etc/sysctl.d files, the
                     module file, and the loaded module (runtime switch only).
  --keep-module      Keep the module file; boot persistence is still removed
                     and the module is unloaded if possible.
  --remove           Remove the module file instead of restoring a pre-install
                     copy (used for a clean uninstall).
  --purge            Delete the selected state snapshot after a successful
                     rollback.  The normal restore/remove rules still apply.
  --reset-route      Also strip initcwnd/initrwnd from the default route.
  --no-restart       Do not restart any service.
  --restart          Restart recorded services even if the runtime CC did not
                     change (inactive units are never started).
  -y, --yes          Do not ask for confirmation.
  --dry-run          Print the plan and change nothing.
  --force            Continue past safety refusals (dirty module file, loaded
                     module during --purge, files outside the state roots).
  -h, --help         Show this help.

Service restart policy:
  Only services that the installer restarted (recorded in the snapshot) are
  restarted.  Without a snapshot, the known proxy units are restarted only if
  they are currently active.  Inactive units are never started.

No-snapshot fallback:
  The script removes only files that contain the install.sh marker or match
  the legacy tcp_bbrp layout, switches bbrp back to bbr/cubic, and unloads the
  module.  It cannot restore a custom original CC/qdisc; use --state when a
  snapshot exists.

Examples:
  sudo ./scripts/rollback.sh --list
  sudo ./scripts/rollback.sh --dry-run
  sudo ./scripts/rollback.sh                 # full restore
  sudo ./scripts/rollback.sh --runtime-only  # stop using bbrp, keep boot files
  sudo ./scripts/rollback.sh --purge         # uninstall and delete the state

Exit codes: 0 clean, 1 critical failure, 2 usage/state error, 3 warnings.
EOF
}

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
            --no-restart)
                [[ "$RESTART_FLAG" == "restart" ]] && usage_die "--no-restart and --restart are mutually exclusive"
                RESTART_MODE="none"
                RESTART_FLAG="no-restart"
                shift
                ;;
            --restart)
                [[ "$RESTART_FLAG" == "no-restart" ]] && usage_die "--no-restart and --restart are mutually exclusive"
                RESTART_MODE="force"
                RESTART_FLAG="restart"
                shift
                ;;
            --reset-route|--full)
                RESET_ROUTE=1
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
        # Automatic rollback must never purge audit data or reset routes.
        if (( PURGE )); then
            usage_die "--auto cannot be combined with --purge"
        fi
        if (( RESET_ROUTE )); then
            usage_die "--auto cannot be combined with --reset-route"
        fi
    fi
}

check_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run this script as root (sudo)"
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
    trap - INT TERM HUP
    err "received SIG$sig; the rollback may be incomplete"
    if [[ -n "${STATE_DIR:-}" ]]; then
        err "state: $STATE_DIR"
    fi
    err "inspect the current configuration and re-run rollback.sh before rebooting"
    exit 130
}

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

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
        if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
            info "run as root to read state directories"
        fi
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

    if [[ -z "$STATE_DIR" ]]; then
        return 0
    fi
    if [[ ! -d "$STATE_DIR" ]]; then
        usage_die "state directory not found: $STATE_DIR"
    fi
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

    # Drop inherited values so the snapshot is the only source of truth.
    unset META_VERSION STATUS CREATED_AT UPDATED_AT INSTALLER_VERSION
    unset DISTRO_ID DISTRO_VERSION KVER ARCH DEST MODULES_CONF SYSCTL_CONF
    unset ORIG_CC ORIG_QDISC ORIG_CC_AVAILABLE ORIG_MODULE_LOADED
    unset HAD_MODULES_CONF HAD_SYSCTL_CONF HAD_DEST INSTALLED_KO_SHA256
    unset WANT_FQ MODULE_UNLOAD_SUPPORTED SECURE_BOOT SIG_ENFORCE CC_APPLIED
    unset SERVICES_TO_RESTART SERVICES_RESTARTED NEW_PACKAGES

    set +u
    # shellcheck disable=SC1090,SC1091
    if ! . "$meta"; then
        set -u
        usage_die "cannot load $meta"
    fi
    set -u

    if [[ "${META_VERSION:-0}" =~ ^[0-9]+$ ]] && (( META_VERSION > 1 )); then
        usage_die "state format $META_VERSION is newer than this rollback script supports"
    fi

    STATE_VALID=1
    STATE_STATUS="${STATUS:-}"
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

    # The metadata stores service lists as space-separated strings.
    local svc
    svc="${SERVICES_TO_RESTART:-}"
    SERVICES_TO_RESTART=()
    [[ -n "$svc" ]] && read -r -a SERVICES_TO_RESTART <<<"$svc"
    svc="${SERVICES_RESTARTED:-}"
    SERVICES_RESTARTED=()
    [[ -n "$svc" ]] && read -r -a SERVICES_RESTARTED <<<"$svc"
    svc="${NEW_PACKAGES:-}"
    NEW_PACKAGES=()
    [[ -n "$svc" ]] && read -r -a NEW_PACKAGES <<<"$svc"

    validate_state_values
}

validate_state_values() {
    [[ "$KVER" =~ ^[A-Za-z0-9._+~-]+$ ]] || usage_die "invalid kernel version in state: $KVER"
    [[ "$DEST" == /* ]] || usage_die "invalid module path in state: $DEST"
    [[ "$DEST" == /lib/modules/* ]] || usage_die "module path is outside /lib/modules: $DEST"
    [[ "$(basename -- "$DEST")" == "$MODULE_NAME.ko" ]] || usage_die "unexpected module file name: $DEST"
    [[ "$MODULES_CONF" == /etc/* ]] || usage_die "invalid modules-load path in state: $MODULES_CONF"
    [[ "$(basename -- "$MODULES_CONF")" == "tcp_bbrp.conf" ]] || usage_die "unexpected modules-load file name: $MODULES_CONF"
    [[ "$SYSCTL_CONF" == /etc/* ]] || usage_die "invalid sysctl path in state: $SYSCTL_CONF"
    [[ "$(basename -- "$SYSCTL_CONF")" == "zz-bbrp.conf" ]] || usage_die "unexpected sysctl file name: $SYSCTL_CONF"
}

check_selected_state_safety() {
    # Refuse to silently roll back an old snapshot while a newer installation is
    # current: the boot files and module names are shared across snapshots.
    (( STATE_VALID )) || return 0
    (( FORCE )) && return 0
    local current=""
    current="$(readlink -f -- "$STATE_ROOT/current" 2>/dev/null || true)"
    if [[ -n "$current" && "$current" != "$STATE_DIR" ]]; then
        usage_die "the selected snapshot is not the current one ($current); use --state \"$current\", or --force to override"
    fi
}

init_no_state() {
    STATE_VALID=0
    STATE_STATUS=""
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
    SERVICES_TO_RESTART=()
    SERVICES_RESTARTED=()
    NEW_PACKAGES=()
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

loaded_module_matches_state() {
    # Do not unload a module that belongs to a different installation/kernel.
    module_is_loaded || return 1
    local path
    path="$(modinfo -n "$MODULE_NAME" 2>/dev/null || true)"
    # If modinfo cannot resolve a file, assume the loaded module is ours; the
    # name is project-specific and a hand-loaded copy is still safe to unload.
    [[ -n "$path" ]] || return 0
    path="$(readlink -f -- "$path" 2>/dev/null || printf '%s' "$path")"
    local dest
    dest="$(readlink -f -- "$DEST" 2>/dev/null || printf '%s' "$DEST")"
    [[ "$path" == "$dest" ]]
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
    # Legacy install.sh layout: only tcp_bbr/tcp_bbrp module lines.
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
    # Legacy install.sh layout: only qdisc=fq and CC=bbrp.
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

choose_target_cc() {
    # choose_target_cc ALLOW_PENDING_BBR
    local allow_pending="${1:-0}" avail want c
    avail="$(available_cc)"
    want="$ORIG_CC"

    if [[ -n "$want" && "$want" != "$CC_NAME" ]]; then
        if grep -qw -- "$want" <<<"$avail"; then
            printf '%s' "$want"
            return 0
        fi
        if [[ "$allow_pending" -eq 1 && "$want" == "bbr" ]]; then
            printf '%s' "bbr"
            return 0
        fi
        warn "original CC '$want' is not available; falling back"
    fi

    for c in bbr cubic; do
        if grep -qw -- "$c" <<<"$avail"; then
            printf '%s' "$c"
            return 0
        fi
        if [[ "$allow_pending" -eq 1 && "$c" == "bbr" ]]; then
            printf '%s' "bbr"
            return 0
        fi
    done
    return 1
}

ensure_bbr_available() {
    grep -qw bbr <<<"$(available_cc)" && return 0
    command -v modprobe >/dev/null 2>&1 || return 1
    modprobe tcp_bbr >/dev/null 2>&1 || return 1
    grep -qw bbr <<<"$(available_cc)"
}

detect_active_services() {
    SERVICE_TARGETS=()
    command -v systemctl >/dev/null 2>&1 || return 0
    local s
    for s in "${KNOWN_SERVICES[@]}"; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            SERVICE_TARGETS+=("$s")
        fi
    done
}

build_service_targets() {
    SERVICE_TARGETS=()
    if [[ "$RESTART_MODE" == "none" ]]; then
        return 0
    fi

    if (( STATE_VALID )); then
        if (( ${#SERVICES_RESTARTED[@]} > 0 )); then
            SERVICE_TARGETS=("${SERVICES_RESTARTED[@]}")
        elif (( ${#SERVICES_TO_RESTART[@]} > 0 )) && { (( CC_APPLIED )) || (( RUNTIME_CHANGED )) || (( RUNTIME_WILL_SWITCH )) || [[ "$RESTART_MODE" == "force" ]]; }; then
            SERVICE_TARGETS=("${SERVICES_TO_RESTART[@]}")
        fi
    else
        detect_active_services
    fi
}

service_list_string() {
    if (( ${#SERVICE_TARGETS[@]} == 0 )); then
        printf 'none'
    else
        printf '%s' "${SERVICE_TARGETS[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Mutating helpers (all guard against --dry-run at the call site)
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
}

create_safety_snapshot() {
    (( DRY_RUN )) && return 0
    SAFETY_DIR="$BACKUP_ROOT/rollback-$STAMP"
    if ! install -d -m 700 "$SAFETY_DIR"; then
        warn "cannot create safety snapshot in $BACKUP_ROOT; continuing without one"
        SAFETY_DIR=""
        return 0
    fi
    local f base
    for f in "$MODULES_CONF" "$SYSCTL_CONF" "$DEST"; do
        [[ -e "$f" || -L "$f" ]] || continue
        base="$(basename -- "$f")"
        if ! cp -a -- "$f" "$SAFETY_DIR/$base" 2>/dev/null; then
            warn "could not copy $f into $SAFETY_DIR"
        fi
    done
    {
        printf 'created_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'rollback_version=%s\n' "$SCRIPT_VERSION"
        printf 'state=%s\n' "${STATE_DIR:-none}"
        printf 'kernel=%s\n' "$KVER"
        printf 'orig_cc=%s\n' "${ORIG_CC:-unknown}"
        printf 'orig_qdisc=%s\n' "${ORIG_QDISC:-unknown}"
    } > "$SAFETY_DIR/README" 2>/dev/null || true
    chmod 600 "$SAFETY_DIR/README" 2>/dev/null || true
    ok "safety copy: $SAFETY_DIR"
}

remove_path() {
    local path="$1"
    if (( DRY_RUN )); then
        printf '  [DRY] remove %s\n' "$path"
        return 0
    fi
    if rm -f -- "$path"; then
        return 0
    fi
    warn "could not remove $path"
    return 1
}

copy_path() {
    local src="$1" dest="$2"
    if (( DRY_RUN )); then
        printf '  [DRY] restore %s -> %s\n' "$src" "$dest"
        return 0
    fi
    if atomic_restore "$src" "$dest"; then
        return 0
    fi
    warn "could not restore $src to $dest"
    return 1
}

update_state_status() {
    local new_status="$1" meta tmp
    (( STATE_VALID )) || return 0
    (( DRY_RUN )) && return 0
    [[ -n "$STATE_DIR" ]] || return 0
    meta="$STATE_DIR/meta.env"
    [[ -f "$meta" ]] || return 0

    tmp="$(mktemp "$STATE_DIR/.meta.XXXXXX")" || return 1
    if ! cp -a -- "$meta" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    {
        printf '\n# rollback %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'STATUS=%q\n' "$new_status"
        printf 'ROLLBACK_VERSION=%q\n' "$SCRIPT_VERSION"
        printf 'ROLLBACK_AT=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'ROLLBACK_WARNINGS=%q\n' "$WARN_COUNT"
    } >> "$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$meta"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

compute_runtime_plan() {
    local cur qd
    cur="$(current_cc)"
    if [[ -z "$cur" ]]; then
        warn "cannot read the current congestion-control setting"
    fi

    RUNTIME_WILL_SWITCH=0
    if [[ "$cur" == "$CC_NAME" ]]; then
        RUNTIME_WILL_SWITCH=1
    elif (( STATE_VALID && CC_APPLIED == 1 )) && [[ -n "$TARGET_CC" && "$cur" != "$TARGET_CC" ]]; then
        RUNTIME_WILL_SWITCH=1
    fi
    if (( AUTO && CC_APPLIED == 0 )) && [[ "$cur" != "$CC_NAME" ]]; then
        # The installer never committed the runtime change; leave it alone.
        RUNTIME_WILL_SWITCH=0
    fi

    RUNTIME_WILL_QDISC=0
    qd="$(current_qdisc)"
    if (( WANT_FQ )) && [[ -n "$ORIG_QDISC" && "$qd" != "$ORIG_QDISC" ]]; then
        RUNTIME_WILL_QDISC=1
    fi

    RUNTIME_WILL_CHANGE=0
    if (( RUNTIME_WILL_SWITCH || RUNTIME_WILL_QDISC )); then
        RUNTIME_WILL_CHANGE=1
    fi
}

config_action_text() {
    local dest="$1" backup="$2" had="$3" managed_fn="$4" label="$5"
    if (( KEEP_CONFIG )); then
        printf 'keep    %s (requested)' "$label"
        return 0
    fi
    if (( had )); then
        if [[ -f "$backup" ]]; then
            printf 'restore %s from %s' "$label" "$backup"
        else
            printf 'BROKEN  %s: backup %s is missing' "$label" "$backup"
        fi
        return 0
    fi
    if [[ -e "$dest" || -L "$dest" ]]; then
        if "$managed_fn" "$dest"; then
            printf 'remove  %s (managed by install.sh)' "$label"
        elif (( FORCE )); then
            printf 'remove  %s (--force, contents not recognised)' "$label"
        else
            printf 'leave   %s (not managed; will not delete)' "$label"
        fi
    else
        printf 'absent  %s' "$label"
    fi
}

module_file_safe_to_change() {
    if module_hash_matches; then
        return 0
    fi
    if [[ -z "$INSTALLED_KO_SHA256" ]]; then
        local name
        name="$(modinfo -F name "$DEST" 2>/dev/null || true)"
        [[ "$name" == "$MODULE_NAME" ]] && return 0
    fi
    return 1
}

module_action_text() {
    if (( RUNTIME_ONLY || KEEP_CONFIG || KEEP_MODULE )); then
        printf 'keep    %s (requested)' "$DEST"
        return 0
    fi
    if (( REMOVE_MODULE )); then
        if [[ -e "$DEST" || -L "$DEST" ]]; then
            printf 'remove  %s (--remove/--purge)' "$DEST"
        else
            printf 'absent  %s' "$DEST"
        fi
        return 0
    fi
    if (( HAD_DEST )); then
        if [[ -f "$STATE_DIR/tcp_bbrp.ko.orig" ]]; then
            printf 'restore %s from the snapshot' "$DEST"
        else
            printf 'BROKEN  %s: original module backup is missing' "$DEST"
        fi
        return 0
    fi
    if [[ -e "$DEST" || -L "$DEST" ]]; then
        printf 'remove  %s (not present before install)' "$DEST"
    else
        printf 'absent  %s' "$DEST"
    fi
}

print_plan() {
    section "Rollback plan"
    if (( STATE_VALID )); then
        printf '  snapshot:    %s\n' "$STATE_DIR"
        printf '  status:      %s\n' "${STATE_STATUS:-unknown}"
        printf '  snapshot OS: %s %s, kernel %s (%s)\n' \
            "${DISTRO_ID:-unknown}" "${DISTRO_VERSION:-unknown}" "$KVER" "${ARCH:-?}"
        if [[ "$KVER" != "$(uname -r)" ]]; then
            printf '  note:        running kernel %s differs from the snapshot kernel\n' "$(uname -r)"
        fi
    else
        printf '  snapshot:    none (conservative no-state fallback)\n'
        printf '  note:        the original CC/qdisc cannot be recovered exactly\n'
    fi
    printf '  running:     cc=%s qdisc=%s module=%s\n' \
        "$(current_cc)" "$(current_qdisc)" "$(module_is_loaded && printf loaded || printf 'not loaded')"

    printf '  runtime:     '
    if (( RUNTIME_WILL_SWITCH )); then
        printf 'switch %s -> %s' "$(current_cc)" "$TARGET_CC"
    else
        printf 'leave %s unchanged' "$(current_cc)"
    fi
    if (( RUNTIME_WILL_QDISC )); then
        printf '; qdisc %s -> %s' "$(current_qdisc)" "$ORIG_QDISC"
    fi
    printf '\n'

    printf '  modules.d:   %s\n' "$(config_action_text "$MODULES_CONF" "$STATE_DIR/modules-load.conf" "$HAD_MODULES_CONF" is_managed_modules_conf "$MODULES_CONF")"
    printf '  sysctl.d:    %s\n' "$(config_action_text "$SYSCTL_CONF" "$STATE_DIR/sysctl.conf" "$HAD_SYSCTL_CONF" is_managed_sysctl_conf "$SYSCTL_CONF")"
    printf '  module file: %s\n' "$(module_action_text)"

    if (( RUNTIME_ONLY || KEEP_CONFIG )); then
        printf '  service:     restart %s (module stays loaded)\n' "$(service_list_string)"
    elif module_is_loaded; then
        printf '  service:     restart %s; then unload %s\n' "$(service_list_string)" "$MODULE_NAME"
    else
        printf '  service:     restart %s\n' "$(service_list_string)"
    fi

    if (( RESET_ROUTE )); then
        printf '  route:       strip initcwnd/initrwnd from the default route\n'
    fi
    if (( PURGE )); then
        printf '  purge:       delete %s after a successful rollback\n' "$STATE_DIR"
    else
        printf '  state:       keep %s for audit\n' "${STATE_DIR:-none}"
    fi
    if (( FORCE )); then
        printf '  force:       safety refusals are overridden\n'
    fi
    printf '\n'
}

confirm_plan() {
    (( ASSUME_YES )) && return 0
    if [[ ! -t 0 ]]; then
        usage_die "no terminal available for confirmation; use --yes"
    fi
    local ans=""
    printf 'Proceed with this rollback? [y/N] '
    read -r ans || true
    case "$ans" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------

set_sysctl_value() {
    local key="$1" value="$2" path out
    if command -v sysctl >/dev/null 2>&1; then
        if out="$(sysctl -w "$key=$value" 2>&1)"; then
            return 0
        fi
        err "sysctl -w $key=$value failed: $out"
        return 1
    fi
    path="/proc/sys/${key//./\/}"
    if [[ ! -w "$path" ]]; then
        err "cannot write $path"
        return 1
    fi
    if ! printf '%s' "$value" > "$path" 2>/dev/null; then
        err "cannot write $value to $path"
        return 1
    fi
}

apply_runtime_change() {
    local cur target qd
    if (( ! RUNTIME_WILL_CHANGE )); then
        info "runtime CC/qdisc already match the rollback target"
        return 0
    fi

    if (( RUNTIME_WILL_SWITCH )); then
        if (( DRY_RUN )); then
            target="$TARGET_CC"
        else
            ensure_bbr_available || true
            if ! target="$(choose_target_cc 0)"; then
                critical "neither bbr nor cubic is available; refusing to change files"
                return 1
            fi
        fi
        if [[ -z "$target" ]]; then
            critical "no usable fallback congestion-control algorithm"
            return 1
        fi
        TARGET_CC="$target"
        cur="$(current_cc)"
        if [[ "$cur" == "$TARGET_CC" ]]; then
            info "runtime CC is already $TARGET_CC"
        elif (( DRY_RUN )); then
            printf '  [DRY] set net.ipv4.tcp_congestion_control=%s\n' "$TARGET_CC"
            RUNTIME_CHANGED=1
        else
            if ! set_sysctl_value net.ipv4.tcp_congestion_control "$TARGET_CC"; then
                critical "could not switch the runtime CC to $TARGET_CC; no files were changed"
                return 1
            fi
            cur="$(current_cc)"
            if [[ "$cur" != "$TARGET_CC" ]]; then
                critical "runtime CC is '$cur' after the switch, expected '$TARGET_CC'; no files were changed"
                return 1
            fi
            ok "runtime CC: $TARGET_CC"
            RUNTIME_CHANGED=1
        fi
    fi

    if (( RUNTIME_WILL_QDISC )); then
        qd="$(current_qdisc)"
        if (( DRY_RUN )); then
            printf '  [DRY] set net.core.default_qdisc=%s\n' "$ORIG_QDISC"
        elif [[ "$qd" == "$ORIG_QDISC" ]]; then
            info "runtime qdisc is already $ORIG_QDISC"
        elif set_sysctl_value net.core.default_qdisc "$ORIG_QDISC"; then
            ok "runtime qdisc: $ORIG_QDISC"
        else
            warn "could not restore the qdisc to $ORIG_QDISC; fq remains in use"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

restart_services() {
    section "Services"
    if [[ "$RESTART_MODE" == "none" ]]; then
        info "service restart skipped by --no-restart"
        return 0
    fi
    if (( ${#SERVICE_TARGETS[@]} == 0 )); then
        info "no services to restart"
        return 0
    fi
    if (( ! RUNTIME_CHANGED )) && [[ "$RESTART_MODE" != "force" ]] && ! module_is_loaded; then
        info "runtime CC did not change and the module is not loaded; no restart needed"
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found; services were not restarted"
        return 0
    fi

    local s
    for s in "${SERVICE_TARGETS[@]}"; do
        if ! systemctl is-active --quiet "$s" 2>/dev/null; then
            info "$s is not active; not starting it"
            continue
        fi
        if (( DRY_RUN )); then
            printf '  [DRY] systemctl restart %s\n' "$s"
            continue
        fi
        if timeout 90 systemctl restart "$s" 2>/dev/null; then
            ok "restarted $s"
        else
            SERVICE_FAILURES+=("$s")
            warn "failed to restart $s"
        fi
    done

    if (( ${#SERVICE_FAILURES[@]} > 0 )); then
        warn "some services failed to restart: ${SERVICE_FAILURES[*]}"
    elif (( ! DRY_RUN )); then
        # Give the kernel a moment to release references to the module.
        sleep 2
    fi
}

# ---------------------------------------------------------------------------
# Files and module
# ---------------------------------------------------------------------------

process_config_file() {
    local dest="$1" backup="$2" had="$3" managed_fn="$4" label="$5"
    if (( KEEP_CONFIG )); then
        info "keeping $label (requested)"
        return 0
    fi

    if (( had )); then
        if [[ ! -f "$backup" ]]; then
            critical "$label: snapshot backup $backup is missing; leaving it untouched"
            return 1
        fi
        if copy_path "$backup" "$dest"; then
            (( DRY_RUN )) || ok "restored $label"
        else
            critical "could not restore $label"
            return 1
        fi
        return 0
    fi

    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
        info "$label is absent"
        return 0
    fi

    if "$managed_fn" "$dest"; then
        if remove_path "$dest"; then
            (( DRY_RUN )) || ok "removed $label"
        else
            critical "could not remove $label"
            return 1
        fi
        return 0
    fi

    if (( FORCE )); then
        warn "forcing removal of unrecognised $label"
        if remove_path "$dest"; then
            :
        else
            critical "could not remove $label"
            return 1
        fi
        return 0
    fi

    warn "$label was not created by install.sh; leaving it untouched (use --force to delete)"
    return 0
}

unload_module() {
    if (( RUNTIME_ONLY || KEEP_CONFIG )); then
        if module_is_loaded; then
            info "$MODULE_NAME stays loaded (requested)"
        fi
        return 0
    fi
    if ! module_is_loaded; then
        ok "$MODULE_NAME is not loaded"
        return 0
    fi
    if ! loaded_module_matches_state; then
        warn "$MODULE_NAME is loaded but does not match the selected snapshot ($DEST); not unloading it"
        return 1
    fi

    if (( MODULE_UNLOAD_SUPPORTED == 0 )); then
        warn "$MODULE_NAME cannot be unloaded on this kernel; reboot to finish"
        return 1
    fi
    if (( DRY_RUN )); then
        printf '  [DRY] modprobe -r %s\n' "$MODULE_NAME"
        return 0
    fi

    local out
    for _ in 1 2 3 4 5; do
        if command -v modprobe >/dev/null 2>&1; then
            if out="$(timeout 30 modprobe -r "$MODULE_NAME" 2>&1)"; then
                ok "$MODULE_NAME unloaded"
                return 0
            fi
        elif command -v rmmod >/dev/null 2>&1; then
            if out="$(timeout 30 rmmod "$MODULE_NAME" 2>&1)"; then
                ok "$MODULE_NAME unloaded"
                return 0
            fi
        else
            warn "neither modprobe nor rmmod is available; cannot unload $MODULE_NAME"
            return 1
        fi
        sleep 2
    done

    [[ -n "${out:-}" ]] && info "last unload error: $out"
    warn "$MODULE_NAME is still in use; it will no longer be loaded after the next boot if boot persistence was removed or restored"
    return 1
}

run_depmod() {
    (( DRY_RUN )) && return 0
    if ! command -v depmod >/dev/null 2>&1; then
        warn "depmod not found; module dependencies were not refreshed"
        return 0
    fi
    if depmod -a "$KVER" 2>/dev/null; then
        ok "depmod updated for $KVER"
    else
        warn "depmod -a $KVER failed; the module index may be stale"
    fi
}

handle_module_file() {
    if (( RUNTIME_ONLY || KEEP_CONFIG || KEEP_MODULE )); then
        info "keeping $DEST (requested)"
        return 0
    fi

    local exists=0 safe=0
    [[ -e "$DEST" || -L "$DEST" ]] && exists=1
    module_file_safe_to_change && safe=1

    if (( REMOVE_MODULE )); then
        if (( exists == 0 )); then
            info "$DEST is already absent"
            return 0
        fi
        if (( ! safe && ! FORCE )); then
            warn "$DEST does not match the recorded module and was not removed (use --force)"
            return 1
        fi
        if remove_path "$DEST"; then
            (( DRY_RUN )) || ok "removed $DEST"
        else
            critical "could not remove $DEST"
            return 1
        fi
        (( ! DRY_RUN )) && run_depmod
        return 0
    fi

    if (( HAD_DEST )); then
        local backup="$STATE_DIR/tcp_bbrp.ko.orig"
        if [[ ! -f "$backup" ]]; then
            critical "original module backup $backup is missing; leaving $DEST untouched"
            return 1
        fi
        if [[ -f "$DEST" ]] && cmp -s -- "$backup" "$DEST"; then
            info "$DEST already matches the pre-install copy"
            return 0
        fi
        if (( exists && ! safe && ! FORCE )); then
            warn "$DEST changed after installation; not overwriting it (use --force)"
            return 1
        fi
        if copy_path "$backup" "$DEST"; then
            (( DRY_RUN )) || ok "restored the pre-install module file"
        else
            critical "could not restore the pre-install module file"
            return 1
        fi
        (( ! DRY_RUN )) && run_depmod
        return 0
    fi

    if (( exists == 0 )); then
        info "$DEST is already absent"
        return 0
    fi
    if (( ! safe && ! FORCE )); then
        warn "$DEST does not look like the installed module; not removing it (use --force)"
        return 1
    fi
    if remove_path "$DEST"; then
        (( DRY_RUN )) || ok "removed the installed module file"
    else
        critical "could not remove $DEST"
        return 1
    fi
    (( ! DRY_RUN )) && run_depmod
}

# ---------------------------------------------------------------------------
# Route and state cleanup
# ---------------------------------------------------------------------------

reset_default_route() {
    (( RESET_ROUTE )) || return 0
    section "Default route"
    if ! command -v ip >/dev/null 2>&1; then
        warn "ip command not found; the default route was not reset"
        return 0
    fi
    local line
    line="$(ip route show default 2>/dev/null | head -n 1 || true)"
    if [[ -z "$line" ]]; then
        warn "no default route found; nothing to reset"
        return 0
    fi

    local -a tokens=() args=()
    local tok skip=0
    read -r -a tokens <<<"$line"
    for tok in "${tokens[@]}"; do
        if (( skip )); then
            skip=0
            continue
        fi
        case "$tok" in
            initcwnd|initrwnd)
                skip=1
                continue
                ;;
        esac
        args+=("$tok")
    done

    if (( ${#args[@]} == 0 )); then
        warn "could not parse the default route; it was not reset"
        return 0
    fi
    if (( DRY_RUN )); then
        printf '  [DRY] ip route replace %s\n' "${args[*]}"
        return 0
    fi
    if ip route replace "${args[@]}"; then
        ok "default route reset without initcwnd/initrwnd"
    else
        warn "could not reset the default route"
    fi
}

purge_state() {
    (( PURGE )) || return 0
    if (( ! STATE_VALID )); then
        info "no snapshot to purge"
        return 0
    fi
    section "Purge state"
    if (( RUNTIME_ONLY || KEEP_CONFIG )) && (( ! FORCE )); then
        warn "refusing to purge the snapshot while boot files are kept (use --force)"
        return 0
    fi
    if module_is_loaded && (( ! FORCE )); then
        warn "refusing to purge the snapshot while $MODULE_NAME is loaded (use --force)"
        return 0
    fi
    if (( DRY_RUN )); then
        printf '  [DRY] remove %s\n' "$STATE_DIR"
        return 0
    fi

    local current=""
    current="$(readlink -f -- "$STATE_ROOT/current" 2>/dev/null || true)"
    if [[ -n "$current" && "$current" == "$STATE_DIR" ]]; then
        rm -f -- "$STATE_ROOT/current" 2>/dev/null || warn "could not remove $STATE_ROOT/current"
    fi
    if rm -rf -- "$STATE_DIR"; then
        PURGED=1
        ok "removed $STATE_DIR"
    else
        warn "could not remove $STATE_DIR"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    section "Rollback summary"
    printf '  before:      cc=%s qdisc=%s module=%s\n' \
        "${BEFORE_CC:-?}" "${BEFORE_QDISC:-?}" "$([[ ${BEFORE_MODULE:-0} -eq 1 ]] && printf loaded || printf 'not loaded')"
    printf '  after:       cc=%s qdisc=%s module=%s\n' \
        "$(current_cc)" "$(current_qdisc)" "$(module_is_loaded && printf loaded || printf 'not loaded')"
    printf '  snapshot:    %s\n' "${STATE_DIR:-none}"
    if [[ -n "$SAFETY_DIR" ]]; then
        printf '  safety copy: %s\n' "$SAFETY_DIR"
    fi
    if [[ -n "$LOG_FILE" ]]; then
        printf '  log:         %s\n' "$LOG_FILE"
    fi
    if (( ${#SERVICE_FAILURES[@]} > 0 )); then
        printf '  failed units: %s\n' "${SERVICE_FAILURES[*]}"
    fi
    if (( PURGED )); then
        printf '  state:       purged\n'
    elif (( STATE_VALID )); then
        printf '  state:       kept for audit\n'
    fi
    if (( ${#NEW_PACKAGES[@]} > 0 )); then
        printf '  packages:    build dependencies intentionally kept: %s\n' "${NEW_PACKAGES[*]}"
    fi

    if (( CRITICAL )); then
        printf '\nRollback did not complete cleanly.  Review the messages above.\n'
        if (( STATE_VALID && ! PURGED )); then
            printf 'The snapshot is still available: %s\n' "$STATE_DIR"
        fi
        if module_is_loaded; then
            printf 'If %s is still loaded, reboot after fixing the reported issue.\n' "$MODULE_NAME"
        fi
        return 0
    fi

    if (( RUNTIME_ONLY || KEEP_CONFIG )); then
        printf '\nBoot persistence was kept, so %s will be used again after reboot.\n' "$CC_NAME"
        printf 'Run rollback.sh without --keep-config/--runtime-only to remove it.\n'
    fi
    if module_is_loaded; then
        printf '\n%s is still loaded.  New sockets use %s; existing sockets keep %s\n' \
            "$MODULE_NAME" "$(current_cc)" "$CC_NAME"
        printf 'until they close.  Stop the affected service or reboot, then run:\n'
        printf '  sudo modprobe -r %s\n' "$MODULE_NAME"
    fi

    if (( DRY_RUN )); then
        printf '\nDry run completed; no changes were made.\n'
        return 0
    fi
    if (( WARN_COUNT > 0 )); then
        printf '\nRollback completed with %s warning(s).\n' "$WARN_COUNT"
    else
        printf '\nRollback completed.\n'
    fi
}

rollback_has_work() {
    if (( PURGE && STATE_VALID )); then
        return 0
    fi
    if (( RUNTIME_WILL_CHANGE || RESET_ROUTE )); then
        return 0
    fi
    if (( RUNTIME_ONLY || KEEP_CONFIG )); then
        return 1
    fi
    if (( HAD_MODULES_CONF || HAD_SYSCTL_CONF || HAD_DEST )); then
        return 0
    fi
    if [[ -e "$MODULES_CONF" || -L "$MODULES_CONF" ]]; then
        return 0
    fi
    if [[ -e "$SYSCTL_CONF" || -L "$SYSCTL_CONF" ]]; then
        return 0
    fi
    if module_is_loaded; then
        return 0
    fi
    if [[ -e "$DEST" || -L "$DEST" ]]; then
        return 0
    fi
    return 1
}

main() {
    parse_args "$@"

    if (( LIST_STATES )); then
        list_states
        exit 0
    fi

    check_root
    if [[ "$(uname -s 2>/dev/null || true)" != "Linux" ]]; then
        die "this script only supports Linux"
    fi
    setup_logging
    acquire_lock
    resolve_state_dir

    if [[ -n "$STATE_DIR" ]]; then
        load_state
    else
        init_no_state
    fi
    check_selected_state_safety

    section "tcp_bbrp rollback $SCRIPT_VERSION"
    if (( STATE_VALID )); then
        log "using snapshot $STATE_DIR (status=${STATE_STATUS:-unknown})"
    else
        log "no snapshot found; using conservative fallback"
    fi

    BEFORE_CC="$(current_cc)"
    BEFORE_QDISC="$(current_qdisc)"
    BEFORE_MODULE=0
    module_is_loaded && BEFORE_MODULE=1

    TARGET_CC="$(choose_target_cc 1 || true)"
    if [[ -z "$TARGET_CC" ]]; then
        critical "neither bbr nor cubic is available; cannot restore a safe fallback"
    fi

    compute_runtime_plan
    build_service_targets
    print_plan

    if (( RUNTIME_WILL_SWITCH )) && [[ -z "$TARGET_CC" ]]; then
        print_summary
        exit 1
    fi

    if ! rollback_has_work; then
        info "nothing to roll back: bbrp is not active and no managed files were found"
        # A no-op auto-rollback still has to close the transaction; otherwise the
        # snapshot stays "rolling-back"/"in-progress" and blocks the next install.
        if (( STATE_VALID && ! RUNTIME_ONLY && ! KEEP_CONFIG )); then
            update_state_status "rolled-back" >/dev/null 2>&1 || warn "could not update the state status"
        fi
        exit 0
    fi

    if (( ! ASSUME_YES )); then
        if ! confirm_plan; then
            info "rollback cancelled; nothing was changed"
            exit 0
        fi
    fi

    if (( ! RUNTIME_ONLY && ! KEEP_CONFIG )); then
        create_safety_snapshot
    fi

    section "Restore runtime"
    if ! apply_runtime_change; then
        print_summary
        exit 1
    fi

    restart_services

    section "Unload module"
    unload_module || true

    section "Restore files"
    process_config_file "$MODULES_CONF" "$STATE_DIR/modules-load.conf" "$HAD_MODULES_CONF" \
        is_managed_modules_conf "$MODULES_CONF" || true
    process_config_file "$SYSCTL_CONF" "$STATE_DIR/sysctl.conf" "$HAD_SYSCTL_CONF" \
        is_managed_sysctl_conf "$SYSCTL_CONF" || true
    handle_module_file || true

    reset_default_route
    purge_state

    if (( STATE_VALID && ! DRY_RUN && ! PURGED && ! RUNTIME_ONLY && ! KEEP_CONFIG )); then
        if (( CRITICAL )); then
            update_state_status "rollback-failed" >/dev/null 2>&1 || warn "could not update the state status"
        else
            update_state_status "rolled-back" >/dev/null 2>&1 || warn "could not update the state status"
        fi
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
