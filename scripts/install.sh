#!/usr/bin/env bash
# One-click installer for the tcp_bbrp out-of-tree kernel module.
#
# Supported: Debian and Ubuntu (and closely related Debian derivatives).
# The original in-tree tcp_bbr module is never overwritten.  The new module
# registers a separate congestion-control algorithm named "bbrp", so the
# original "bbr" and "cubic" remain available as fallbacks.
#
# Safety model
# ------------
# * Preflight checks do not change persistent system state.
# * The module is built and validated before anything is installed.
# * A state snapshot is written to /var/backups/tcp-bbrp/<stamp>/ before the
#   first mutation, and /var/lib/tcp-bbrp/current points at it.
# * Every mutation after that point is protected by an ERR/INT/TERM trap that
#   automatically calls rollback.sh if a step fails.
# * The module is smoke-tested on loopback before it is made the default CC.
# * The only failure this script cannot recover from is a kernel panic or
#   hard lock-up caused by a module bug.  The script refuses to run when
#   kernel.panic_on_oops/panic_on_warn is enabled unless --accept-risk is
#   given, and it recommends a snapshot/console before installing.
#
# Exit codes: 0 = success, 1 = failure, 2 = usage error,
#             3 = installed but a proxy service failed to restart.
#
# License: GPL-2.0 (same as the rest of the repository).

set -Eeuo pipefail
umask 022
export LC_ALL=C

SCRIPT_VERSION="2.0.0"
SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    SELF="$(readlink -f -- "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

MODULE_NAME="tcp_bbrp"
CC_NAME="bbrp"
MARKER="# Managed by tcp-bbrp install.sh"

KVER="$(uname -r)"
ARCH="$(uname -m)"
KDIR="/lib/modules/$KVER/build"
DEST_DIR="/lib/modules/$KVER/extra"
DEST="$DEST_DIR/$MODULE_NAME.ko"
MODULES_CONF="/etc/modules-load.d/tcp_bbrp.conf"
SYSCTL_CONF="/etc/sysctl.d/zz-bbrp.conf"

STATE_ROOT="/var/lib/tcp-bbrp"
BACKUP_ROOT="/var/backups/tcp-bbrp"
LOG_ROOT="/var/log/tcp-bbrp"
LOCK_FILE="/run/lock/tcp-bbrp.lock"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"

# Command-line options.
KO_INPUT=""
SOURCE_INPUT=""
FORCE_BUILD=0
INSTALL_DEPS=1
ASSUME_YES=0
DRY_RUN=0
RUN_SMOKE=1
RESTART_MODE="auto"
ACCEPT_RISK=0
AUTO_ROLLBACK=1
KEEP_BUILD_DIR=0
VERBOSE=0
RESTART_SERVICES=()

# Runtime state.
DISTRO_ID="unknown"
DISTRO_VERSION="unknown"
DISTRO_NAME="unknown"
CONFIG_FILE=""
TMP_CONFIG=""
HEADERS_OK=0
NEED_BUILD=1
CANDIDATE_KO=""
KO_PATH=""
BUILD_DIR=""
BUILD_LOG=""
TMP_SRC=""
APT_LOG=""
APT_UPDATED=0
MISSING_PKGS=()
NEW_PACKAGES=()
WANT_FQ=1
FQ_CONFIGURED=1
MODULE_UNLOAD_SUPPORTED=1
SIG_ENFORCE=0
SECURE_BOOT=0
AVAILABLE_CC=""
CURRENT_STATE_DIR=""
ALREADY_INSTALLED=0
DETECTED_SERVICES=()
SERVICES_TO_RESTART=()
SERVICES_RESTARTED=()
SERVICE_FAILURES=()

# State-file fields.
META_VERSION=1
STATUS=""
CREATED_AT=""
UPDATED_AT=""
ORIG_CC="unknown"
ORIG_QDISC="unknown"
ORIG_CC_AVAILABLE=0
ORIG_MODULE_LOADED=0
HAD_MODULES_CONF=0
HAD_SYSCTL_CONF=0
HAD_DEST=0
INSTALLED_KO_SHA256=""
CC_APPLIED=0
TRANSACTION_ACTIVE=0
BACKUP_DIR=""
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
    printf '  [WARN] %s\n' "$*" >&2
}

err() {
    printf 'ERROR: %s\n' "$*" >&2
}

die() {
    err "$*"
    if [[ ${TRANSACTION_ACTIVE:-0} -eq 1 ]]; then
        on_error 1 "${BASH_LINENO[0]:-0}" "die: $*"
    fi
    exit 1
}

usage() {
    cat <<'EOF'
tcp_bbrp one-click installer (Debian / Ubuntu)

Usage:
  sudo ./scripts/install.sh [options]

What it does:
  1. Runs read-only preflight checks (distro, kernel, headers, Secure Boot,
     lockdown, panic settings, disk/memory, existing installation, sysctl
     ordering, modprobe blacklists, service state).
  2. Installs only the missing build dependencies with apt-get.
  3. Uses a matching prebuilt tcp_bbrp.ko if present, otherwise builds from
     the checked-in source.  If that source is incompatible with the running
     kernel, it can install the matching linux-source package and regenerate.
  4. Backs up existing module/config files and records the original runtime
     congestion-control state in /var/backups/tcp-bbrp/<stamp>/.
  5. Installs to /lib/modules/$(uname -r)/extra, runs depmod/modprobe,
     verifies registration, and runs a loopback smoke test.
  6. Writes boot persistence, applies the runtime sysctl, and restarts known
     proxy services that were active so their listeners use bbrp.
  7. On any failure after the snapshot, automatically invokes rollback.sh.

Options:
  --ko PATH              Use this prebuilt module (still validated).
  --source PATH          Regenerate from a kernel tcp_bbr.c at PATH.
  --rebuild              Ignore ./tcp_bbrp.ko and build from source.
  --no-deps              Never call apt-get; fail if dependencies are missing.
  -y, --yes              Non-interactive; accept the linux-source fallback
                         prompt.  Missing apt dependencies are installed
                         automatically unless --no-deps is given.
  --dry-run              Run checks, print the plan, change nothing.
  --no-smoke             Skip the loopback smoke test (not recommended).
  --no-restart           Do not restart any proxy service.
  --restart SERVICE      Restart this systemd unit after install (repeatable).
                         If given, automatic service detection is disabled.
  --accept-risk          Continue when panic_on_oops/panic_on_warn is enabled.
  --no-auto-rollback     Keep the failed installation for debugging instead of
                         automatically calling rollback.sh (dangerous).
  --keep-build-dir       Keep the temporary build directory for inspection.
  --verbose              Print more diagnostic detail.
  -h, --help             Show this help.

Examples:
  sudo ./scripts/install.sh
  sudo ./scripts/install.sh --dry-run
  sudo ./scripts/install.sh --restart x-ui --restart sing-box
  sudo ./scripts/install.sh --ko /root/tcp_bbrp.ko
  sudo ./scripts/install.sh --source /usr/src/linux/net/ipv4/tcp_bbr.c

Rollback:
  sudo ./scripts/rollback.sh                 # restore the previous state
  sudo ./scripts/rollback.sh --list          # list saved states
  sudo ./scripts/rollback.sh --keep-config   # runtime switch only

Safety notes:
  * Existing SSH sessions are not affected by changing the default CC, but a
    buggy kernel module can still panic the host.  Use a VPS snapshot and
    console access for production machines.
  * Secure Boot and kernel lockdown must allow unsigned out-of-tree modules.
  * After a kernel upgrade the module must be rebuilt; boot falls back to bbr
    or cubic because the old module cannot be loaded.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --ko)
                [[ $# -ge 2 ]] || { usage; exit 2; }
                KO_INPUT="$2"
                shift 2
                ;;
            --source)
                [[ $# -ge 2 ]] || { usage; exit 2; }
                SOURCE_INPUT="$2"
                shift 2
                ;;
            --rebuild)
                FORCE_BUILD=1
                shift
                ;;
            --no-deps)
                INSTALL_DEPS=0
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
            --no-smoke)
                RUN_SMOKE=0
                shift
                ;;
            --no-restart)
                if [[ "$RESTART_MODE" == "manual" ]]; then
                    err "--no-restart and --restart are mutually exclusive"
                    exit 2
                fi
                RESTART_MODE="none"
                RESTART_SERVICES=()
                shift
                ;;
            --restart)
                [[ $# -ge 2 ]] || { usage; exit 2; }
                if [[ "$RESTART_MODE" == "none" ]]; then
                    err "--no-restart and --restart are mutually exclusive"
                    exit 2
                fi
                if [[ ! "$2" =~ ^[A-Za-z0-9_.@:-]+$ ]]; then
                    err "invalid service name: $2"
                    exit 2
                fi
                RESTART_MODE="manual"
                RESTART_SERVICES+=("$2")
                shift 2
                ;;
            --accept-risk)
                ACCEPT_RISK=1
                shift
                ;;
            --no-auto-rollback)
                AUTO_ROLLBACK=0
                shift
                ;;
            --keep-build-dir)
                KEEP_BUILD_DIR=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                err "unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    if [[ $# -gt 0 ]]; then
        err "unexpected argument(s): $*"
        usage
        exit 2
    fi

    if [[ -n "$KO_INPUT" && -n "$SOURCE_INPUT" ]]; then
        err "--ko and --source are mutually exclusive"
        exit 2
    fi
    if [[ -n "$KO_INPUT" && $FORCE_BUILD -eq 1 ]]; then
        err "--ko and --rebuild are mutually exclusive"
        exit 2
    fi
}

