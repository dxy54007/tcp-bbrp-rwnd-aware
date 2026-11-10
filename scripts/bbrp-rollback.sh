#!/usr/bin/env bash
# Deprecated compatibility wrapper for the old rollback script name.
#
# The implementation lives in rollback.sh.  This wrapper keeps existing
# commands working:
#   bbrp-rollback.sh              -> rollback.sh
#   bbrp-rollback.sh --keep-config-> rollback.sh --keep-config
#   bbrp-rollback.sh --remove     -> rollback.sh --remove
#
# There is no route/initcwnd handling: rollback.sh never touches routes.
#
# New scripts and documentation should call rollback.sh directly.

set -u

SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    SELF="$(readlink -f -- "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd -P)"

printf 'NOTE: bbrp-rollback.sh is deprecated; forwarding to rollback.sh\n' >&2

args=()
for arg in "$@"; do
    case "$arg" in
        --full)
            # Route/initcwnd handling was removed; keep the old command working
            # by ignoring this flag instead of failing.
            printf 'NOTE: --full no longer changes routes; ignoring it\n' >&2
            ;;
        *)
            args+=("$arg")
            ;;
    esac
done

exec bash "$SCRIPT_DIR/rollback.sh" "${args[@]}"
