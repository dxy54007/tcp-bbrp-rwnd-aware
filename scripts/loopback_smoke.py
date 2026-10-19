#!/usr/bin/env python3
"""Loopback smoke test for the tcp_bbrp module.

Requires:
  - the tcp_bbrp module is loaded
  - 'bbrp' appears in /proc/sys/net/ipv4/tcp_available_congestion_control
  - Python 3 on Linux

The test sets TCP_CONGESTION=bbrp on both ends of a loopback TCP connection
and transfers a configurable amount of data. It does not touch external
interfaces or the proxy configuration.
"""
import argparse
import queue
import socket
import threading
import time

TCP_CONGESTION = getattr(socket, "TCP_CONGESTION", 13)
IPPROTO_TCP = socket.IPPROTO_TCP
CC = b"bbrp"


def get_cc(sock):
    try:
        v = sock.getsockopt(IPPROTO_TCP, TCP_CONGESTION)
    except OSError as e:
        return f"getsockopt_error={e!r}"
    if isinstance(v, int):
        return v.to_bytes(4, "little").rstrip(b"\x00").decode("ascii", "replace")
    return v.decode("ascii", "replace") if isinstance(v, (bytes, bytearray)) else repr(v)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--size-mb", type=int, default=64)
    args = p.parse_args()
    total = args.size_mb * 1024 * 1024
    chunk = b"x" * (1024 * 1024)
    q = queue.Queue()
    errors = []

    def server():
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", 0))
            s.listen(1)
            q.put(s.getsockname()[1])
            conn, _ = s.accept()
            conn.setsockopt(IPPROTO_TCP, TCP_CONGESTION, CC)
            print("server_cc=", get_cc(conn))
            got = 0
            while got < total:
                data = conn.recv(1024 * 1024)
                if not data:
                    break
                got += len(data)
            conn.sendall(b"ok")
            conn.close()
            s.close()
            print("server_got=", got)
        except Exception as e:  # noqa: BLE001
            errors.append(repr(e))
            print("server_error=", repr(e))

    t = threading.Thread(target=server, daemon=True)
    t.start()
    port = q.get(timeout=5)
    c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    c.setsockopt(IPPROTO_TCP, TCP_CONGESTION, CC)
    c.connect(("127.0.0.1", port))
    print("client_cc=", get_cc(c))
    start = time.time()
    sent = 0
    while sent < total:
        c.sendall(chunk)
        sent += len(chunk)
    c.shutdown(socket.SHUT_WR)
    ack = c.recv(16)
    elapsed = time.time() - start
    print("client_sent=", sent)
    print("ack=", ack)
    print("elapsed_s=%.3f" % elapsed)
    print("throughput_Mbps=%.1f" % (sent * 8 / elapsed / 1e6))
    c.close()
    t.join(timeout=5)

    if errors:
        raise SystemExit("loopback errors: " + "; ".join(errors))
    print("OK: bbrp loopback transfer completed")


if __name__ == "__main__":
    main()
