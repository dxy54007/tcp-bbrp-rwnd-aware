# tcp_bbrp — receive-window-aware BBRv1 STARTUP patch

> 一个独立的 out-of-tree Linux 内核模块：当客户端接收窗口（rwnd）还没长开时，不让 BBRv1 把“接收窗口受限”误判成“管道已满”而提前退出 STARTUP。
>
> 原树内 `tcp_bbr.ko` 完全不动；本模块注册为新的拥塞控制算法 **`bbrp`**，可以随时切回 `bbr` 或 `cubic`。

---

## 1. 为什么需要这个补丁

BBRv1 在 STARTUP 阶段用 `full_bw_cnt` 判断“管道是否已经填满”：

- 如果连续 3 个非 app-limited 的 RTT 轮次里，带宽估计没有增长 25% 以上，就认为 STARTUP 结束，进入 DRAIN/PROBE_BW。
- 这个判断默认“带宽不涨 = 管道满了”。

但在高 RTT 的接入链路上，常见的情况是：

1. 客户端初始接收窗口只有 75–120 KB；
2. RTT 约 140–160 ms 时，这个窗口对应的理论吞吐只有约 20 Mbps；
3. 服务端 BBR 很快把 cwnd 撑到超过客户端窗口，进入 **rwnd-limited**；
4. 此时带宽当然涨不上去，`full_bw_cnt` 连续 3 轮递增，BBR 提前退出 STARTUP；
5. 大约 1 秒后，客户端窗口突然从几百 KB 跳到 4–8 MB；
6. 但 BBR 已经不在 STARTUP，pacing_gain 从 2.88672 掉到 1，错过了最快的爬升窗口。

在本项目的排查中：

- 原始 BBR 的 STARTUP 在约 **20.4 Mbps** 提前退出；
- 只加 `initcwnd 50`，退出点只提高到约 **27.3 Mbps**，平均吞吐仍在 **53–59 Mbps** 附近；
- BBRv3 实测仍受同一问题影响；
- CUBIC 没有这个 premature STARTUP exit，但日常浏览的平滑度不如 BBR。

所以目标不是换拥塞控制，而是让 **BBRv1 在 rwnd-limited 阶段不要退出 STARTUP**。

---

## 2. 补丁做了什么

### 2.1 独立模块，不覆盖原 BBR

- 模块名：`tcp_bbrp`
- 拥塞控制名：`bbrp`
- 原 `tcp_bbr` / `bbr` 保持加载，SSH、系统连接和回滚都可以继续使用原 BBR。
- 这样不需要卸载正在被 SSH 使用的 `tcp_bbr`，也不会和原模块的 BTF kfunc 注册冲突（补丁里移除了第二个模块的 BTF kfunc 注册，只注册拥塞控制 ops）。

### 2.2 核心判断

在 `bbr_check_full_bw_reached()` 里增加：

```c
static bool bbrp_is_rwnd_limited(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    /* cwnd 已经大于接收端通告窗口，说明当前是 rwnd-limited */
    return (u64)tcp_snd_cwnd(tp) * tp->mss_cache > tp->snd_wnd;
}
```

```c
if (bbr_full_bw_reached(sk) || !bbr->round_start || rs->is_app_limited)
    return;

if (rwnd_aware && bbrp_is_rwnd_limited(sk)) {
    /* 窗口受限的轮次不能证明管道已满，不计入 full_bw_cnt */
    bbr->full_bw_cnt = 0;
    return;
}
```

效果：

- rwnd-limited 期间，`full_bw_cnt` 不会累积到 3；
- 客户端窗口从几百 KB 跳到 4–8 MB 后，BBR 仍在 STARTUP；
- 等带宽估计真正停止增长（或触发 loss 保护）时再退出，而不是在 20–27 Mbps 就退出。

### 2.3 可开关的模块参数

```bash
cat /sys/module/tcp_bbrp/parameters/rwnd_aware
# Y
```

- 默认 `Y`：启用 rwnd-aware 行为；
- 设为 `N`：行为退回原版 BBRv1，便于同一模块内做 A/B 对比：

```bash
echo 0 > /sys/module/tcp_bbrp/parameters/rwnd_aware
```

