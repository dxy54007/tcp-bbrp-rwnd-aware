#!/usr/bin/env bash
# Deprecated compatibility wrapper for the old rollback script name.
#
# The implementation now lives in rollback.sh.  This wrapper keeps existing
# commands working:
#   bbrp-rollback.sh              -> rollback.sh
#   bbrp-rollback.sh --full       -> rollback.sh --reset-route
#   bbrp-rollback.sh --keep-config-> rollback.sh --keep-config
#   bbrp-rollback.sh --remove     -> rollback.sh --remove
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
            args+=("--reset-route")
            ;;
        *)
            args+=("$arg")
            ;;
    esac
done

exec bash "$SCRIPT_DIR/rollback.sh" "${args[@]}"