setup_logging() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    install -d -m 750 "$LOG_ROOT" 2>/dev/null || {
        warn "cannot create $LOG_ROOT; continuing without a log file"
        return 0
    }
    LOG_FILE="$LOG_ROOT/install-$STAMP.log"
    if ! ( umask 077; : > "$LOG_FILE" ) 2>/dev/null; then
        warn "cannot write $LOG_FILE; continuing without a log file"
        LOG_FILE=""
        return 0
    fi
    # Keep console output and a persistent audit trail.
    exec > >(tee -a "$LOG_FILE") 2>&1
}

acquire_lock() {
    [[ $DRY_RUN -eq 1 ]] && return 0
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

release_lock() {
    if [[ -n "${LOCK_DIR:-}" && -d "${LOCK_DIR:-}" ]]; then
        rm -f -- "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir -- "$LOCK_DIR" 2>/dev/null || true
        LOCK_DIR=""
    fi
    # Closing the flock descriptor releases the kernel lock.  Do not redirect
    # stderr here: "exec" redirections would otherwise persist for the rest of
    # the script and silence the auto-rollback output.
    exec 9>&- || true
}

cleanup() {
    if [[ -n "${TMP_CONFIG:-}" && -f "${TMP_CONFIG:-}" ]]; then
        rm -f -- "$TMP_CONFIG" 2>/dev/null || true
    fi
    if [[ -n "${TMP_SRC:-}" && -d "${TMP_SRC:-}" ]]; then
        rm -rf -- "$TMP_SRC" 2>/dev/null || true
    fi
    if [[ -n "${BUILD_DIR:-}" && -d "${BUILD_DIR:-}" && ${KEEP_BUILD_DIR:-0} -eq 0 ]]; then
        rm -rf -- "$BUILD_DIR" 2>/dev/null || true
    fi
    release_lock
}

on_error() {
    local rc="${1:-1}"
    local line="${2:-?}"
    local cmd="${3:-unknown}"
    trap - ERR INT TERM HUP
    set +e

    err "command failed (exit $rc) at line $line: $cmd"

    if [[ ${TRANSACTION_ACTIVE:-0} -eq 1 ]]; then
        TRANSACTION_ACTIVE=0
        release_lock
        if [[ ${AUTO_ROLLBACK:-1} -eq 1 ]]; then
            warn "installation failed after changes were made; starting automatic rollback"
            STATUS="rolling-back"
            write_meta >/dev/null 2>&1 || true
            local rb_rc=0
            bash "$SCRIPT_DIR/rollback.sh" --auto --yes --state "$BACKUP_DIR" || rb_rc=$?
            case "$rb_rc" in
                0)
                    err "installation failed; rollback completed and the previous state was restored"
                    ;;
                3)
                    err "installation failed; rollback completed with warnings"
                    err "review the rollback output above, then run: sudo $SCRIPT_DIR/rollback.sh --state $BACKUP_DIR"
                    ;;
                *)
                    err "installation failed AND automatic rollback failed (exit $rb_rc)"
                    print_manual_recovery
                    ;;
            esac
        else
            err "automatic rollback disabled by --no-auto-rollback"
            print_manual_recovery
        fi
    else
        info "no automatic rollback: the transaction was not active (pre-snapshot or already committed)"
    fi

    exit "$rc"
}

on_signal() {
    local sig="$1"
    trap - INT TERM HUP
    warn "received SIG$sig"
    on_error 130 0 "signal SIG$sig"
}

trap 'rc=$?; on_error "$rc" "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# ---------------------------------------------------------------------------
# Generic checks
# ---------------------------------------------------------------------------

version_ge() {
    # version_ge A B  ->  true when A >= B
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

add_missing_pkg() {
    local pkg="$1" existing
    for existing in "${MISSING_PKGS[@]:-}"; do
        [[ "$existing" == "$pkg" ]] && return 0
    done
    MISSING_PKGS+=("$pkg")
}

free_kb() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

check_disk_space() {
    local need_mb="$1" path="$2" kb
    while [[ ! -e "$path" && "$path" != "/" ]]; do
        path="$(dirname -- "$path")"
    done
    kb="$(free_kb "$path" || true)"
    [[ -n "$kb" ]] || return 0
    (( kb >= need_mb * 1024 ))
}

detect_headers() {
    HEADERS_OK=0
    [[ -d "$KDIR" && -f "$KDIR/Makefile" ]] || return 0
    local rel=""
    if [[ -r "$KDIR/include/config/kernel.release" ]]; then
        rel="$(cat "$KDIR/include/config/kernel.release" 2>/dev/null || true)"
    fi
    if [[ -n "$rel" && "$rel" != "$KVER" ]]; then
        warn "headers in $KDIR are for kernel '$rel', not '$KVER'"
        return 0
    fi
    if [[ ! -f "$KDIR/include/generated/autoconf.h" ]]; then
        warn "kernel build tree is incomplete: $KDIR/include/generated/autoconf.h is missing"
        return 0
    fi
    HEADERS_OK=1
    return 0
}

detect_kernel_config() {
    CONFIG_FILE=""
    if [[ -n "${TMP_CONFIG:-}" ]]; then
        rm -f -- "$TMP_CONFIG" 2>/dev/null || true
        TMP_CONFIG=""
    fi
    if [[ -r "/boot/config-$KVER" ]]; then
        CONFIG_FILE="/boot/config-$KVER"
    elif [[ -r "$KDIR/.config" ]]; then
        CONFIG_FILE="$KDIR/.config"
    elif [[ -r /proc/config.gz ]] && command -v gzip >/dev/null 2>&1; then
        TMP_CONFIG="$(mktemp "${TMPDIR:-/var/tmp}/tcp-bbrp-config.XXXXXX")" || return 1
        if gzip -dc /proc/config.gz > "$TMP_CONFIG" 2>/dev/null; then
            CONFIG_FILE="$TMP_CONFIG"
        else
            rm -f -- "$TMP_CONFIG"
            TMP_CONFIG=""
            return 1
        fi
    fi
    return 0
}

config_value() {
    local key="CONFIG_$1"
    [[ -n "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || return 1
    awk -F= -v k="$key" '$1 == k {v=$2} END {print v}' "$CONFIG_FILE"
}

config_enabled() {
    local v
    v="$(config_value "$1" || true)"
    [[ "$v" == "y" || "$v" == "m" ]]
}

config_builtin() {
    [[ "$(config_value "$1" || true)" == "y" ]]
}

detect_fq() {
    FQ_CONFIGURED=1
    if [[ -n "$CONFIG_FILE" ]] && ! config_enabled NET_SCH_FQ; then
        FQ_CONFIGURED=0
    fi
    WANT_FQ=1
    if command -v modprobe >/dev/null 2>&1; then
        if ! modprobe -n -v sch_fq >/dev/null 2>&1; then
            WANT_FQ=0
        fi
    elif [[ $FQ_CONFIGURED -eq 0 ]]; then
        WANT_FQ=0
    fi
    if [[ $WANT_FQ -eq 0 ]]; then
        warn "sch_fq is not available; net.core.default_qdisc will not be changed"
    fi
}

detect_secure_boot() {
    SECURE_BOOT=0
    if command -v mokutil >/dev/null 2>&1; then
        local sbout=""
        sbout="$(mokutil --sb-state 2>/dev/null || true)"
        if grep -qi 'SecureBoot enabled' <<<"$sbout"; then
            SECURE_BOOT=1
        fi
        return 0
    fi
    if [[ -d /sys/firmware/efi ]]; then
        local var b
        var="$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' -print -quit 2>/dev/null || true)"
        if [[ -n "$var" ]]; then
            b="$(od -An -t u1 -j 4 -N 1 "$var" 2>/dev/null | tr -d ' \n' || true)"
            [[ "$b" == "1" ]] && SECURE_BOOT=1
        fi
    fi
}

module_is_signed() {
    local ko="$1"
    [[ -n "$(modinfo -F signer "$ko" 2>/dev/null || true)" ]] && return 0
    [[ -n "$(modinfo -F sig_id "$ko" 2>/dev/null || true)" ]] && return 0
    return 1
}

dmesg_tail() {
    if command -v dmesg >/dev/null 2>&1; then
        dmesg 2>/dev/null | tail -30 >&2 || true
    fi
}

current_state_dir() {
    [[ -L "$STATE_ROOT/current" ]] || return 1
    local d
    d="$(readlink -f -- "$STATE_ROOT/current" 2>/dev/null || true)"
    [[ -n "$d" && -d "$d" ]] || return 1
    printf '%s' "$d"
}

read_state_field() {
    local file="$1" key="$2"
    (
        unset STATUS META_VERSION KVER ORIG_CC INSTALLED_KO_SHA256
        # shellcheck disable=SC1090
        . "$file" >/dev/null 2>&1 || exit 1
        case "$key" in
            STATUS) printf '%s' "${STATUS:-}" ;;
            KVER) printf '%s' "${KVER:-}" ;;
            ORIG_CC) printf '%s' "${ORIG_CC:-}" ;;
            INSTALLED_KO_SHA256) printf '%s' "${INSTALLED_KO_SHA256:-}" ;;
            *) return 1 ;;
        esac
    )
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

check_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run this script as root (sudo)"
}