---

## 3. 实测效果

测试环境（同一台 VPS、同一客户端、同一节点/路径）：

- Debian 13
- 内核 `6.12.107+deb13-amd64`
- 1 vCPU / 约 1 GB RAM
- 客户端 RTT 约 140–190 ms
- 测速方式与之前相同；测试时路由仍保留临时 `initcwnd 50 initrwnd 50`

| 方案 | STARTUP 表现 | 单流/主连接结果 | 备注 |
|---|---|---|---|
| 原始 BBR | 约 20.4 Mbps 提前退出 | 12 秒主流程平均约 58.3 Mbps | 客户端窗口随后跳到 4.1 MB |
| BBR + `initcwnd 50` | 退出点约 27.3 Mbps | 平均仍约 53–59 Mbps，峰值约 165 Mbps | 只提高峰值，没解决平均 |
| **`tcp_bbrp`** | 23.17 Mbps → 365.9 Mbps 时 `pacing_gain` 仍是 **2.88672** | 主连接 **471.8 MB / 41.7 s = 94.9 Mbps**；VPS 总 TX **507.1 MB = 102.0 Mbps** | 0 lost、0 timeout、qdisc 0 drop；248 次重传 |

成功轮次的关键时间线（1 秒采样）：

```text
11:08:29  cwnd=104    snd_wnd=266752   bw=4.58 Mbps    pacing_gain=2.88672
11:08:30  cwnd=858    snd_wnd=5159936  bw=23.17 Mbps   pacing_gain=2.88672
11:08:31  cwnd=15023  snd_wnd=8150528  bw=365.93 Mbps  pacing_gain=2.88672
```

对比原始 BBR 的失败轮次：

```text
10:41:31  cwnd=838    snd_wnd=395776   bw=22.5 Mbps    pacing_gain=2.88672
10:41:32  cwnd=790    snd_wnd=4.1 MB   bw=27.3 Mbps    pacing_gain=1  ← 提前退出
```

> 这些数字来自特定 VPS、客户端、测速服务器和线路状态，不是通用 benchmark。你的客户端窗口增长速度、RTT、代理实现和测速服务器都会影响结果。

---

## 4. 硬件 / 软件要求

### 必需

- Linux，x86_64（本仓库只在 x86_64 上测试过）
- 可加载 out-of-tree 内核模块（`CONFIG_MODULES=y`）
- 与运行内核 **完全匹配** 的 kernel headers：
  - Debian/Ubuntu：`linux-headers-$(uname -r)`
- `gcc`、`make`、`python3`
- root 权限
- 内核 BBRv1 源码 `net/ipv4/tcp_bbr.c`（用于重新生成补丁；仓库里也放了已生成的 `tcp_bbrp.c`）

### 测试过的环境

- Debian 13
- `6.12.107+deb13-amd64`
- 1 vCPU / 1 GB RAM
- 构建时解压完整内核源码约需 **1.6 GB** 磁盘；只编译模块约需几十 MB
- 模块约 **750 KB**

### 安全启动 / 模块签名

- 如果 VPS 开启了 Secure Boot，未签名模块会加载失败；需要自行签名并注册 MOK，或关闭 Secure Boot。
- 加载未签名 out-of-tree 模块会使内核进入 tainted 状态，这是正常现象，但生产环境请自行评估。

### 内核升级

这是 out-of-tree 模块，**不会自动跟着内核升级重新编译**：

- 升级内核后，`/lib/modules/$(uname -r)/extra/tcp_bbrp.ko` 对新内核无效；
- `tcp_bbrp` 加载失败时，`/etc/sysctl.d/myconf.conf` 里的 `bbr` 会作为 fallback；
- 需要针对新内核的 headers 和 `tcp_bbr.c` 重新构建、安装。

### 适用场景

适合：

- 高 RTT、客户端接收窗口初始较小、但随后会 autotuning 增长的链路；
- BBRv1 在单流上出现“启动阶段十几/二十几 Mbps 就掉出 STARTUP”的现象；
- 希望保留 BBR 的日常浏览体验，同时恢复单流爬升速度。

不适合/不要期待：

