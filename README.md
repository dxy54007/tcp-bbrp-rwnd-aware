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

- **Debian 11+ 或 Ubuntu 20.04+**。`scripts/install.sh` 会检查 `/etc/os-release`；带 `ID_LIKE=debian/ubuntu` 的衍生版会给出提示，但只在 Debian/Ubuntu 上测试。
- Linux **4.9+**；支持 `x86_64` 和 `aarch64/arm64`，实测环境为 `x86_64`。
- root 权限，以及可用的 systemd（`modules-load.d`、`sysctl.d` 和代理服务重启都依赖它）。
- **不是容器 / WSL**：内核模块必须装到真实宿主机内核。脚本会检测 Docker、systemd 容器和 WSL 内核。
- 内核允许加载 out-of-tree 模块：
  - `CONFIG_MODULES=y`；
  - 未启用 kernel lockdown；
  - `kernel.modules_disabled=0`；
  - Secure Boot / `CONFIG_MODULE_SIG_FORCE` 场景下模块必须已签名并完成 MOK 注册。
- 与运行内核 **完全匹配** 的 kernel headers。`install.sh` 会优先使用已有的 `/lib/modules/$(uname -r)/build`，缺失时通过 apt 安装 `linux-headers-$(uname -r)`。
- 构建时需要 `gcc`、`make`、`python3`、`bc` 等；`install.sh` 会检查并安装缺失的依赖（可用 `--no-deps` 禁止）。
- 内核 BBRv1 源码 `net/ipv4/tcp_bbr.c`：
  - 优先使用仓库内已生成的 `tcp_bbrp.c`；
  - 若与当前内核不兼容，`install.sh` 会尝试安装版本匹配的 `linux-source` 并自动提取；
  - 也可以用 `--source /path/to/tcp_bbr.c` 明确指定。

如果内核没有启用 `CONFIG_MODULE_UNLOAD`，模块加载后无法立即卸载；回滚仍会恢复配置，但需要重启才能彻底卸载。

### 测试过的环境

- Debian 13
- 内核 `6.12.107+deb13-amd64`
- 1 vCPU / 1 GB RAM
- 构建时解压完整内核源码约需 **1.6 GB** 磁盘；只编译模块约需几十 MB
- 模块约 **750 KB**

`scripts/install.sh` / `scripts/rollback.sh` 支持 Debian 11+ 和 Ubuntu 20.04+；`scripts/make_bbrp.py` 已针对 Linux 5.15、6.1、6.8、6.12 的 `tcp_bbr.c` 做过生成测试。其他内核版本请用 `--source` 对准自己的源码，并检查生成的 diff。

### 安全启动 / 模块签名

- 如果 VPS 开启了 Secure Boot，未签名模块会加载失败；需要自行签名并注册 MOK，或关闭 Secure Boot。
- 如果内核启用了 `CONFIG_MODULE_SIG_FORCE` 或处于 lockdown，脚本会在安装前拒绝继续。
- 加载未签名 out-of-tree 模块会使内核进入 tainted 状态，这是正常现象，但生产环境请自行评估。

### 内核升级

这是 out-of-tree 模块，**不会自动跟着内核升级重新编译**：

