#!/usr/bin/env python3
"""Create the patched BBR source tcp_bbrp.c from a kernel tcp_bbr.c.

Patch goal: do not count receive-window-limited rounds toward BBR STARTUP
exit.  A round is treated as receive-window-limited when the sender's
congestion window (in bytes) exceeds the receiver's advertised window.

Usage:
    PATCH_DIR=/path/to/workdir python3 make_bbrp.py

PATCH_DIR must contain the original tcp_bbr.c for the kernel being built.
The generated tcp_bbrp.c and Makefile are written to PATCH_DIR.  If
PATCH_DIR is omitted, the parent directory of this script is used.

The generator handles both older kernels (no BTF kfunc registration and
tp->snd_cwnd) and newer kernels (BTF_SET8/BTF_KFUNCS and tcp_snd_cwnd()).
"""
import os
import pathlib
import re
import sys

P = pathlib.Path(os.environ.get(
    "PATCH_DIR",
    str(pathlib.Path(__file__).resolve().parent.parent),
))
src_path = P / "tcp_bbr.c"
out_path = P / "tcp_bbrp.c"
src = src_path.read_text()


def replace_once(old, new, label):
    global src
    n = src.count(old)
    if n != 1:
        print(f"ERROR {label}: expected 1 occurrence, got {n}")
        sys.exit(1)
    src = src.replace(old, new)
    print(f"OK {label}")


# 1. Unique congestion-control name so the original bbr module stays loaded.
replace_once('\t.name\t\t= "bbr",', '\t.name\t\t= "bbrp",', "cc name")

# 2. Module parameter to allow A/B testing without rebuilding.
replace_once(
    "static const u32 bbr_full_bw_cnt = 3;",
    "static const u32 bbr_full_bw_cnt = 3;\n\n"
    "static bool rwnd_aware __read_mostly = true;\n"
    'module_param(rwnd_aware, bool, 0644);\n'
    'MODULE_PARM_DESC(rwnd_aware, "Do not count receive-window-limited rounds toward BBR STARTUP exit");',
    "module param",
)

# 3. Helper: cwnd in bytes > advertised receive window => rwnd-limited.
#    tcp_snd_cwnd() was added in 6.1; older trees still use tp->snd_cwnd.
marker = "/* Estimate when the pipe is full, using the change in delivery rate: BBR"
cwnd_expr = "tcp_snd_cwnd(tp)" if "tcp_snd_cwnd(" in src else "tp->snd_cwnd"
helper = (
    "/* Return true if the sender's congestion window exceeds the receiver's\n"
    " * advertised window, i.e. the connection is receive-window-limited.\n"
    " */\n"
    "static bool bbrp_is_rwnd_limited(struct sock *sk)\n"
    "{\n"
    "\tstruct tcp_sock *tp = tcp_sk(sk);\n"
    "\n"
    "\treturn (u64)" + cwnd_expr + " * tp->mss_cache > tp->snd_wnd;\n"
    "}\n\n"
)
replace_once(marker, helper + marker, "rwnd helper")

# 4. In STARTUP exit check, reset the counter on rwnd-limited rounds.
old_early = (
    "\tif (bbr_full_bw_reached(sk) || !bbr->round_start || rs->is_app_limited)\n"
    "\t\treturn;\n"
)
new_early = (
    old_early
    + "\n\tif (rwnd_aware && bbrp_is_rwnd_limited(sk)) {\n"
    "\t\t/* A receive-window-limited round is not evidence that the\n"
    "\t\t * path is full; don't count it toward STARTUP exit.\n"
    "\t\t */\n"
    "\t\tbbr->full_bw_cnt = 0;\n"
    "\t\treturn;\n"
    "\t}\n"
)
replace_once(old_early, new_early, "startup rwnd check")

# 5. Remove BTF kfunc registration when the kernel source has it.  The
#    original tcp_bbr module already registered this set; a second module
#    registering it can fail.  Older kernels (e.g. 5.15) have no such block.
btf_markers = (
    "BTF_KFUNCS_START(tcp_bbr_check_kfunc_ids)",
    "BTF_SET8_START(tcp_bbr_check_kfunc_ids)",
)
start = -1
for btf_marker in btf_markers:
    start = src.find(btf_marker)
    if start >= 0:
        break
if start < 0:
    print("SKIP BTF block not present (kernel has no tcp_bbr kfunc set)")
else:
    end_marker = "static const struct btf_kfunc_id_set tcp_bbr_kfunc_set = {"
    end_start = src.find(end_marker, start)
    if end_start < 0:
        print("ERROR BTF set not found")
        sys.exit(1)
    end = src.find("};", end_start)
    if end < 0:
        print("ERROR BTF end not found")
        sys.exit(1)
    end += 2
    removed = src[start:end]
    src = src[:start] + src[end:]
    print(f"OK removed BTF block ({len(removed)} bytes)")

# 6. Simplify module init to only register the congestion control.
new_init = """static int __init bbr_register(void)
{
\tBUILD_BUG_ON(sizeof(struct bbr) > ICSK_CA_PRIV_SIZE);

\treturn tcp_register_congestion_control(&tcp_bbr_cong_ops);
}"""
old_init_btf = """static int __init bbr_register(void)
{
\tint ret;

\tBUILD_BUG_ON(sizeof(struct bbr) > ICSK_CA_PRIV_SIZE);

\tret = register_btf_kfunc_id_set(BPF_PROG_TYPE_STRUCT_OPS, &tcp_bbr_kfunc_set);
\tif (ret < 0)
\t\treturn ret;
\treturn tcp_register_congestion_control(&tcp_bbr_cong_ops);
}"""
old_init_plain = """static int __init bbr_register(void)
{
\tBUILD_BUG_ON(sizeof(struct bbr) > ICSK_CA_PRIV_SIZE);

\treturn tcp_register_congestion_control(&tcp_bbr_cong_ops);
}"""
if old_init_btf in src:
    src = src.replace(old_init_btf, new_init, 1)
    print("OK simplified module init (BTF variant)")
elif old_init_plain in src:
    print("OK module init already registers only the congestion control")
else:
    init_re = re.compile(r"static int __init bbr_register\(void\)\n\{.*?\n\}", re.S)
    if len(init_re.findall(src)) != 1:
        print("ERROR module init: could not find a unique bbr_register() body")
        sys.exit(1)
    src = init_re.sub(lambda _m: new_init, src, count=1)
    print("OK simplified module init (regex variant)")

# 7. Describe the patched module clearly.
replace_once(
    'MODULE_DESCRIPTION("TCP BBR (Bottleneck Bandwidth and RTT)");',
    'MODULE_DESCRIPTION("TCP BBR patched: rwnd-aware STARTUP exit (bbrp)");',
    "module description",
)

out_path.write_text(src)
print(f"wrote {out_path} ({len(src)} bytes)")

makefile = """obj-m := tcp_bbrp.o
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
all:
\t$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
\t$(MAKE) -C $(KDIR) M=$(PWD) clean
"""
(P / "Makefile").write_text(makefile)
print(f"wrote {P / 'Makefile'}")
