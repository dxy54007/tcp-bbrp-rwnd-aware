#!/bin/bash
# One-click rollback for the tcp_bbrp (CC name: bbrp) kernel module.
#
# Default: remove boot persistence, switch the running default back to the
# original BBR, restart x-ui if present, and unload tcp_bbrp when possible.
# The original in-tree tcp_bbr.ko is never touched.
#
# Usage:
#   /root/bbrp-rollback.sh                 # full rollback, remove persistence
#   /root/bbrp-rollback.sh --keep-config   # only switch runtime to bbr, keep boot files
#   /root/bbrp-rollback.sh --remove        # also delete the out-of-tree module file
#   /root/bbrp-rollback.sh --full          # also reset default route (remove initcwnd/initrwnd)
set -u

KEEP_CONFIG=0
REMOVE=0
FULL=0
for arg in "$@"; do
    case "$arg" in
        --keep-config) KEEP_CONFIG=1 ;;
        --remove) REMOVE=1 ;;
        --full) FULL=1 ;;
        *) echo "unknown argument: $arg"; exit 2 ;;
    esac
done

echo "== bbrp rollback =="
echo "before: cc=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"
ip route show default 2>/dev/null || true
lsmod | grep -E '^tcp_bbrp ' || true

# Remove the boot persistence unless the caller explicitly wants to keep it.
if [ "$KEEP_CONFIG" -eq 0 ]; then
    rm -f /etc/sysctl.d/zz-bbrp.conf
    rm -f /etc/modules-load.d/tcp_bbrp.conf
    echo "removed boot persistence files"
fi

# Restore the fallback sysctl file to bbr if it was previously changed.
if grep -qE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=.*bbrp' /etc/sysctl.d/myconf.conf 2>/dev/null; then
    sed -i -E 's/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=.*/net.ipv4.tcp_congestion_control = bbr/' /etc/sysctl.d/myconf.conf
fi

# Switch the running default back to original BBR.
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr
else
    echo "WARNING: original bbr is not available; falling back to cubic"
    sysctl -w net.ipv4.tcp_congestion_control=cubic
fi
sysctl -w net.core.default_qdisc=fq

if command -v tc >/dev/null 2>&1 && ! tc qdisc show dev ens7 2>/dev/null | grep -q 'qdisc fq '; then
    tc qdisc replace dev ens7 root fq 2>/dev/null || true
fi

# Recreate the proxy listener with the original BBR.
if systemctl is-active --quiet x-ui 2>/dev/null; then
    systemctl restart x-ui 2>/dev/null || true
    sleep 2
fi

# Unload the patched module if no socket is using it anymore.
if lsmod | grep -q '^tcp_bbrp '; then
    if modprobe -r tcp_bbrp 2>/tmp/bbrp-rollback-modprobe.err; then
        echo "tcp_bbrp unloaded"
    else
        echo "WARNING: tcp_bbrp is still in use; module left loaded but no longer default"
        cat /tmp/bbrp-rollback-modprobe.err 2>/dev/null || true
    fi
fi

# Optionally remove the out-of-tree module file.
if [ "$REMOVE" -eq 1 ]; then
    if lsmod | grep -q '^tcp_bbrp '; then
        echo "WARNING: not removing tcp_bbrp.ko because the module is still loaded"
    else
        rm -f "/lib/modules/$(uname -r)/extra/tcp_bbrp.ko"
        depmod -a
        echo "removed tcp_bbrp.ko and ran depmod"
    fi
fi

# Optionally reset the default route to the pre-initcwnd state.
if [ "$FULL" -eq 1 ]; then
    GW=$(ip route show default | awk '/^default/ {print $3; exit}')
    DEV=$(ip route show default | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [ -n "$GW" ] && [ -n "$DEV" ]; then
        ip route replace default via "$GW" dev "$DEV"
        echo "reset default route via $GW dev $DEV (no initcwnd/initrwnd)"
    else
        echo "WARNING: could not determine default gateway/device; route not reset"
    fi
fi

echo "== after =="
echo "cc=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"
ip route show default 2>/dev/null || true
lsmod | grep -E '^tcp_bbrp ' || echo "tcp_bbrp not loaded"
echo "done"