- 客户端窗口始终不增长；
- 线路本身只有 20 Mbps；
- 测速服务器或代理本身是瓶颈；
- 内核的 `tcp_bbr.c` 已经和 6.12 版本差异很大（需要重新适配补丁）。

---

## 5. 构建

### 方式 A：直接编译仓库内的 `tcp_bbrp.c`

```bash
sudo apt-get update
sudo apt-get install -y build-essential linux-headers-$(uname -r)

git clone https://github.com/dxy54007/tcp-bbrp-rwnd-aware.git
cd tcp-bbrp-rwnd-aware
make
```

产物：`./tcp_bbrp.ko`

### 方式 B：从你自己的内核 `tcp_bbr.c` 重新生成

适合内核版本不是 6.12.107，或你想确认补丁与自己内核源码完全匹配：

```bash
./scripts/build.sh --from-source /path/to/linux/net/ipv4/tcp_bbr.c
```

脚本会：

1. 把原 `tcp_bbr.c` 放到临时目录；
2. 运行 `scripts/make_bbrp.py` 生成 `tcp_bbrp.c`；
3. 用当前内核 headers 编译。

### 方式 C：Debian `linux-source-6.12`

```bash
sudo apt-get install -y linux-source-6.12
./scripts/build.sh --debian-source
```

默认读取 `/usr/src/linux-source-6.12.tar.xz`；也可以用 `SRC_TARBALL=/path/to/linux-source-6.12.tar.xz` 指定。

> 编译出的模块 `vermagic` 必须与 `uname -r` 一致。`scripts/install.sh` 会检查这一点并拒绝不匹配的模块。

---

## 6. 安装为默认拥塞控制

```bash
sudo ./scripts/install.sh
```

脚本会做这些事：

1. 检查模块 `vermagic`；
2. 安装到 `/lib/modules/$(uname -r)/extra/tcp_bbrp.ko`；
3. `depmod -a` + `modprobe tcp_bbrp`；
4. 写入 `/etc/modules-load.d/tcp_bbrp.conf`：
   ```text
   tcp_bbr
   tcp_bbrp
   ```
5. 写入 `/etc/sysctl.d/zz-bbrp.conf`：
   ```text
   net.core.default_qdisc = fq
   net.ipv4.tcp_congestion_control = bbrp
   ```
6. 执行 `sysctl --system`；
7. 如果 `x-ui` 正在运行，重启它，让 443 listener 用新默认 CC 重建。

### 为什么用 `zz-bbrp.conf`

- 原来的 `/etc/sysctl.d/myconf.conf` 仍然保留 `bbr` 作为 fallback；
- `zz-bbrp.conf` 按文件名排在 `myconf.conf` 之后，最后生效；
- `systemd-modules-load` 在 `systemd-sysctl` 之前运行，所以开机时先加载 `tcp_bbrp`，再设置 `bbrp`。

### 如果不使用 x-ui

脚本不会强行重启其他服务。安装后手动重启你的代理/监听服务，让监听 socket 重新创建即可。

---

## 7. 验证

### 7.1 模块和默认 CC

```bash
modinfo tcp_bbrp
cat /proc/sys/net/ipv4/tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
cat /sys/module/tcp_bbrp/parameters/rwnd_aware
```

期望：

```text
... reno cubic bbr bbrp
net.ipv4.tcp_congestion_control = bbrp
net.core.default_qdisc = fq
Y
```

### 7.2 确认 443 listener 真的是 bbrp

不要只看 `sysctl`，因为 listener 必须重新创建才会使用新默认：

```bash
sudo python3 scripts/verify_listener_cc.py 443
# listener_cc= bbrp
# OK
```

### 7.3 loopback 冒烟测试

```bash
python3 scripts/loopback_smoke.py --size-mb 64
```

期望看到 `client_cc= bbrp`、`server_cc= bbrp`，传输完成且无异常。

### 7.4 动态 A/B

```bash
# 关闭 rwnd-aware，行为退回原版 BBRv1
echo 0 | sudo tee /sys/module/tcp_bbrp/parameters/rwnd_aware

# 重新打开
echo 1 | sudo tee /sys/module/tcp_bbrp/parameters/rwnd_aware
```