check_os() {
    section "Preflight: operating system"
    [[ -r /etc/os-release ]] || die "/etc/os-release not found; this is not Debian/Ubuntu"
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID $DISTRO_VERSION}"

    case "$DISTRO_ID" in
        debian|ubuntu)
            ;;
        *)
            case " ${ID_LIKE:-} " in
                *debian*|*ubuntu*)
                    warn "Debian derivative detected ($DISTRO_NAME); only Debian/Ubuntu are tested"
                    ;;
                *)
                    die "unsupported distribution '$DISTRO_NAME'; Debian or Ubuntu is required"
                    ;;
            esac
            ;;
    esac

    command -v apt-get >/dev/null 2>&1 || die "apt-get not found; this is not a Debian/Ubuntu system"
    command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query not found"
    command -v sort >/dev/null 2>&1 || die "sort not found"

    if [[ "$DISTRO_ID" == "ubuntu" && "$DISTRO_VERSION" != "unknown" ]]; then
        if ! version_ge "$DISTRO_VERSION" "20.04"; then
            warn "Ubuntu $DISTRO_VERSION is older than the tested baseline (20.04)"
        fi
    elif [[ "$DISTRO_ID" == "debian" && "$DISTRO_VERSION" != "unknown" ]]; then
        if ! version_ge "$DISTRO_VERSION" "11"; then
            warn "Debian $DISTRO_VERSION is older than the tested baseline (11)"
        fi
    fi
    ok "$DISTRO_NAME"
}

check_arch_kernel() {
    section "Preflight: kernel and architecture"
    KVER="$(uname -r)"
    ARCH="$(uname -m)"
    KDIR="/lib/modules/$KVER/build"
    DEST_DIR="/lib/modules/$KVER/extra"
    DEST="$DEST_DIR/$MODULE_NAME.ko"

    case "$ARCH" in
        x86_64|aarch64|arm64)
            ;;
        *)
            die "unsupported architecture '$ARCH' (tested: x86_64, aarch64)"
            ;;
    esac
    if [[ "$KVER" == *microsoft* || "$KVER" == *WSL* ]]; then
        die "WSL kernel detected; load the module on a real Linux host, not in WSL"
    fi

    local major minor
    major="${KVER%%.*}"
    minor="${KVER#*.}"
    minor="${minor%%.*}"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        if (( major < 4 || (major == 4 && minor < 9) )); then
            die "kernel $KVER is too old; BBR requires Linux 4.9 or newer"
        fi
    fi

    [[ -d "/lib/modules/$KVER" ]] || die "/lib/modules/$KVER not found; is the running kernel installed?"
    detect_headers
    if [[ $HEADERS_OK -eq 0 ]]; then
        info "kernel headers for $KVER are missing or incomplete; apt-get will be used"
    else
        ok "kernel headers: $KDIR"
    fi

    if [[ ! -d /run/systemd/system ]]; then
        warn "systemd is not running; modules-load.d/sysctl.d boot persistence cannot be verified"
    fi
    ok "kernel $KVER, architecture $ARCH"
}

check_container() {
    section "Preflight: virtualisation/container"
    if [[ -f /.dockerenv ]]; then
        die "Docker container detected; kernel modules must be installed on the host"
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --container --quiet; then
            local v
            v="$(systemd-detect-virt --container 2>/dev/null || true)"
            die "container detected ($v); kernel modules must be installed on the host"
        fi
    fi
    ok "bare metal or virtual machine"
}

check_kernel_policy() {
    section "Preflight: module loading policy"
    detect_kernel_config || warn "could not read the running kernel configuration"
    if [[ -n "$CONFIG_FILE" ]]; then
        if ! config_enabled MODULES; then
            die "CONFIG_MODULES is not enabled in the running kernel"
        fi
        if ! config_enabled MODULE_UNLOAD; then
            MODULE_UNLOAD_SUPPORTED=0
            warn "CONFIG_MODULE_UNLOAD is not enabled; rollback will require a reboot to unload"
        fi
        if ! config_enabled NET_SCH_FQ; then
            FQ_CONFIGURED=0
            warn "CONFIG_NET_SCH_FQ is not enabled; fq will not be selected"
        fi
        if config_enabled MODULE_SIG_FORCE; then
            SIG_ENFORCE=1
            info "CONFIG_MODULE_SIG_FORCE is enabled; the module must be signed"
        fi
        if config_enabled CC_IS_CLANG; then
            warn "the running kernel was built with clang; a gcc-built external module may be incompatible"
        fi
    else
        warn "kernel config not found; cannot verify CONFIG_MODULES/MODULE_SIG_FORCE"
    fi

    if [[ -r /sys/kernel/security/lockdown ]]; then
        if grep -Eq '\[(integrity|confidentiality)\]' /sys/kernel/security/lockdown 2>/dev/null; then
            die "kernel lockdown is active; unsigned out-of-tree modules are blocked"
        fi
    fi

    local modules_disabled
    modules_disabled="$(cat /proc/sys/kernel/modules_disabled 2>/dev/null || printf '0')"
    if [[ "$modules_disabled" != "0" ]]; then
        die "kernel.modules_disabled=$modules_disabled; module loading is disabled"
    fi

    if [[ -r /sys/module/module/parameters/sig_enforce ]]; then
        local se
        se="$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null || true)"
        if [[ "$se" == "Y" || "$se" == "1" ]]; then
            SIG_ENFORCE=1
        fi
    fi

    detect_secure_boot
    if [[ $SECURE_BOOT -eq 1 ]]; then
        warn "Secure Boot is enabled; an unsigned module will not load"
    fi
    if [[ $SIG_ENFORCE -eq 1 ]]; then
        warn "kernel module signature enforcement is active"
    fi

    local panic_oops panic_warn
    panic_oops="$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null || printf '0')"
    panic_warn="$(cat /proc/sys/kernel/panic_on_warn 2>/dev/null || printf '0')"
    if [[ "$panic_oops" != "0" || "$panic_warn" != "0" ]]; then
        local msg="kernel.panic_on_oops=$panic_oops kernel.panic_on_warn=$panic_warn: a module bug could reboot this host immediately"
        if [[ $ACCEPT_RISK -eq 1 ]]; then
            warn "$msg (accepted via --accept-risk)"
        else
            die "$msg; take a snapshot/confirm console access and rerun with --accept-risk"
        fi
    fi

    local tainted
    tainted="$(cat /proc/sys/kernel/tainted 2>/dev/null || printf '0')"
    if [[ "$tainted" != "0" ]]; then
        warn "kernel is already tainted (tainted=$tainted); loading this module adds the out-of-tree taint"
    fi
    ok "module loading is permitted by the current kernel policy"
}

check_existing_install() {
    section "Preflight: existing installation"
    AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
    [[ -n "$AVAILABLE_CC" ]] || die "cannot read the kernel congestion-control list"

    # Make the original BBR available as a rollback target.  Loading tcp_bbr is
    # harmless and does not change the current default.
    if ! grep -qw bbr <<<"$AVAILABLE_CC"; then
        if [[ $DRY_RUN -eq 0 ]] && command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1; then
            AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
            info "loaded the in-tree tcp_bbr module as a fallback"
        else
            warn "the in-tree bbr is not available; rollback will fall back to cubic"
        fi
    fi

    CURRENT_STATE_DIR="$(current_state_dir || true)"
    if [[ -n "$CURRENT_STATE_DIR" && -r "$CURRENT_STATE_DIR/meta.env" ]]; then
        local st sk
        st="$(read_state_field "$CURRENT_STATE_DIR/meta.env" STATUS || true)"
        sk="$(read_state_field "$CURRENT_STATE_DIR/meta.env" KVER || true)"
        case "$st" in
            installed)
                if [[ "$sk" != "$KVER" ]]; then
                    info "the current snapshot belongs to kernel $sk; installing a new one for $KVER"
                    info "the old snapshot is kept for audit: sudo $SCRIPT_DIR/rollback.sh --list"
                elif existing_install_healthy; then
                    ALREADY_INSTALLED=1
                    ok "tcp_bbrp is already installed and active"
                    printf '       cc=%s qdisc=%s module=%s\n' \
                        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" \
                        "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')" \
                        "$DEST"
                    info "to rebuild or downgrade, run: sudo $SCRIPT_DIR/rollback.sh && sudo $SCRIPT_DIR/install.sh"
                    exit 0
                else
                    die "a previous installation state exists (kernel $sk, status $st) but it is not healthy; run: sudo $SCRIPT_DIR/rollback.sh"
                fi
                ;;
            in-progress|rolling-back|rollback-failed)
                die "a previous operation did not finish (status=$st); run: sudo $SCRIPT_DIR/rollback.sh --force"
                ;;
            rolled-back)
                info "found a completed rollback state; a fresh installation may proceed"
                ;;
            "")
                die "state file $CURRENT_STATE_DIR/meta.env has no STATUS; inspect it and use rollback.sh --state"
                ;;
            *)
                die "unrecognised state '$st' in $CURRENT_STATE_DIR; run rollback.sh --state explicitly"
                ;;
        esac
    fi

    if grep -qw "$CC_NAME" <<<"$AVAILABLE_CC" || lsmod 2>/dev/null | grep -q "^$MODULE_NAME "; then
        die "$CC_NAME is already registered/loaded without a managed state; run: sudo $SCRIPT_DIR/rollback.sh"
    fi
    if [[ -e "$DEST" || -L "$DEST" ]]; then
        info "existing module file will be backed up: $DEST"
    fi
    if [[ -e "$MODULES_CONF" || -L "$MODULES_CONF" ]]; then
        info "existing boot config will be backed up: $MODULES_CONF"
    fi
    if [[ -e "$SYSCTL_CONF" || -L "$SYSCTL_CONF" ]]; then
        info "existing boot config will be backed up: $SYSCTL_CONF"
    fi
    ok "no active conflicting installation"
}