- 升级内核后，`/lib/modules/$(uname -r)/extra/tcp_bbrp.ko` 对新内核无效；
- 开机的 `modules-load.d` 会尝试加载 `tcp_bbrp`。如果加载失败，`sysctl.d` 里的 `bbrp` 设置也会失败，系统会保留更早的 `bbr` 设置；如果没有任何更早设置，则使用内核默认的 `cubic`；
- 需要针对新内核的 headers 和 `tcp_bbr.c` 重新运行 `install.sh`；
- 旧内核的快照仍保存在 `/var/backups/tcp-bbrp/`，可以用 `rollback.sh --list` 查看，用 `--state` 指定；如果已有更新的 `current` 安装，需要加 `--force` 才能操作旧快照。

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
sudo apt-get install -y build-essential linux-headers-$(uname -r) python3
git clone https://github.com/dxy54007/tcp-bbrp-rwnd-aware.git
cd tcp-bbrp-rwnd-aware
make
```

产物：`./tcp_bbrp.ko`。只建议在源码版本与当前内核接近时使用；`install.sh` 会检查 `vermagic` 并在不匹配时改用版本匹配的源码重新生成。

### 方式 B：从你自己的内核 `tcp_bbr.c` 重新生成

```bash
./scripts/build.sh --from-source /path/to/linux/net/ipv4/tcp_bbr.c
```

脚本会：

1. 把原 `tcp_bbr.c` 放到临时目录；
2. 运行 `scripts/make_bbrp.py` 生成 `tcp_bbrp.c`；
3. 用当前内核 headers 编译。

`make_bbrp.py` 会按源码版本处理以下差异：

- 旧内核的 `BTF_SET8_START` / `BTF_KFUNCS_START` 和可选的 BTF 段；
- 旧版 `bbr_register()` 返回值/参数差异；
- `tcp_snd_cwnd(tp)` 与旧内核的 `tp->snd_cwnd`。

生成后请务必检查 `git diff tcp_bbrp.c`，确认补丁落在你的内核版本对应的位置。

### 方式 C：Debian / Ubuntu `linux-source`

```bash
# Debian 示例；请把 6.12 换成与你内核匹配的版本
sudo apt-get install -y linux-source-6.12
./scripts/build.sh --debian-source
```

`build.sh --debian-source` 默认读取 `/usr/src/linux-source-6.12.tar.xz`。其他版本可以用：

```bash
SRC_TARBALL=/usr/src/linux-source-6.1.tar.xz ./scripts/build.sh --debian-source
```

> `install.sh` 不依赖这个固定版本：它会按 `uname -r` 自动查找或安装匹配的 `linux-source`，并提取 `net/ipv4/tcp_bbr.c`。

> 编译出的模块 `vermagic` 必须与 `uname -r` 一致。`scripts/install.sh` 会检查这一点并拒绝不匹配的模块。

---

## 6. 安装为默认拥塞控制

推荐先做一次只读预检：

```bash
sudo ./scripts/install.sh --dry-run
```

确认无误后一键安装：

```bash
sudo ./scripts/install.sh
```

### 6.1 安装脚本做什么

1. **只读预检**：
   - Debian/Ubuntu、架构、内核版本、headers；
   - 容器 / WSL 检测；
   - Secure Boot、lockdown、`kernel.modules_disabled`、模块签名强制、`panic_on_oops` / `panic_on_warn`；
   - 现有安装状态、sysctl 文件顺序冲突、`modprobe` 黑名单/同名模块冲突；
   - 磁盘和内存余量、已运行的代理服务。
2. **安装构建依赖**（默认使用 `apt-get`；`--no-deps` 可禁止）。
3. **选择模块来源**：
   - `--ko PATH` 指定的预编译模块；
   - 仓库根目录下已验证的 `tcp_bbrp.ko`；
   - 用仓库 `tcp_bbrp.c` 编译；
   - 如果编译失败，安装版本匹配的 `linux-source` 并重新生成。
4. **写快照**：`/var/backups/tcp-bbrp/<时间戳>/`，并把 `/var/lib/tcp-bbrp/current` 指向它。快照包含原模块文件、原 boot 配置和原 CC/qdisc。
5. **安装模块**到 `/lib/modules/$(uname -r)/extra/tcp_bbrp.ko`，执行 `depmod -a`、`modprobe tcp_bbrp`，验证 `bbrp` 已注册且 `rwnd_aware` 可读。
6. **loopback 冒烟测试**：确认模块能实际传输数据（`--no-smoke` 可跳过，不推荐）。
7. **写开机持久化**并应用运行时设置。
8. **重启检测到的代理服务**，让已有 listener 重新创建 socket；可选检查 443 listener 的 CC。
9. **任何在快照之后发生的失败都会自动调用 `rollback.sh --auto`**，恢复原状态。

### 6.2 写入的文件

`/etc/modules-load.d/tcp_bbrp.conf`：

```text
# Managed by tcp-bbrp install.sh
tcp_bbr
tcp_bbrp
```

`/etc/sysctl.d/zz-bbrp.conf`：

```text
# Managed by tcp-bbrp install.sh
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrp
```

如果内核没有可用的 `sch_fq`，第一行会自动省略，脚本不会强行修改 qdisc。

### 为什么用 `zz-bbrp.conf`

- 不修改 `/etc/sysctl.d/myconf.conf` 等用户文件；
- `zz-bbrp.conf` 按文件名排在大多数配置之后，最后生效；
- `systemd-modules-load` 在 `systemd-sysctl` 之前运行，所以开机时先加载 `tcp_bbrp`，再设置 `bbrp`；
- 如果模块加载失败，`bbrp` 写入失败，更早的 `bbr` 配置或内核默认值仍然有效。

### 6.3 常用选项

| 选项 | 作用 |
|---|---|
| `--ko PATH` | 使用指定预编译模块（仍会校验名称、vermagic、GPL、`rwnd_aware`） |
| `--source PATH` | 从指定 `tcp_bbr.c` 重新生成并编译 |
| `--rebuild` | 忽略仓库里的 `tcp_bbrp.ko`，强制从源码构建 |
| `--no-deps` | 不调用 apt；依赖缺失时直接失败 |
| `-y`, `--yes` | 非交互；自动接受 `linux-source` 安装提示。缺失的 apt 依赖默认自动安装（`--no-deps` 可禁止） |
| `--dry-run` | 只做检查和计划输出，不修改系统 |
| `--no-smoke` | 跳过 loopback 冒烟测试 |
| `--no-restart` | 不重启任何代理服务 |
| `--restart SERVICE` | 安装后重启指定的 systemd unit（可重复；不再自动检测） |
| `--accept-risk` | 在 `panic_on_oops` / `panic_on_warn` 开启时仍继续（不推荐） |
| `--no-auto-rollback` | 失败后不自动回滚，保留现场用于调试（危险） |
| `--keep-build-dir` | 保留临时构建目录 |
| `--verbose` | 输出更多诊断信息 |
| `-h`, `--help` | 显示帮助 |

### 6.4 如果不使用 x-ui

脚本会自动检测这些常见 unit，只重启 **安装前正在运行** 的服务：

`x-ui`、`3x-ui`、`xray`、`v2ray`、`v2raya`、`sing-box`、`hysteria-server`、`hysteria`、`trojan-go`、`shadowsocks-libev`。

其他代理请手动重启，或使用 `--restart 你的服务名`。已经建立的 socket 不会自动切换 CC，必须重新创建 listener。

### 6.5 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 安装成功 |
| `1` | 安装失败（快照后失败会尝试自动回滚） |
| `2` | 参数/用法错误 |
| `3` | 模块和配置已安装，但有代理服务重启失败 |

### 6.6 失败点与恢复

| 失败点 | 系统状态 | 处理 |
|---|---|---|
| 预检失败 | 未修改系统 | 按错误提示修复（headers、Secure Boot、sysctl 冲突等）后重跑 |
| apt / 编译失败 | 未修改内核和 boot 配置 | 查看 `/var/log/tcp-bbrp/` 或构建日志；修复依赖后重跑 |
| 快照后、模块加载前失败 | 已写快照，可能已有模块文件 | 自动回滚会恢复/删除文件；也可手动 `rollback.sh --state ...` |
| 冒烟测试失败 | 模块已加载但未设为默认 | 自动回滚；若回滚也失败，按屏幕上的 manual recovery 操作 |
| 服务重启失败 | 安装已完成，退出码 3 | 修复服务后手动重启；模块仍可用 |
| 自动回滚失败 | 状态文件保留，屏幕打印手动步骤 | 不要急着重启；按步骤恢复或从控制台执行 `rollback.sh --force` |

日志默认在 `/var/log/tcp-bbrp/`。

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

先查看快照：

```bash
sudo ./scripts/rollback.sh --list
```

执行默认回滚：

```bash
sudo ./scripts/rollback.sh
```

默认行为：

- 从 `/var/lib/tcp-bbrp/current`（或 `--state` 指定的目录）读取安装快照；
- 把 `/etc/sysctl.d/zz-bbrp.conf`、`/etc/modules-load.d/tcp_bbrp.conf` 恢复为安装前的内容；原来不存在则删除；
- 把 `/lib/modules/$(uname -r)/extra/tcp_bbrp.ko` 恢复为安装前的文件；原来不存在则删除，并刷新 `depmod`；
- 当前 CC 切回安装前的值；不可用时退回 `bbr`，再退回 `cubic`；
- 如果安装时改过 qdisc，恢复安装前的 qdisc；
- 重启安装时记录的服务，让 socket 释放对 `bbrp` 的引用；
- 最多重试 5 次卸载 `tcp_bbrp`；仍有 socket 占用时保留模块到重启；
- 保留快照和日志用于审计；`--purge` 才会删除快照。

在修改文件前，脚本会把当前文件另存到：

```text
/var/backups/tcp-bbrp/rollback-<时间戳>/
```

原树内 `tcp_bbr.ko` 从头到尾没有被覆盖。

### 8.1 常用选项

| 选项 | 作用 |
|---|---|
| `--state DIR` | 使用指定快照，而不是 `current` |
| `--list` | 列出所有快照及状态 |
| `--runtime-only` | 只切回运行时 CC/qdisc 并重启服务；保留所有文件和已加载模块 |
| `--keep-config` | 保留 boot 配置、模块文件和已加载模块（运行时切换） |
| `--keep-module` | 保留 `tcp_bbrp.ko`；仍删除 boot 配置并尝试卸载 |
| `--remove` | 强制删除 `tcp_bbrp.ko`，而不是恢复安装前的副本 |
| `--purge` | 回滚成功后删除选中的快照；正常恢复/删除规则仍然生效 |
| `--reset-route` / `--full` | 额外去掉默认路由上的 `initcwnd` / `initrwnd` |
| `--no-restart` | 不重启任何服务 |
| `--restart` | 即使运行时 CC 没变，也重启记录的服务（不会启动未运行的服务） |
| `-y`, `--yes` | 不询问确认 |
| `--dry-run` | 只打印计划，不修改系统 |
| `--force` | 覆盖安全检查（模块文件哈希不匹配、未识别文件、仍加载时 purge 等） |
| `-h`, `--help` | 显示帮助 |

`--auto` 是 `install.sh` 内部使用的非交互模式：它不会 purge 快照，也不会重置路由。

`--state` 默认只接受与 `/var/lib/tcp-bbrp/current` 一致的快照。如果机器上已有更新的安装，却要清理旧内核的快照，必须显式加 `--force`，否则脚本会拒绝，避免覆盖新安装的 boot 配置。

### 8.2 默认流程

1. 获取锁，读取快照并显示计划；除非 `--yes`，否则要求确认。
2. 切换运行时 CC。**如果 CC 切换失败，脚本会在修改任何文件之前停止**，避免留下“运行时已回退、开机仍加载 bbrp”的半成品。
3. 重启安装时记录的服务，等待 socket 释放。
4. 恢复/删除 boot 配置；只处理带 install.sh marker 或符合旧版 `tcp_bbrp` 布局的文件。
5. 卸载模块（重试 5 次），恢复/删除模块文件，执行 `depmod`。
6. 可选地重置默认路由。
7. 把快照状态标记为 `rolled-back`；`--purge` 时删除快照。

### 8.3 没有快照时

如果找不到带 `meta.env` 的快照（例如手工安装或旧版本残留），脚本会进入保守回退模式：

- 删除带 marker 或符合旧版布局的 `tcp_bbrp` 配置；
- 把当前 `bbrp` 切回 `bbr` / `cubic`；
- 卸载 `tcp_bbrp`；
- 不删除无法识别的文件；模块文件无法用记录哈希校验时，需要 `--force` 才删除；
- 无法恢复自定义的原始 CC/qdisc，建议尽量使用带快照的回滚。

### 8.4 旧命令兼容

旧的 `scripts/bbrp-rollback.sh` 现在是兼容包装器：

```bash
sudo ./scripts/bbrp-rollback.sh              # 等价于 rollback.sh
sudo ./scripts/bbrp-rollback.sh --full       # 等价于 rollback.sh --reset-route
sudo ./scripts/bbrp-rollback.sh --keep-config
sudo ./scripts/bbrp-rollback.sh --remove
```

新脚本和文档请直接使用 `rollback.sh`。

### 8.5 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 回滚干净完成 |
| `1` | 关键失败（备份缺失、CC 无法切换、文件恢复失败等） |
| `2` | 参数或快照状态错误 |
| `3` | 回滚完成，但有警告（服务重启失败、模块仍占用等） |

### 8.6 回滚失败点与恢复

| 失败点 | 系统状态 | 处理 |
|---|---|---|
| CC 切换失败 | 文件和 boot 配置未修改 | 确认 `bbr` / `cubic` 可用后重跑；不要先删 boot 配置 |
| boot 配置备份缺失 | 对应文件保持不动 | 从 `/var/backups/tcp-bbrp/rollback-*` 或手工备份恢复 |
| 服务重启失败 | 配置已恢复，退出码 3 | 修复服务后手动重启；必要时 `--restart` 重跑 |
| 模块仍被占用 | boot 配置已恢复，模块保留到重启 | 重跑 `rollback.sh`，或重启后执行 `modprobe -r tcp_bbrp` |
| purge 被拒绝 | 快照保留 | 先解决模块占用/保留配置问题，或明确使用 `--force` |
| 回滚过程被中断 | 可能只完成一部分 | 重新运行 `rollback.sh --state ...`；快照状态和日志会保留 |
| 回滚关键失败 | 状态标记为 `rollback-failed` | 查看 `/var/log/tcp-bbrp/`，修复后用 `rollback.sh --force --state ...` |

> 如果模块导致新 SSH 连接异常，已有 SSH 会话通常还在；也可以从 VPS 控制台执行回滚。
>
> 如果 VPS 直接重启，由于 boot 配置已被删除/恢复，或模块加载失败，系统会回到 `bbr`/`cubic`。

---

## 9. 仓库文件

```text
.
├── README.md
├── LICENSE                         # GPL-2.0
├── .gitattributes                  # 脚本/配置强制 LF，避免 CRLF 破坏执行
├── Makefile
├── tcp_bbrp.c                      # 已生成的补丁源码（基于 Debian 6.12.107）
├── patches/
│   ├── 0001-bbrp-rwnd-aware-startup.patch
│   └── upstream-tcp_bbr-6.12.107.c # 对照用原始源码
├── scripts/
│   ├── make_bbrp.py                # 从 tcp_bbr.c 生成 tcp_bbrp.c
│   ├── build.sh                    # 开发/手工构建
│   ├── install.sh                  # 一键安装（Debian/Ubuntu）
│   ├── rollback.sh                 # 一键回滚/状态恢复
│   ├── bbrp-rollback.sh            # 旧命令兼容包装器（已弃用）
│   ├── loopback_smoke.py
│   └── verify_listener_cc.py
├── examples/
│   ├── modules-load.d/tcp_bbrp.conf
│   └── sysctl.d/zz-bbrp.conf
└── docs/
    └── case-study.md               # 排查过程、失败方案、完整时间线