> 该参数只影响新行为判断，不需要重启模块；但测速连接需要完全断开重连，才能保证走新 socket。

---

## 8. 回滚

```bash
sudo ./scripts/bbrp-rollback.sh
```

默认行为：

- 删除 `/etc/sysctl.d/zz-bbrp.conf` 和 `/etc/modules-load.d/tcp_bbrp.conf`（取消开机默认）；
- 当前默认 CC 切回 `bbr`；
- 如果 `x-ui` 在运行，重启它；
- 如果 `tcp_bbrp` 已无 socket 使用，卸载模块；
- 原 `tcp_bbr.ko` 从头到尾没有被覆盖。

常用选项：

```bash
# 只切回 bbr，保留开机默认文件
sudo ./scripts/bbrp-rollback.sh --keep-config

# 连同 /lib/modules/.../extra/tcp_bbrp.ko 一起删除
sudo ./scripts/bbrp-rollback.sh --remove

# 如果你还改过默认路由的 initcwnd/initrwnd，可顺便恢复
sudo ./scripts/bbrp-rollback.sh --full
```

> 如果模块导致新 SSH 连接异常，已有的 SSH 会话通常还在；也可以从 VPS 控制台执行回滚。  
> 如果 VPS 直接重启，由于开机默认文件已被删除/或模块加载失败，系统会回到 `bbr`（`myconf.conf` 的 fallback）。

---

## 9. 仓库文件

```text
.
├── README.md
├── LICENSE                         # GPL-2.0
├── Makefile
├── tcp_bbrp.c                      # 已生成的补丁源码（基于 Debian 6.12.107）
├── patches/
│   ├── 0001-bbrp-rwnd-aware-startup.patch
│   └── upstream-tcp_bbr-6.12.107.c # 对照用原始源码
├── scripts/
│   ├── make_bbrp.py                # 从 tcp_bbr.c 生成 tcp_bbrp.c
│   ├── build.sh
│   ├── install.sh
│   ├── bbrp-rollback.sh
│   ├── loopback_smoke.py
│   └── verify_listener_cc.py
├── examples/
│   ├── modules-load.d/tcp_bbrp.conf
│   └── sysctl.d/zz-bbrp.conf
└── docs/
    └── case-study.md               # 排查过程、失败方案、完整时间线
```

---

## 10. 风险和限制

- 这是 out-of-tree 内核模块，不是上游 BBR 的正式修复；内核升级后必须重新构建。
- 未签名模块会 taint 内核；Secure Boot 环境需要签名。
- 补丁改变的是 BBRv1 的 STARTUP 退出判断，不改变 BBR 的 pacing/cwnd 模型；极端情况下可能延长 STARTUP、增加短时排队或重传。请在有控制台/快照的 VPS 上测试。
- 本仓库只负责拥塞控制。测试时使用的 `initcwnd 50` 属于路由参数，不由本模块设置；是否保留取决于你的路径和客户端行为。
- 不同内核的 `tcp_bbr.c` 可能有差异；请用 `--from-source` 对准自己的源码重新生成并检查 diff。
- 没有 warranty。生产环境请先快照、保留回滚路径。

---

## 11. License

- `tcp_bbrp.c` / patch 基于 Linux 内核 `net/ipv4/tcp_bbr.c`，遵循 **GPL-2.0**（源码中保留 `Dual BSD/GPL` 模块声明）。
- 仓库中的脚本和文档同样以 GPL-2.0 提供，见 `LICENSE`。

---

## English summary

`tcp_bbrp` is a separate out-of-tree Linux kernel module (CC name `bbrp`) that patches BBRv1's `bbr_check_full_bw_reached()` so receive-window-limited rounds do not increment `full_bw_cnt`. This prevents BBR from leaving STARTUP at ~20–27 Mbps while the client's receive window is still small and about to autotune to several MB. The original in-tree `tcp_bbr` is untouched. Tested on Debian 13 / kernel 6.12.107: a single flow reached 94.9 Mbps average over 41.7 s (471.8 MB), with zero loss/timeouts and zero qdisc drops, while `pacing_gain` remained 2.88672 through the 23.17 → 365.9 Mbps transition.
