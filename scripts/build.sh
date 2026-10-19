#!/usr/bin/env bash
# Build tcp_bbrp.ko against the running kernel headers.
#
# Default: build the checked-in tcp_bbrp.c (generated from Debian 6.12.107).
# --from-source PATH : regenerate tcp_bbrp.c from a kernel tcp_bbr.c first.
# --debian-source     : extract net/ipv4/tcp_bbr.c from /usr/src/linux-source-6.12.tar.xz
#                       then regenerate tcp_bbrp.c.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
MODE="prebuilt"
SRC=""

usage() {
    echo "usage: $0 [--from-source /path/to/tcp_bbr.c | --debian-source]"
    exit 1
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        --from-source)
            [[ $# -eq 2 ]] || usage
            MODE="from-source"
            SRC="$2"
            ;;
        --debian-source)
            MODE="debian-source"
            ;;
        *)
            usage
            ;;
    esac
fi

if [[ ! -d "$KDIR" ]]; then
    echo "ERROR: kernel headers not found: $KDIR" >&2
    echo "Install linux-headers-$(uname -r) first." >&2
    exit 1
fi

if [[ "$MODE" == "from-source" || "$MODE" == "debian-source" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    if [[ "$MODE" == "from-source" ]]; then
        [[ -f "$SRC" ]] || { echo "ERROR: source file not found: $SRC" >&2; exit 1; }
        cp "$SRC" "$TMP/tcp_bbr.c"
    else
        TARBALL="${SRC_TARBALL:-/usr/src/linux-source-6.12.tar.xz}"
        [[ -f "$TARBALL" ]] || { echo "ERROR: source tarball not found: $TARBALL" >&2; exit 1; }
        MEMBER="$(tar -tJf "$TARBALL" | grep 'net/ipv4/tcp_bbr.c$' | head -1 || true)"
        [[ -n "$MEMBER" ]] || { echo "ERROR: tcp_bbr.c not found in $TARBALL" >&2; exit 1; }
        tar -xJf "$TARBALL" -C "$TMP" --strip-components=3 "$MEMBER"
    fi
    PATCH_DIR="$TMP" python3 "$ROOT/scripts/make_bbrp.py"
    cp "$TMP/tcp_bbrp.c" "$ROOT/tcp_bbrp.c"
    echo "regenerated $ROOT/tcp_bbrp.c from source"
fi

make -C "$KDIR" M="$ROOT" modules
modinfo "$ROOT/tcp_bbrp.ko"
echo
echo "built: $ROOT/tcp_bbrp.ko"
echo "install with: sudo $ROOT/scripts/install.sh"