existing_install_healthy() {
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "$CC_NAME" ]] || return 1
    grep -qw "$CC_NAME" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || return 1
    lsmod 2>/dev/null | grep -q "^$MODULE_NAME " || return 1
    [[ -f "$DEST" ]] || return 1
    [[ -f "$MODULES_CONF" && -f "$SYSCTL_CONF" ]] || return 1
    grep -qF "$MARKER" "$MODULES_CONF" 2>/dev/null || return 1
    grep -qF "$MARKER" "$SYSCTL_CONF" 2>/dev/null || return 1
    [[ -r /sys/module/$MODULE_NAME/parameters/rwnd_aware ]] || return 1
    return 0
}

check_modprobe_conflicts() {
    section "Preflight: modprobe policy and name conflicts"
    if grep -RhsE '^[[:space:]]*(blacklist[[:space:]]+tcp_bbrp([[:space:]]|$)|install[[:space:]]+tcp_bbrp[[:space:]]+/(usr/)?bin/(false|true)([[:space:]]|$))' \
        /etc/modprobe.d /usr/lib/modprobe.d /run/modprobe.d >/dev/null 2>&1; then
        die "tcp_bbrp is blacklisted or disabled in modprobe.d"
    fi

    if command -v modinfo >/dev/null 2>&1; then
        local existing ex_real dest_real
        existing="$(modinfo -n tcp_bbrp 2>/dev/null || true)"
        if [[ -n "$existing" ]]; then
            ex_real="$(readlink -f -- "$existing" 2>/dev/null || printf '%s' "$existing")"
            dest_real="$(readlink -f -- "$DEST" 2>/dev/null || printf '%s' "$DEST")"
            if [[ "$ex_real" != "$dest_real" ]]; then
                die "another tcp_bbrp module is already provided by $existing"
            fi
        fi
    fi
    ok "no modprobe blacklist or module-name conflict"
}

