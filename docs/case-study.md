# Case study: BBRv1 premature STARTUP exit on a high-RTT access link

本文记录 `tcp_bbrp` 的排查过程、失败方案和最终实测。所有 IP 已省略；数据来自同一台 VPS、同一客户端、同一代理节点/路径的不同时间测试。

## 1. 现象

VPS 使用 BBR 时，单流下载在开始阶段会出现一个很明显的“台阶”：

- 前 1–2 秒只能到约 20–27 Mbps；
- 随后客户端接收窗口突然从几百 KB 跳到 4–8 MB；
- 但 BBR 已经退出 STARTUP，`pacing_gain` 从 2.88672 掉到 1；
- 之后虽然还能继续爬，但单流平均吞吐明显低于线路能力。

同一路径用 CUBIC 没有这个“提前退出”问题，但日常浏览的平滑度不如 BBR。目标因此不是换 CC，而是修复 BBRv1 的 STARTUP 判断。

## 2. 测试环境

- Debian 13
- 内核 `6.12.107+deb13-amd64`
- 1 vCPU / 约 1 GB RAM
- VPS 网卡 MTU 1450
- 客户端 RTT 约 140–190 ms
- 客户端通过 v2rayNG 连接同一节点
- 代理：Xray 26.9.9 / 3x-ui 3.8.5
- 采样：每秒一次 `ss -tin`，记录 cwnd、snd_wnd、RTT、delivery_rate、pacing_rate、pacing_gain、retrans、qdisc 统计等

## 3. 原始 BBR 的关键日志

一次典型的主流程：

```text
10:41:29  cwnd=57    snd_wnd=75264   bw=0.39 Mbps   pacing_gain=2.88672
10:41:31  cwnd=838   snd_wnd=395776  bw=22.5 Mbps   rwnd_limited=26.6%  pacing_gain=2.88672
10:41:32  cwnd=790   snd_wnd=4.1 MB  bw=27.3 Mbps   rwnd_limited=22%    pacing_gain=1  ← STARTUP 退出
10:41:44  cwnd=5078                  bw=175 Mbps    delivery=154.6 Mbps
```

关键点：

- 退出时 `snd_wnd` 只有 395 KB，后来 1 秒内跳到 4.1 MB；
- `cwnd=838` 时 `cwnd * mss ≈ 1.15 MB`，远大于 `snd_wnd=395 KB`，说明发送端被接收窗口限制；
- 但 BBRv1 的 `full_bw_cnt` 只跳过 `rs->is_app_limited`，不跳过接收窗口受限的轮次；
- 连续 3 个“带宽没涨”的轮次后，BBR 认为管道已满，退出 STARTUP。

## 4. 试过但不够的方案

### 4.1 `initcwnd 50`

- 把默认路由改成 `initcwnd 50 initrwnd 50`；
- 首个主流程 cwnd 确实从默认值提高到 57；
- STARTUP 退出点从约 20.4 Mbps 提高到约 27.3 Mbps；
- 峰值从约 106.8 Mbps 提高到约 165 Mbps；
- 但 12 秒左右的主流程平均仍在 53–59 Mbps 附近。

原因：

- 首个采样 `snd_wnd=75 KB`，50 MSS（约 69 KB）已经填满约 92% 的窗口；
- 客户端窗口 autotuning 还没长开，单纯加大 initcwnd 不能创造更多可发送窗口；
- `initrwnd 50` 只影响 VPS 接收方向（客户端上传），不是下载方向的关键。

结论：`initcwnd` 可以让峰值更高，但不能解决 STARTUP 在窗口受限阶段提前退出的问题。

### 4.2 BBRv3

- 实际安装、测试过 BBRv3；
- 在同一路径上仍然出现限速/爬升不理想；
- 已卸载并清理，不作为最终方案。

### 4.3 CUBIC

- CUBIC 没有 BBRv1 的 premature STARTUP exit；
- 但日常浏览的平滑度不如 BBR，用户明确更偏好 BBR；
- 因此不作为长期默认。

## 5. 最终补丁

### 5.1 为什么用独立模块

- 原 `tcp_bbr` 正被 SSH、系统连接和代理使用，`modprobe -r tcp_bbr` 会失败或破坏现有连接；
- 直接替换 `tcp_bbr.ko` 风险高，回滚也麻烦；
- 因此复制 BBRv1 源码，注册为新的模块 `tcp_bbrp` / CC `bbrp`；
- 原 `tcp_bbr.ko` 不动；回滚只需切回 `bbr` 并卸载/删除 `tcp_bbrp`。

BTF kfunc 注册也被移除：原模块已经注册了同一组 kfunc，第二个模块重复注册可能冲突；本模块只需要拥塞控制 ops。

### 5.2 判断条件

```c
static bool bbrp_is_rwnd_limited(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    return (u64)tcp_snd_cwnd(tp) * tp->mss_cache > tp->snd_wnd;
}
```

