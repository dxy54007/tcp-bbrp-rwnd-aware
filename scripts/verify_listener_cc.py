#!/usr/bin/env python3
"""Verify the TCP congestion-control algorithm of a listening socket.

Useful after an Xray/x-ui restart: the 443 listener must be bbrp, not bbr.
It duplicates the listener fd via pidfd_getfd and calls getsockopt(TCP_CONGESTION).
Requires root and Linux 5.6+.
"""
import argparse
import ctypes
import os
import re
import socket
import subprocess
import sys

TCP_CONGESTION = getattr(socket, "TCP_CONGESTION", 13)


def cc_name(value):
    if isinstance(value, int):
        return value.to_bytes(4, "little").rstrip(b"\x00").decode("ascii", "replace")
    if isinstance(value, (bytes, bytearray)):
        return value.rstrip(b"\x00").decode("ascii", "replace")
    return str(value)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("port", nargs="?", type=int, default=443)
    p.add_argument("--expect", default="bbrp")
    args = p.parse_args()

    out = subprocess.check_output(["ss", "-ltnp"], text=True)
    line = next((l for l in out.splitlines() if re.search(rf":{args.port}\s", l)), None)
    print("ss_line=", line)
    if not line:
        print(f"ERROR: no listener on port {args.port}", file=sys.stderr)
        return 1
    m = re.search(r"pid=(\d+),fd=(\d+)", line)
    if not m:
        print("ERROR: no pid/fd in ss output (run as root?)", file=sys.stderr)
        return 1

    pid, fd = int(m.group(1)), int(m.group(2))
    libc = ctypes.CDLL(None, use_errno=True)
    pidfd = libc.syscall(434, pid, 0)  # pidfd_open
    if pidfd < 0:
        print("ERROR: pidfd_open errno", ctypes.get_errno(), file=sys.stderr)
        return 1
    dupfd = libc.syscall(438, pidfd, fd, 0)  # pidfd_getfd
    if dupfd < 0:
        print("ERROR: pidfd_getfd errno", ctypes.get_errno(), file=sys.stderr)
        os.close(pidfd)
        return 1
    try:
        s = socket.socket(fileno=dupfd)
        value = s.getsockopt(socket.IPPROTO_TCP, TCP_CONGESTION)
        name = cc_name(value)
        print("listener_cc=", name)
        s.close()
    finally:
        os.close(pidfd)

    if args.expect and name != args.expect:
        print(f"ERROR: expected {args.expect}, got {name}", file=sys.stderr)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