check_sysctl_conflicts() {
    section "Preflight: sysctl boot ordering"
    local target_base
    target_base="$(basename -- "$SYSCTL_CONF")"
    local -A seen=()
    local dir f base
    shopt -s nullglob
    for dir in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.conf; do
            base="$(basename -- "$f")"
            [[ -n "${seen[$base]:-}" ]] && continue
            seen["$base"]="$f"
        done
    done
    shopt -u nullglob

    local conflicts=()
    for base in "${!seen[@]}"; do
        [[ "$base" > "$target_base" ]] || continue
        scan_sysctl_file "${seen[$base]}" conflicts
    done
    scan_sysctl_file /etc/sysctl.conf conflicts

    if (( ${#conflicts[@]} > 0 )); then
        err "these files are applied after $SYSCTL_CONF and would override it:"
        printf '  %s\n' "${conflicts[@]}" >&2
        die "comment out/remove the conflicting lines, or choose a different sysctl strategy"
    fi
    ok "no later sysctl file overrides tcp_congestion_control/default_qdisc"
}

scan_sysctl_file() {
    local file="$1"
    local -n out="$2"
    [[ -r "$file" ]] || return 0
    local line key val clean
    while IFS= read -r line || [[ -n "$line" ]]; do
        clean="${line%%#*}"
        [[ "$clean" =~ ^[[:space:]]*(net\.ipv4\.tcp_congestion_control|net\.core\.default_qdisc)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val%%#*}"
        val="${val//[[:space:]]/}"
        [[ -n "$val" ]] || continue
        if [[ "$key" == "net.ipv4.tcp_congestion_control" && "$val" != "$CC_NAME" ]]; then
            out+=("$file: $line")
        fi
        if [[ "$key" == "net.core.default_qdisc" && $WANT_FQ -eq 1 && "$val" != "fq" ]]; then
            out+=("$file: $line")
        fi
    done < "$file"
}

detect_services() {
    DETECTED_SERVICES=()
    command -v systemctl >/dev/null 2>&1 || return 0
    [[ -d /run/systemd/system ]] || return 0
    local s
    for s in "${KNOWN_SERVICES[@]}"; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            DETECTED_SERVICES+=("$s")
        fi
    done
}

check_services() {
    section "Preflight: proxy services"
    detect_services

    if [[ "$RESTART_MODE" == "none" ]]; then
        SERVICES_TO_RESTART=()
        info "service restart disabled by --no-restart"
        return 0
    fi

    if [[ "$RESTART_MODE" == "manual" ]]; then
        if ! command -v systemctl >/dev/null 2>&1; then
            die "--restart requires systemd, but systemctl was not found"
        fi
        local s
        for s in "${RESTART_SERVICES[@]}"; do
            if ! systemctl cat "$s" >/dev/null 2>&1 && ! systemctl cat "$s.service" >/dev/null 2>&1; then
                die "systemd unit not found: $s"
            fi
            SERVICES_TO_RESTART+=("$s")
        done
    else
        SERVICES_TO_RESTART=("${DETECTED_SERVICES[@]}")
    fi

    # De-duplicate while preserving order.
    local -A seen=()
    local dedup=()
    local s
    for s in "${SERVICES_TO_RESTART[@]:-}"; do
        [[ -n "$s" ]] || continue
        [[ -n "${seen[$s]:-}" ]] && continue
        seen["$s"]=1
        dedup+=("$s")
    done
    SERVICES_TO_RESTART=()
    if (( ${#dedup[@]} > 0 )); then
        SERVICES_TO_RESTART=("${dedup[@]}")
    fi

    if (( ${#SERVICES_TO_RESTART[@]} > 0 )); then
        ok "will restart: ${SERVICES_TO_RESTART[*]}"
    else
        info "no known active proxy service detected; restart your listener manually after install"
    fi
}

check_module_candidate() {
    section "Preflight: module source"
    NEED_BUILD=1
    CANDIDATE_KO=""

    if [[ -n "$KO_INPUT" ]]; then
        [[ -f "$KO_INPUT" ]] || die "prebuilt module not found: $KO_INPUT"
        CANDIDATE_KO="$(readlink -f -- "$KO_INPUT" 2>/dev/null || printf '%s' "$KO_INPUT")"
        NEED_BUILD=0
        info "using explicitly provided module: $CANDIDATE_KO"
        return 0
    fi

    local repo_ko="$ROOT/tcp_bbrp.ko"
    if [[ $FORCE_BUILD -eq 0 && -z "$SOURCE_INPUT" && -f "$repo_ko" ]]; then
        if command -v modinfo >/dev/null 2>&1 && validate_module "$repo_ko" >/dev/null 2>&1; then
            CANDIDATE_KO="$repo_ko"
            NEED_BUILD=0
            info "using validated prebuilt module: $repo_ko"
            return 0
        fi
        warn "prebuilt $repo_ko is not usable on kernel $KVER; it will be rebuilt"
    fi

    if [[ -n "$SOURCE_INPUT" ]]; then
        [[ -f "$SOURCE_INPUT" ]] || die "kernel source file not found: $SOURCE_INPUT"
        info "will regenerate tcp_bbrp.c from $SOURCE_INPUT"
    else
        [[ -f "$ROOT/tcp_bbrp.c" ]] || die "$ROOT/tcp_bbrp.c not found"
        [[ -f "$ROOT/Makefile" ]] || die "$ROOT/Makefile not found"
        info "will build from the checked-in tcp_bbrp.c (6.12 base); a version-matched kernel source is used as fallback if needed"
    fi
    NEED_BUILD=1
}

check_build_requirements() {
    section "Preflight: build environment"
    local c
    for c in install mktemp awk sed grep sort df sha256sum tee timeout od; do
        command -v "$c" >/dev/null 2>&1 || die "required base command '$c' is missing"
    done
    command -v sysctl >/dev/null 2>&1 || add_missing_pkg procps
    command -v apt-cache >/dev/null 2>&1 || add_missing_pkg apt
    for c in dmesg lsmod; do
        command -v "$c" >/dev/null 2>&1 || warn "optional diagnostic command '$c' is missing"
    done

    if [[ $NEED_BUILD -eq 1 ]]; then
        if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1 || ! command -v ld >/dev/null 2>&1; then
            add_missing_pkg build-essential
        fi
        if [[ $HEADERS_OK -eq 0 ]]; then
            add_missing_pkg "linux-headers-$KVER"
        fi
        command -v bc >/dev/null 2>&1 || add_missing_pkg bc
        command -v xz >/dev/null 2>&1 || add_missing_pkg xz-utils
        command -v bzip2 >/dev/null 2>&1 || add_missing_pkg bzip2
        if [[ -n "$CONFIG_FILE" ]] && config_enabled DEBUG_INFO_BTF_MODULES && ! command -v pahole >/dev/null 2>&1; then
            add_missing_pkg dwarves
        fi
        info "a module build is required"
    else
        info "using a prebuilt module; compiler/headers are not required"
    fi

    if ! command -v modinfo >/dev/null 2>&1 || ! command -v depmod >/dev/null 2>&1 \
        || ! command -v modprobe >/dev/null 2>&1 || ! command -v lsmod >/dev/null 2>&1; then
        add_missing_pkg kmod
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        if [[ $NEED_BUILD -eq 1 || $RUN_SMOKE -eq 1 ]]; then
            add_missing_pkg python3
        fi
    fi

    if (( ${#MISSING_PKGS[@]} > 0 )); then
        info "missing packages: ${MISSING_PKGS[*]}"
        if [[ $INSTALL_DEPS -eq 0 ]]; then
            warn "--no-deps was given; installation will fail unless these are installed"
        fi
    else
        ok "build/runtime dependencies are present"
    fi
}

check_resources() {
    section "Preflight: memory and disk"
    local mem_kb need_mb=32 tmp_base
    mem_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || printf '0')"
    if [[ -n "$mem_kb" ]] && (( mem_kb > 0 && mem_kb < 65536 )); then
        die "less than 64 MB of available memory; building/loading a module is unsafe"
    elif [[ -n "$mem_kb" ]] && (( mem_kb > 0 && mem_kb < 262144 )); then
        warn "less than 256 MB of available memory; the build may be slow or fail"
    fi

    [[ $NEED_BUILD -eq 1 ]] && need_mb=300
    tmp_base="${TMPDIR:-/var/tmp}"
    if ! check_disk_space "$need_mb" "$tmp_base"; then
        die "need at least ${need_mb} MB free under $tmp_base"
    fi
    if ! check_disk_space 32 "$DEST_DIR"; then
        die "need at least 32 MB free under /lib/modules/$KVER"
    fi
    if ! check_disk_space 16 /var; then
        die "need at least 16 MB free under /var for the state snapshot"
    fi
    if ! check_disk_space 8 /etc; then
        die "need at least 8 MB free under /etc"
    fi
    ok "resources look sufficient"
}

# ---------------------------------------------------------------------------
# Dependency installation
# ---------------------------------------------------------------------------

apt_update_once() {
    [[ $APT_UPDATED -eq 1 ]] && return 0
    APT_UPDATED=1
    APT_LOG="${LOG_ROOT}/apt-$STAMP.log"
    if [[ -z "${LOG_FILE:-}" ]]; then
        APT_LOG="${TMPDIR:-/var/tmp}/tcp-bbrp-apt-$STAMP.log"
    fi
    : > "$APT_LOG" 2>/dev/null || APT_LOG="/dev/null"
    info "running apt-get update"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$APT_LOG" 2>&1; then
        warn "apt-get update failed; trying with the existing package lists"
        tail -5 "$APT_LOG" >&2 || true
    fi
    return 0
}

apt_install_packages() {
    local -a pkgs=("$@")
    (( ${#pkgs[@]} > 0 )) || return 0
    apt_update_once
    local p
    for p in "${pkgs[@]}"; do
        if ! pkg_installed "$p"; then
            NEW_PACKAGES+=("$p")
        fi
    done
    info "installing packages: ${pkgs[*]}"
    if ! DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
        apt-get -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold \
                install -y --no-install-recommends "${pkgs[@]}" >>"$APT_LOG" 2>&1; then
        err "apt-get install failed; last 40 lines of $APT_LOG:"
        tail -40 "$APT_LOG" >&2 || true
        err "package manager recovery: run 'apt-get -f install' and 'dpkg --configure -a'"
        return 1
    fi
    return 0
}

install_missing_packages() {
    section "Dependencies: installing missing packages"
    (( ${#MISSING_PKGS[@]} > 0 )) || return 0
    if [[ $INSTALL_DEPS -eq 0 ]]; then
        die "missing packages (${MISSING_PKGS[*]}); rerun without --no-deps"
    fi
    if ! apt_install_packages "${MISSING_PKGS[@]}"; then
        die "could not install required packages; no kernel changes were made"
    fi
    MISSING_PKGS=()
    ok "dependencies installed"
}

verify_build_environment() {
    section "Dependencies: verification"
    local c
    detect_kernel_config || warn "could not re-read the running kernel configuration"
    if [[ $NEED_BUILD -eq 1 ]]; then
        detect_headers
        [[ $HEADERS_OK -eq 1 ]] || die "kernel headers for $KVER are still missing/incomplete"
        if [[ ! -f "$KDIR/include/config/kernel.release" ]] || [[ "$(cat "$KDIR/include/config/kernel.release" 2>/dev/null || true)" != "$KVER" ]]; then
            die "kernel headers do not match the running kernel $KVER"
        fi
        if [[ -n "$CONFIG_FILE" ]] && config_enabled MODVERSIONS; then
            [[ -s "$KDIR/Module.symvers" ]] || die "$KDIR/Module.symvers is missing but CONFIG_MODVERSIONS is enabled; install the full matching linux-headers package"
        fi
        for c in gcc make ld modinfo depmod modprobe; do
            command -v "$c" >/dev/null 2>&1 || die "required build command '$c' is still missing"
        done
        if ! command -v python3 >/dev/null 2>&1; then
            die "python3 is required to regenerate a version-matched module"
        fi
    else
        for c in modinfo depmod modprobe; do
            command -v "$c" >/dev/null 2>&1 || die "required module command '$c' is still missing"
        done
    fi

    # Re-detect fq after installing kmod, then re-check sysctl ordering because
    # the qdisc requirement may have changed.
    detect_fq
    check_sysctl_conflicts
    ok "environment is ready"
}

# ---------------------------------------------------------------------------
# Module validation and build
# ---------------------------------------------------------------------------

validate_module() {
    local ko="$1"
    local name vermagic license desc parms magic

    [[ -f "$ko" && -s "$ko" ]] || { err "module file is missing or empty: $ko"; return 1; }
    command -v modinfo >/dev/null 2>&1 || { err "modinfo is not installed"; return 1; }

    magic="$(od -An -t x1 -N4 -- "$ko" 2>/dev/null | tr -d ' \n' || true)"
    [[ "$magic" == "7f454c46" ]] || { err "not an ELF module: $ko"; return 1; }

    name="$(modinfo -F name "$ko" 2>/dev/null || true)"
    [[ "$name" == "$MODULE_NAME" ]] || { err "module name is '$name', expected '$MODULE_NAME'"; return 1; }

    vermagic="$(modinfo -F vermagic "$ko" 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$vermagic" != "$KVER" ]]; then
        err "module vermagic '$vermagic' does not match running kernel '$KVER'"
        err "rebuild against /lib/modules/$KVER/build"
        return 1
    fi

    license="$(modinfo -F license "$ko" 2>/dev/null || true)"
    [[ "$license" == *GPL* ]] || { err "module license '$license' is not GPL-compatible"; return 1; }

    desc="$(modinfo -F description "$ko" 2>/dev/null || true)"
    [[ "$desc" == *bbrp* ]] || { err "module description does not identify bbrp: '$desc'"; return 1; }

    parms="$(modinfo -F parm "$ko" 2>/dev/null || true)"
    [[ "$parms" == *rwnd_aware* ]] || { err "module is missing the rwnd_aware parameter"; return 1; }

    if [[ $VERBOSE -eq 1 ]]; then
        modinfo "$ko" | sed 's/^/       /' || true
    fi
    return 0
}

set_build_log() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        BUILD_LOG="${LOG_ROOT}/build-$STAMP.log"
    else
        BUILD_LOG="${TMPDIR:-/var/tmp}/tcp-bbrp-build-$STAMP.log"
    fi
    : > "$BUILD_LOG" 2>/dev/null || BUILD_LOG="/dev/null"
}

run_make() {
    local dir="$1"
    if ! make -C "$KDIR" M="$dir" modules >>"$BUILD_LOG" 2>&1; then
        err "kernel module build failed; last 40 lines of $BUILD_LOG:"
        tail -40 "$BUILD_LOG" >&2 || true
        return 1
    fi
    [[ -f "$dir/tcp_bbrp.ko" ]] || {
        err "make completed but $dir/tcp_bbrp.ko was not produced"
        return 1
    }
    return 0
}

generate_from_source() {
    local src="$1" dir="$2"
    [[ -f "$src" ]] || { err "kernel source not found: $src"; return 1; }
    if [[ "$(readlink -f -- "$src" 2>/dev/null || printf '%s' "$src")" != "$(readlink -f -- "$dir/tcp_bbr.c" 2>/dev/null || printf '%s' "$dir/tcp_bbr.c")" ]]; then
        cp -- "$src" "$dir/tcp_bbr.c" || return 1
    fi
    if ! PATCH_DIR="$dir" python3 "$SCRIPT_DIR/make_bbrp.py" >>"$BUILD_LOG" 2>&1; then
        err "make_bbrp.py failed; last 30 lines of $BUILD_LOG:"
        tail -30 "$BUILD_LOG" >&2 || true
        return 1
    fi
    return 0
}

find_source_tarball() {
    local -a files=()
    local f base ver score best="" bestscore=0
    local kbase kpatch kmm rest
    kbase="${KVER%-*}"
    kpatch="${kbase%%-*}"
    kmm="${KVER%%.*}"
    rest="${KVER#*.}"
    kmm="$kmm.${rest%%.*}"

    shopt -s nullglob
    files=(/usr/src/linux-source-*.tar.xz /usr/src/linux-source-*.tar.gz /usr/src/linux-source-*.tar.bz2 /usr/src/linux-source-*.tar.zst)
    shopt -u nullglob
    [[ ${#files[@]} -gt 0 ]] || return 1

    for f in "${files[@]}"; do
        base="${f##*/}"
        base="${base#linux-source-}"
        base="${base%%.tar.*}"
        ver="$base"
        score=0
        [[ "$ver" == "$KVER" ]] && score=100
        [[ $score -lt 90 && "$ver" == "$kbase" ]] && score=90
        [[ $score -lt 80 && "$ver" == "$kpatch" ]] && score=80
        [[ $score -lt 70 && "$ver" == "$kmm" ]] && score=70
        [[ $score -lt 60 && "$ver" == "$kmm".* ]] && score=60
        if (( score > bestscore )); then
            best="$f"
            bestscore=$score
        fi
    done
    (( bestscore > 0 )) || return 1
    printf '%s' "$best"
}

find_source_package() {
    local kbase kpatch kmm rest p
    kbase="${KVER%-*}"
    kpatch="${kbase%%-*}"
    kmm="${KVER%%.*}"
    rest="${KVER#*.}"
    kmm="$kmm.${rest%%.*}"
    local -a cands=(
        "linux-source-$KVER"
        "linux-source-$kbase"
        "linux-source-$kpatch"
        "linux-source-$kmm"
    )
    for p in "${cands[@]}"; do
        local cand=""
        cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
        if [[ -n "$cand" && "$cand" != "(none)" ]]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

extract_tcp_bbr() {
    local tarball="$1" dest="$2" member found raw
    local -a opts=()
    case "$tarball" in
        *.tar.xz)
            command -v xz >/dev/null 2>&1 || { err "xz is required to unpack $tarball"; return 1; }
            opts=(-J)
            ;;
        *.tar.gz)
            opts=(-z)
            ;;
        *.tar.bz2)
            command -v bzip2 >/dev/null 2>&1 || { err "bzip2 is required to unpack $tarball"; return 1; }
            opts=(-j)
            ;;
        *.tar.zst)
            command -v zstd >/dev/null 2>&1 || { err "zstd is required to unpack $tarball"; return 1; }
            opts=(--zstd)
            ;;
        *)
            err "unsupported kernel source archive: $tarball"
            return 1
            ;;
    esac

    member="$(tar "${opts[@]}" -tf "$tarball" 2>/dev/null | awk '/\/net\/ipv4\/tcp_bbr\.c$/ { if (!m) m=$0 } END { print m }')"
    [[ -n "$member" ]] || { err "net/ipv4/tcp_bbr.c not found in $tarball"; return 1; }

    mkdir -p "$dest" || return 1
    if tar "${opts[@]}" -xf "$tarball" -C "$dest" --strip-components=3 -- "$member" 2>/dev/null; then
        [[ -f "$dest/tcp_bbr.c" ]] && return 0
    fi

    # Some archives do not have exactly three leading path components.
    raw="$dest/raw"
    rm -rf -- "$raw"
    mkdir -p "$raw" || return 1
    if ! tar "${opts[@]}" -xf "$tarball" -C "$raw" -- "$member" 2>/dev/null; then
        err "failed to extract $member from $tarball"
        return 1
    fi
    found="$(find "$raw" -type f -path '*/net/ipv4/tcp_bbr.c' -print -quit 2>/dev/null || true)"
    [[ -n "$found" ]] || { err "extracted tcp_bbr.c not found under $raw"; return 1; }
    cp -- "$found" "$dest/tcp_bbr.c" || return 1
    rm -rf -- "$raw"
    return 0
}

try_build_from_kernel_source() {
    section "Build: version-matched kernel source fallback"
    local tarball="" pkg="" size mb ans bdir
    tarball="$(find_source_tarball || true)"

    if [[ -z "$tarball" ]]; then
        pkg="$(find_source_package || true)"
        if [[ -z "$pkg" ]]; then
            err "no linux-source tarball or matching linux-source package was found for $KVER"
            err "install the matching linux-source package, or rerun with --source /path/to/tcp_bbr.c"
            return 1
        fi
        if [[ $INSTALL_DEPS -eq 0 ]]; then
            err "--no-deps prevents installing $pkg"
            err "install it manually: apt-get install -y $pkg"
            return 1
        fi
        size="$(apt-cache show "$pkg" 2>/dev/null | awk -F': ' '/^Size:/ {print $2; exit}')"
        mb=0
        [[ "$size" =~ ^[0-9]+$ ]] && mb=$(( (size + 1048575) / 1048576 ))
        if [[ $ASSUME_YES -eq 0 ]]; then
            if [[ ! -t 0 ]]; then
                die "non-interactive session; pass --yes to allow installing $pkg"
            fi
            printf 'Install %s (~%s MB download) to generate a version-matched module? [y/N] ' "$pkg" "$mb"
            ans=""
            read -r ans || ans=""
            [[ "$ans" =~ ^[Yy]$ ]] || { err "declined; rerun with --source or install $pkg manually"; return 1; }
        fi
        if ! check_disk_space 400 /usr/src; then
            err "need at least 400 MB free under /usr/src for $pkg"
            return 1
        fi
        apt_install_packages "$pkg" || return 1
        tarball="$(find_source_tarball || true)"
        [[ -n "$tarball" ]] || { err "package installed but no linux-source archive was found"; return 1; }
    fi

    info "using kernel source archive: $tarball"
    TMP_SRC="$(mktemp -d "${TMPDIR:-/var/tmp}/tcp-bbrp-src.XXXXXX")" || return 1
    extract_tcp_bbr "$tarball" "$TMP_SRC" || return 1

    if [[ -n "${BUILD_DIR:-}" && -d "${BUILD_DIR:-}" ]]; then
        rm -rf -- "$BUILD_DIR"
    fi
    bdir="$(mktemp -d "${TMPDIR:-/var/tmp}/tcp-bbrp-build.XXXXXX")" || return 1
    BUILD_DIR="$bdir"
    BUILD_LOG="${LOG_ROOT}/build-$STAMP.log"
    [[ -n "${LOG_FILE:-}" ]] || BUILD_LOG="${TMPDIR:-/var/tmp}/tcp-bbrp-build-$STAMP.log"
    : > "$BUILD_LOG" 2>/dev/null || BUILD_LOG="/dev/null"

    cp -- "$TMP_SRC/tcp_bbr.c" "$BUILD_DIR/tcp_bbr.c" || return 1
    if ! generate_from_source "$BUILD_DIR/tcp_bbr.c" "$BUILD_DIR"; then
        return 1
    fi
    if ! run_make "$BUILD_DIR"; then
        return 1
    fi
    KO_PATH="$BUILD_DIR/tcp_bbrp.ko"
    validate_module "$KO_PATH" || return 1
    ok "built version-matched module from $tarball"
    return 0
}

build_module() {
    section "Build: compiling tcp_bbrp.ko"
    [[ $NEED_BUILD -eq 1 ]] || { KO_PATH="$CANDIDATE_KO"; return 0; }

    BUILD_DIR="$(mktemp -d "${TMPDIR:-/var/tmp}/tcp-bbrp-build.XXXXXX")" || die "cannot create build directory"
    set_build_log

    if [[ -n "$SOURCE_INPUT" ]]; then
        info "regenerating from $SOURCE_INPUT"
        cp -- "$SOURCE_INPUT" "$BUILD_DIR/tcp_bbr.c" || die "cannot copy $SOURCE_INPUT"
        if ! generate_from_source "$BUILD_DIR/tcp_bbr.c" "$BUILD_DIR"; then
            die "failed to generate tcp_bbrp.c from $SOURCE_INPUT"
        fi
        if ! run_make "$BUILD_DIR"; then
            die "failed to build tcp_bbrp.ko from $SOURCE_INPUT"
        fi
    else
        cp -- "$ROOT/tcp_bbrp.c" "$BUILD_DIR/tcp_bbrp.c" || die "cannot copy tcp_bbrp.c"
        cp -- "$ROOT/Makefile" "$BUILD_DIR/Makefile" || die "cannot copy Makefile"
        if ! run_make "$BUILD_DIR"; then
            warn "the checked-in 6.12-based source is incompatible with kernel $KVER"
            warn "trying to install/extract the version-matched kernel source"
            if ! try_build_from_kernel_source; then
                die "could not build a module for kernel $KVER; see $BUILD_LOG"
            fi
        fi
    fi

    KO_PATH="$BUILD_DIR/tcp_bbrp.ko"
    validate_module "$KO_PATH" || die "the newly built module failed validation"
    ok "module built: $KO_PATH"
}

check_module_signature_policy() {
    if [[ $SECURE_BOOT -eq 1 || $SIG_ENFORCE -eq 1 ]]; then
        if module_is_signed "$KO_PATH"; then
            warn "Secure Boot/signature enforcement is active; the module is signed, but the key must be enrolled in the kernel keyring"
        else
            die "$KO_PATH is unsigned while Secure Boot/signature enforcement is active; sign it or disable Secure Boot"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Snapshot / transaction state
# ---------------------------------------------------------------------------

write_meta() {
    [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR:-}" ]] || return 1
    UPDATED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    local tmp np sr started
    np="${NEW_PACKAGES[*]:-}"
    sr="${SERVICES_TO_RESTART[*]:-}"
    started="${SERVICES_RESTARTED[*]:-}"
    tmp="$(mktemp "$BACKUP_DIR/.meta.XXXXXX")" || return 1
    {
        printf 'META_VERSION=%q\n' "$META_VERSION"
        printf 'STATUS=%q\n' "$STATUS"
        printf 'CREATED_AT=%q\n' "$CREATED_AT"
        printf 'UPDATED_AT=%q\n' "$UPDATED_AT"
        printf 'INSTALLER_VERSION=%q\n' "$SCRIPT_VERSION"
        printf 'DISTRO_ID=%q\n' "$DISTRO_ID"
        printf 'DISTRO_VERSION=%q\n' "$DISTRO_VERSION"
        printf 'KVER=%q\n' "$KVER"
        printf 'ARCH=%q\n' "$ARCH"
        printf 'DEST=%q\n' "$DEST"
        printf 'MODULES_CONF=%q\n' "$MODULES_CONF"
        printf 'SYSCTL_CONF=%q\n' "$SYSCTL_CONF"
        printf 'ORIG_CC=%q\n' "$ORIG_CC"
        printf 'ORIG_QDISC=%q\n' "$ORIG_QDISC"
        printf 'ORIG_CC_AVAILABLE=%q\n' "$ORIG_CC_AVAILABLE"
        printf 'ORIG_MODULE_LOADED=%q\n' "$ORIG_MODULE_LOADED"
        printf 'HAD_MODULES_CONF=%q\n' "$HAD_MODULES_CONF"
        printf 'HAD_SYSCTL_CONF=%q\n' "$HAD_SYSCTL_CONF"
        printf 'HAD_DEST=%q\n' "$HAD_DEST"
        printf 'INSTALLED_KO_SHA256=%q\n' "$INSTALLED_KO_SHA256"
        printf 'WANT_FQ=%q\n' "$WANT_FQ"
        printf 'MODULE_UNLOAD_SUPPORTED=%q\n' "$MODULE_UNLOAD_SUPPORTED"
        printf 'SECURE_BOOT=%q\n' "$SECURE_BOOT"
        printf 'SIG_ENFORCE=%q\n' "$SIG_ENFORCE"
        printf 'CC_APPLIED=%q\n' "$CC_APPLIED"
        printf 'NEW_PACKAGES=%q\n' "$np"
        printf 'SERVICES_TO_RESTART=%q\n' "$sr"
        printf 'SERVICES_RESTARTED=%q\n' "$started"
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$BACKUP_DIR/meta.env"
}

capture_original_state() {
    ORIG_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    ORIG_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
    ORIG_CC_AVAILABLE=0
    if [[ -n "$ORIG_CC" ]] && grep -qw "$ORIG_CC" <<<"$AVAILABLE_CC"; then
        ORIG_CC_AVAILABLE=1
    fi
    ORIG_MODULE_LOADED=0
    if lsmod 2>/dev/null | grep -q "^$MODULE_NAME "; then
        ORIG_MODULE_LOADED=1
        die "$MODULE_NAME is already loaded; refusing to overwrite a live module"
    fi
    ORIG_CC="${ORIG_CC:-unknown}"
    ORIG_QDISC="${ORIG_QDISC:-unknown}"
}

create_state() {
    section "State: snapshot and transaction journal"
    install -d -m 700 "$STATE_ROOT" "$BACKUP_ROOT" || die "cannot create state directories"
    BACKUP_DIR="$BACKUP_ROOT/$STAMP"
    install -d -m 700 "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"

    HAD_MODULES_CONF=0
    HAD_SYSCTL_CONF=0
    HAD_DEST=0

    if [[ -e "$MODULES_CONF" || -L "$MODULES_CONF" ]]; then
        cp -a -- "$MODULES_CONF" "$BACKUP_DIR/modules-load.conf" || die "cannot back up $MODULES_CONF"
        HAD_MODULES_CONF=1
    fi
    if [[ -e "$SYSCTL_CONF" || -L "$SYSCTL_CONF" ]]; then
        cp -a -- "$SYSCTL_CONF" "$BACKUP_DIR/sysctl.conf" || die "cannot back up $SYSCTL_CONF"
        HAD_SYSCTL_CONF=1
    fi
    if [[ -e "$DEST" || -L "$DEST" ]]; then
        cp -a -- "$DEST" "$BACKUP_DIR/tcp_bbrp.ko.orig" || die "cannot back up $DEST"
        HAD_DEST=1
    fi

    capture_original_state
    STATUS="in-progress"
    CREATED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    write_meta || die "cannot write transaction metadata"
    ln -sfn "$BACKUP_DIR" "$STATE_ROOT/current" || die "cannot update $STATE_ROOT/current"
    TRANSACTION_ACTIVE=1
    ok "snapshot saved: $BACKUP_DIR"
}

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------

install_module_file() {
    section "Install: module file"
    install -d -m 755 "$DEST_DIR" || die "cannot create $DEST_DIR"
    local tmp
    tmp="$(mktemp "$DEST_DIR/.tcp_bbrp.ko.XXXXXX")" || die "cannot create a temporary file in $DEST_DIR"
    if ! install -m 0644 "$KO_PATH" "$tmp"; then
        rm -f -- "$tmp"
        die "cannot copy $KO_PATH to $DEST_DIR"
    fi
    if ! mv -f -- "$tmp" "$DEST"; then
        rm -f -- "$tmp"
        die "cannot atomically replace $DEST"
    fi
    cmp -s "$KO_PATH" "$DEST" || die "installed module differs from the validated module"
    INSTALLED_KO_SHA256="$(sha256sum "$DEST" | awk '{print $1}')"
    write_meta || die "cannot update transaction state after module copy"
    ok "installed $DEST"
}

load_module() {
    section "Install: depmod and modprobe"
    if [[ -z "${BUILD_LOG:-}" ]]; then
        set_build_log
    fi
    if ! depmod -a "$KVER" >>"$BUILD_LOG" 2>&1; then
        die "depmod -a $KVER failed; the module index was not updated"
    fi
    local found found_real dest_real
    found="$(modinfo -n "$MODULE_NAME" 2>/dev/null || true)"
    found_real="$(readlink -f -- "$found" 2>/dev/null || printf '%s' "$found")"
    dest_real="$(readlink -f -- "$DEST" 2>/dev/null || printf '%s' "$DEST")"
    if [[ -n "$found" && "$found_real" != "$dest_real" ]]; then
        die "modprobe resolves $MODULE_NAME to $found instead of $DEST"
    fi

    if ! modprobe "$MODULE_NAME"; then
        err "modprobe $MODULE_NAME failed; kernel log tail:"
        dmesg_tail
        die "the module could not be loaded"
    fi
    lsmod 2>/dev/null | grep -q "^$MODULE_NAME " || die "$MODULE_NAME did not appear in lsmod"
    grep -qw "$CC_NAME" /proc/sys/net/ipv4/tcp_available_congestion_control || {
        err "kernel log tail:"
        dmesg_tail
        die "$CC_NAME did not register with the TCP stack"
    }
    [[ -d "/sys/module/$MODULE_NAME" ]] || die "/sys/module/$MODULE_NAME is missing"
    local rwnd
    rwnd="$(cat "/sys/module/$MODULE_NAME/parameters/rwnd_aware" 2>/dev/null || true)"
    [[ -n "$rwnd" ]] || die "rwnd_aware module parameter is not readable"
    ok "module loaded; bbrp is registered (rwnd_aware=$rwnd)"
}

run_smoke() {
    section "Verify: loopback smoke test"
    if [[ $RUN_SMOKE -eq 0 ]]; then
        warn "smoke test skipped by --no-smoke"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 is unavailable; smoke test skipped"
        return 0
    fi
    if [[ ! -f "$SCRIPT_DIR/loopback_smoke.py" ]]; then
        warn "$SCRIPT_DIR/loopback_smoke.py not found; smoke test skipped"
        return 0
    fi
    local out
    out="${LOG_ROOT}/smoke-$STAMP.log"
    [[ -n "${LOG_FILE:-}" ]] || out="${TMPDIR:-/var/tmp}/tcp-bbrp-smoke-$STAMP.log"
    if ! timeout 60 python3 "$SCRIPT_DIR/loopback_smoke.py" --size-mb 16 >"$out" 2>&1; then
        err "loopback smoke test failed; last 30 lines:"
        tail -30 "$out" >&2 || true
        die "the module did not pass the loopback transfer test"
    fi
    tail -5 "$out" | sed 's/^/       /' || true
    ok "loopback transfer completed with bbrp"
}

write_persistence() {
    section "Install: boot persistence"
    local mods sysctl_content
    mods="$MARKER
# The in-tree tcp_bbr remains available as a fallback.
"
    if grep -qw bbr <<<"$AVAILABLE_CC"; then
        mods+="tcp_bbr
"
    fi
    mods+="tcp_bbrp
"

    sysctl_content="$MARKER
# Applied late in sysctl.d processing; keep the bbr fallback files intact.
"
    if [[ $WANT_FQ -eq 1 ]]; then
        sysctl_content+="net.core.default_qdisc = fq
"
    fi
    sysctl_content+="net.ipv4.tcp_congestion_control = $CC_NAME
"

    write_atomic "$MODULES_CONF" "$mods" 0644 || die "cannot write $MODULES_CONF"
    write_atomic "$SYSCTL_CONF" "$sysctl_content" 0644 || die "cannot write $SYSCTL_CONF"
    write_meta || die "cannot update transaction state after writing boot persistence"
    ok "wrote $MODULES_CONF and $SYSCTL_CONF"
}

write_atomic() {
    local dest="$1" content="$2" mode="$3" dir tmp
    dir="$(dirname -- "$dest")"
    install -d -m 755 "$dir" || return 1
    tmp="$(mktemp "$dir/.$(basename -- "$dest").XXXXXX")" || return 1
    if ! printf '%s' "$content" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$dest"
}

apply_runtime() {
    section "Install: applying runtime sysctl"
    if [[ $WANT_FQ -eq 1 ]]; then
        if ! sysctl -w net.core.default_qdisc=fq >/dev/null; then
            die "cannot set net.core.default_qdisc=fq"
        fi
    fi
    if ! sysctl -w "net.ipv4.tcp_congestion_control=$CC_NAME" >/dev/null; then
        die "cannot set net.ipv4.tcp_congestion_control=$CC_NAME"
    fi
    local cc qd
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    [[ "$cc" == "$CC_NAME" ]] || die "runtime CC is '$cc', expected '$CC_NAME'"
    if [[ $WANT_FQ -eq 1 && "$qd" != "fq" ]]; then
        die "runtime default_qdisc is '$qd', expected 'fq'"
    fi
    ok "runtime cc=$cc qdisc=$qd"
}

restart_services() {
    section "Services: recreating listeners"
    SERVICES_RESTARTED=()
    SERVICE_FAILURES=()
    if (( ${#SERVICES_TO_RESTART[@]} == 0 )); then
        info "no services to restart; existing listeners keep their old CC until restarted"
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found; services were not restarted"
        return 0
    fi

    local s active
    for s in "${SERVICES_TO_RESTART[@]}"; do
        active=0
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            active=1
        fi
        # Automatic mode only touches services that were active at preflight.
        # Explicit --restart is allowed to start an inactive unit.
        if [[ $active -eq 0 && "$RESTART_MODE" != "manual" ]]; then
            continue
        fi
        if timeout 90 systemctl restart "$s"; then
            SERVICES_RESTARTED+=("$s")
            ok "restarted $s"
        else
            SERVICE_FAILURES+=("$s")
            err "failed to restart $s; last status:"
            systemctl status --no-pager -l "$s" 2>&1 | tail -15 >&2 || true
        fi
    done

    STATUS="installed"
    write_meta >/dev/null 2>&1 || warn "could not update the service list in $BACKUP_DIR/meta.env"

    if (( ${#SERVICE_FAILURES[@]} > 0 )); then
        warn "installation is complete, but these services failed to restart: ${SERVICE_FAILURES[*]}"
        warn "fix the service, then restart it manually so its listeners use $CC_NAME"
    fi
}

verify_listener() {
    (( ${#SERVICES_RESTARTED[@]} > 0 )) || return 0
    command -v ss >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    [[ -f "$SCRIPT_DIR/verify_listener_cc.py" ]] || return 0
    local addrs
    addrs="$(ss -ltn 2>/dev/null | awk '{print $4}' || true)"
    grep -qE '[:.]443$' <<<"$addrs" || return 0
    if ! timeout 20 python3 "$SCRIPT_DIR/verify_listener_cc.py" 443 --expect "$CC_NAME" >/dev/null 2>&1; then
        warn "could not confirm that the 443 listener uses $CC_NAME; verify with: python3 $SCRIPT_DIR/verify_listener_cc.py 443"
    else
        ok "443 listener uses $CC_NAME"
    fi
}

# ---------------------------------------------------------------------------
# Dry-run and final reporting
# ---------------------------------------------------------------------------

print_dry_run() {
    section "Dry run summary (no changes made)"
    local modsrc services
    if [[ $NEED_BUILD -eq 0 ]]; then
        modsrc="$CANDIDATE_KO"
    elif [[ -n "$SOURCE_INPUT" ]]; then
        modsrc="build from $SOURCE_INPUT"
    else
        modsrc="build from $ROOT/tcp_bbrp.c (fallback: version-matched linux-source)"
    fi
    services="${SERVICES_TO_RESTART[*]:-none}"
    printf '  distro:      %s\n' "$DISTRO_NAME"
    printf '  kernel:      %s (%s)\n' "$KVER" "$ARCH"
    printf '  headers:     %s\n' "$([[ $HEADERS_OK -eq 1 ]] && echo "$KDIR" || echo 'missing (would install)')"
    printf '  module:      %s\n' "$modsrc"
    printf '  install to:  %s\n' "$DEST"
    printf '  boot files:  %s ; %s\n' "$MODULES_CONF" "$SYSCTL_CONF"
    printf '  runtime:     cc=%s' "$CC_NAME"
    [[ $WANT_FQ -eq 1 ]] && printf ' qdisc=fq'
    printf '\n'
    printf '  services:    %s\n' "$services"
    printf '  smoke test:  %s\n' "$([[ $RUN_SMOKE -eq 1 ]] && echo yes || echo no)"
    printf '  secure boot: %s\n' "$([[ $SECURE_BOOT -eq 1 ]] && echo enabled || echo disabled)"
    if (( ${#MISSING_PKGS[@]} > 0 )); then
        printf '  packages:    %s (would install)\n' "${MISSING_PKGS[*]}"
    else
        printf '  packages:    none missing\n'
    fi
    printf '\nNo changes were made.  Re-run without --dry-run to install.\n'
}

print_manual_recovery() {
    local mods_conf="$MODULES_CONF" sysctl_conf="$SYSCTL_CONF" dest="$DEST"
    cat <<EOF

Manual recovery
---------------
1. Switch new sockets back to the original BBR (or cubic):
     sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null ||
     sysctl -w net.ipv4.tcp_congestion_control=cubic
     sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
2. Remove boot persistence:
     rm -f "$sysctl_conf" "$mods_conf"
3. Unload the module if possible (reboot if it is still in use):
     modprobe -r tcp_bbrp 2>/dev/null || true
4. Remove the installed module and refresh depmod:
     rm -f "$dest"
     depmod -a "$KVER"
5. Restore files from the snapshot, if one exists:
     ls -l "$BACKUP_DIR" 2>/dev/null || true
     cp -a "$BACKUP_DIR/modules-load.conf" "$mods_conf" 2>/dev/null || true
     cp -a "$BACKUP_DIR/sysctl.conf" "$sysctl_conf" 2>/dev/null || true
     cp -a "$BACKUP_DIR/tcp_bbrp.ko.orig" "$dest" 2>/dev/null || true
     depmod -a "$KVER"
6. Restart proxy listeners so they open new sockets.

If the host is unstable, reboot it.  Boot persistence points at the module
only if it was committed; after removing the files above the host boots with
bbr or cubic and the old tcp_bbr.ko is never touched.
EOF
}

print_summary() {
    section "Installation complete"
    printf '  distro:       %s\n' "$DISTRO_NAME"
    printf '  kernel:       %s (%s)\n' "$KVER" "$ARCH"
    printf '  module:       %s\n' "$DEST"
    printf '  cc/qdisc:     %s / %s\n' \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" \
        "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    printf '  available:    %s\n' "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo '?')"
    printf '  rwnd_aware:   %s\n' "$(cat /sys/module/$MODULE_NAME/parameters/rwnd_aware 2>/dev/null || echo '?')"
    printf '  boot config:  %s\n' "$MODULES_CONF"
    printf '  boot config:  %s\n' "$SYSCTL_CONF"
    printf '  snapshot:     %s\n' "$BACKUP_DIR"
    if (( ${#SERVICES_RESTARTED[@]} > 0 )); then
        printf '  restarted:    %s\n' "${SERVICES_RESTARTED[*]}"
    fi
    if (( ${#NEW_PACKAGES[@]} > 0 )); then
        printf '  packages:     installed for the build and intentionally kept: %s\n' "${NEW_PACKAGES[*]}"
    fi
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '  log:          %s\n' "$LOG_FILE"
    fi
    if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
        printf '  build dir:    %s\n' "$BUILD_DIR"
    fi
    printf '\n  rollback:     sudo %s/rollback.sh\n' "$SCRIPT_DIR"
    printf '  runtime-only: sudo %s/rollback.sh --runtime-only\n' "$SCRIPT_DIR"
    printf '\nOnly sockets created after this point use %s.  Restart any\n' "$CC_NAME"
    printf 'listener that was not restarted automatically.\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    check_root
    setup_logging
    acquire_lock

    section "tcp_bbrp installer $SCRIPT_VERSION"
    check_os
    check_arch_kernel
    check_container
    check_kernel_policy
    check_existing_install
    check_modprobe_conflicts

    detect_fq
    check_sysctl_conflicts
    check_services
    check_module_candidate
    check_build_requirements
    check_resources

    if (( ALREADY_INSTALLED == 1 )); then
        exit 0
    fi
    if (( DRY_RUN == 1 )); then
        print_dry_run
        exit 0
    fi

    if (( ${#MISSING_PKGS[@]} > 0 )); then
        install_missing_packages
    fi
    verify_build_environment

    if [[ $NEED_BUILD -eq 1 ]]; then
        build_module
    else
        KO_PATH="$CANDIDATE_KO"
        validate_module "$KO_PATH" || die "the prebuilt module failed validation"
    fi
    check_module_signature_policy

    create_state
    install_module_file
    load_module
    run_smoke
    write_persistence
    apply_runtime

    CC_APPLIED=1
    write_meta || die "cannot record CC_APPLIED in the transaction state"
    STATUS="installed"
    write_meta || die "cannot commit the installation state"
    TRANSACTION_ACTIVE=0

    restart_services
    verify_listener
    print_summary

    if (( ${#SERVICE_FAILURES[@]} > 0 )); then
        exit 3
    fi
}

main "$@"