为什么不用 `tp->is_rwnd_limited`：

- 在该内核的 `struct tcp_sock` 中没有这个可直接读取的布尔字段；
- `ss` 里的 `rwnd_limited` 来自 `tcpi_rwnd_limited`（TCP chrono 统计），不是速率采样里的布尔值；
- 用 `cwnd * mss > snd_wnd` 更直接：发送端 cwnd 已经超过接收端通告窗口，就是接收窗口受限。

在 `bbr_check_full_bw_reached()` 中：

```c
if (bbr_full_bw_reached(sk) || !bbr->round_start || rs->is_app_limited)
    return;

if (rwnd_aware && bbrp_is_rwnd_limited(sk)) {
    bbr->full_bw_cnt = 0;
    return;
}
```

- rwnd-limited 轮次不增加 `full_bw_cnt`，并清零已有计数；
- 客户端窗口跳大后，如果带宽估计增长 ≥25%，`full_bw` 正常更新；
- 只有真正连续 3 个非 app-limited、非 rwnd-limited 且带宽不增长的轮次，才退出 STARTUP；
- `rwnd_aware` 模块参数默认 `Y`，可动态设为 `0` 做 A/B。

## 6. 成功轮次

测试时仍然保留了临时的 `initcwnd 50 initrwnd 50` 路由（补丁本身不依赖它）。成功轮次的主连接：

```text
11:08:29  cwnd=104    snd_wnd=266752   bw=4.58 Mbps    pacing_gain=2.88672
11:08:30  cwnd=858    snd_wnd=5159936  bw=23.17 Mbps   pacing_gain=2.88672
11:08:31  cwnd=15023  snd_wnd=8150528  bw=365.93 Mbps  pacing_gain=2.88672
11:08:32  cwnd=15023  snd_wnd=8331264  bw=403.78 Mbps  delivery=353.47 Mbps
11:08:43  cwnd=17024  snd_wnd=8335360  bw=387.90 Mbps  delivery=335.12 Mbps
```

汇总：

- 主连接发送 **471.8 MB**，持续 **41.7 s**，约 **94.9 Mbps** 平均；
- VPS 总 TX **507.1 MB / 41.7 s = 102.0 Mbps**；
- VPS 总 RX **480.4 MB = 96.6 Mbps**；
- `TcpRetransSegs=248`，`TCPLostRetransmit=0`，`TCPTimeouts=0`；
- qdisc `dropped=0`，`overlimits=0`；
- Xray CPU 约 13.9%，x-ui 0.8%；
- 客户端反馈“速度终于跑满了”。

注意：这里的 94.9 Mbps 是 41.7 秒窗口的平均值；瞬时 BBR 带宽估计达到 365–403 Mbps。实际测速 App 的数字会受测速服务器和线路影响。

对比原始 BBR 的同一类主流程：STARTUP 在 20.4 Mbps 退出，12 秒平均约 58.3 Mbps；`initcwnd 50` 只把退出点推到 27.3 Mbps，平均仍 53–59 Mbps。补丁的关键变化是：在 23.17 Mbps、窗口已经跳到 5.16 MB 时，`pacing_gain` 仍保持 2.88672，没有提前退出。

## 7. 复现方法

```bash
# 1. 构建
make
# 或针对自己的内核源码重新生成
./scripts/build.sh --from-source /path/to/tcp_bbr.c

# 2. 安装并设置默认
sudo ./scripts/install.sh

# 3. 验证
modinfo tcp_bbrp
sysctl net.ipv4.tcp_congestion_control
sudo python3 scripts/verify_listener_cc.py 443
python3 scripts/loopback_smoke.py

# 4. 断开客户端所有旧连接，重新连接后测速
```

如果你也想保留测试时的路由参数：

```bash
# 先查看当前默认路由
ip route show default
# 示例（gateway/device 请替换成你自己的）
sudo ip route replace default via <gateway> dev <device> initcwnd 50 initrwnd 50
```

本仓库不自动持久化该路由；它只负责拥塞控制模块。

## 8. 限制

- 只在 Debian 13 / 6.12.107 上完整验证；
- 其他内核需要确认 `tcp_bbr.c` 的 API/结构一致；
- 内核升级后必须重新编译模块；
- Secure Boot 环境需要签名；
- 单次测试不能代表所有线路；请用自己的客户端窗口/RTT/测速服务器验证；
- 如果客户端窗口一直不增长，补丁不会有魔法。

## 9. 附录

- 补丁：`patches/0001-bbrp-rwnd-aware-startup.patch`
- 原始对照源码：`patches/upstream-tcp_bbr-6.12.107.c`
- 生成脚本：`scripts/make_bbrp.py`
- 安装/回滚：`scripts/install.sh`、`scripts/bbrp-rollback.sh`
