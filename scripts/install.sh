#!/usr/bin/env bash
# Install tcp_bbrp.ko and make bbrp the default TCP congestion control.
#
# This script does NOT overwrite the in-tree tcp_bbr.ko. The original BBR
# remains available as a fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KO="${1:-$ROOT/tcp_bbrp.ko}"
KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
DEST_DIR="/lib/modules/$KVER/extra"
DEST="$DEST_DIR/tcp_bbrp.ko"
MODULES_CONF="/etc/modules-load.d/tcp_bbrp.conf"
SYSCTL_CONF="/etc/sysctl.d/zz-bbrp.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ -d "$KDIR" ]] || { echo "ERROR: kernel headers not found: $KDIR" >&2; exit 1; }
[[ -f "$KO" ]] || { echo "ERROR: module not found: $KO" >&2; exit 1; }

echo "== checking module =="
modinfo "$KO" | grep -E '^(filename|description|name|vermagic|parm):'
VERMAGIC="$(modinfo -F vermagic "$KO" | awk '{print $1}')"
if [[ "$VERMAGIC" != "$KVER" ]]; then
    echo "ERROR: module vermagic '$VERMAGIC' does not match running kernel '$KVER'" >&2
    echo "Rebuild against /lib/modules/$KVER/build." >&2
    exit 1
fi

echo "== installing module =="
mkdir -p "$DEST_DIR"
install -m 644 "$KO" "$DEST"
depmod -a
modprobe tcp_bbrp
if ! grep -qw bbrp /proc/sys/net/ipv4/tcp_available_congestion_control; then
    echo "ERROR: bbrp did not register; check dmesg" >&2
    exit 1
fi

echo "== writing boot persistence =="
for f in "$MODULES_CONF" "$SYSCTL_CONF"; do
    if [[ -e "$f" ]]; then
        cp -a "$f" "$f.bak.$STAMP"
    fi
done
cat > "$MODULES_CONF" <<'EOF'
# Separate patched BBRv1 module (CC name: bbrp).
# The in-tree tcp_bbr remains available as a fallback.
tcp_bbr
tcp_bbrp
EOF
cat > "$SYSCTL_CONF" <<'EOF'
# This file sorts after /etc/sysctl.d/myconf.conf, which keeps bbr as fallback.
# If tcp_bbrp fails to load after a kernel upgrade, this write fails and bbr remains.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrp
EOF

echo "== applying sysctl =="
sysctl --system >/tmp/bbrp-sysctl.log 2>&1 || true
tail -20 /tmp/bbrp-sysctl.log || true
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "bbrp" ]]; then
    echo "ERROR: bbrp is not the effective default after sysctl --system" >&2
    exit 1
fi

echo "== restarting proxy listener (if present) =="
if systemctl is-active --quiet x-ui 2>/dev/null; then
    systemctl restart x-ui
    sleep 2
else
    echo "x-ui not active; restart your proxy service manually if needed"
fi

echo
echo "== installed =="
echo "cc=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"
cat /proc/sys/net/ipv4/tcp_available_congestion_control
cat /sys/module/tcp_bbrp/parameters/rwnd_aware 2>/dev/null || true
echo "module: $DEST"
echo "rollback: sudo $ROOT/scripts/bbrp-rollback.sh"