```

运行时状态不在仓库内：

- 快照：`/var/backups/tcp-bbrp/`
- 当前快照指针：`/var/lib/tcp-bbrp/current`
- 日志：`/var/log/tcp-bbrp/`

---

## 10. 风险和限制

- 这是 out-of-tree 内核模块，不是上游 BBR 的正式修复；内核升级后必须重新构建。
- 未签名模块会 taint 内核；Secure Boot 环境需要签名并注册 MOK。
- 补丁改变的是 BBRv1 的 STARTUP 退出判断，不改变 BBR 的 pacing/cwnd 模型；极端情况下可能延长 STARTUP、增加短时排队或重传。请在有控制台/快照的 VPS 上测试。
- **自动回滚无法处理内核 panic、hard lock-up 或模块导致的立即重启**。因此安装脚本会拒绝在 `kernel.panic_on_oops` / `kernel.panic_on_warn` 开启时继续，除非明确传入 `--accept-risk`；生产环境请先做快照并确认有控制台。
- 安装脚本安装的 apt 构建依赖（headers、build-essential、python3 等）不会在回滚时自动卸载：它们可能被其他软件共享，自动删除风险更高。需要时请手工 `apt-get remove`。
- 默认回滚不修改路由的 `initcwnd` / `initrwnd`；需要时用 `--reset-route`。该选项只处理默认路由，不处理策略路由或多默认路由。
- `--no-auto-rollback` 会保留失败现场，适合调试，但可能让机器停在“模块已加载、boot 配置已部分写入”的状态；生产环境不建议。
- 不同内核的 `tcp_bbr.c` 可能有差异；请用 `install.sh --source` 或 `build.sh --from-source` 对准自己的源码重新生成并检查 diff。
- 没有 warranty。生产环境请先快照、保留回滚路径。

---

## 11. License

- `tcp_bbrp.c` / patch 基于 Linux 内核 `net/ipv4/tcp_bbr.c`，遵循 **GPL-2.0**（源码中保留 `Dual BSD/GPL` 模块声明）。
- 仓库中的脚本和文档同样以 GPL-2.0 提供，见 `LICENSE`。

---

## English summary

`tcp_bbrp` is a separate out-of-tree Linux kernel module (CC name `bbrp`) that patches BBRv1's `bbr_check_full_bw_reached()` so receive-window-limited rounds do not increment `full_bw_cnt`. This prevents BBR from leaving STARTUP at ~20–27 Mbps while the client's receive window is still small and about to autotune to several MB. The original in-tree `tcp_bbr` is untouched. Tested on Debian 13 / kernel 6.12.107: a single flow reached 94.9 Mbps average over 41.7 s (471.8 MB), with zero loss/timeouts and zero qdisc drops, while `pacing_gain` remained 2.88672 through the 23.17 → 365.9 Mbps transition. `scripts/install.sh` provides a one-click, preflight-checked installer for Debian/Ubuntu with an automatic rollback transaction; `scripts/rollback.sh` restores the previous module, boot configuration, runtime CC/qdisc, and services from a snapshot.
