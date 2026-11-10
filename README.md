# tcp_bbrp — 让 BBRv1 在接收窗口受限时不要提前退出 STARTUP

## 1. 环境要求、注意事项和懒人一键脚本

### 环境要求

- Debian 11+ 或 Ubuntu 20.04+，`x86_64` / `aarch64`，root 权限（非 root 运行脚本会自动用 `sudo` 重跑）。
- 真实 VPS 或独立服务器，不是 Docker、WSL 等容器环境；内核允许加载 out-of-tree 模块。
- 需要与 `uname -r` 完全匹配的 kernel headers；缺失时脚本会尝试通过 apt 自动安装。`gcc`、`make`、`python3` 等编译依赖同样会自动补齐。
- Secure Boot 已关闭，或你能给模块签名并完成 MOK 注册。
- Linux 4.9+；实测环境为 Debian 13 / 6.12。

### 注意事项

- 这是 out-of-tree 模块，升级内核后必须重新运行一次安装脚本。否则新内核加载旧模块会失败，开机自动回退到 `bbr` 或 `cubic`。
- 脚本只负责编译、安装 `bbrp` 并设置开机默认，**不会重启 x-ui、sing-box 等任何服务，也不会修改路由或 `initcwnd` / `initrwnd`**。安装后需要自己重启一次代理/监听服务，已有连接才会换成 `bbrp`。
- 如果仓库内源码和当前内核不兼容，脚本会自动安装匹配的 `linux-source` 重新生成；`/usr/src` 需要预留足够空间。
- 未签名模块会让内核进入 tainted 状态；建议先在带快照、有控制台的机器上测试。
- 回滚只恢复模块、sysctl 和开机配置；安装时通过 apt 装的编译依赖不会自动卸载。
- 回滚时如果模块仍被现有连接占用，可能需要重启一次才能彻底卸载。

### 懒人一键脚本

一键安装（自动编译 `bbrp` 并设为开机默认）：

```bash
curl -fsSL https://raw.githubusercontent.com/dxy54007/tcp-bbrp-rwnd-aware/main/scripts/install.sh -o /tmp/bbrp-install.sh && bash /tmp/bbrp-install.sh
```

一键回退（恢复安装前的模块、拥塞控制和开机配置）：

```bash
curl -fsSL https://raw.githubusercontent.com/dxy54007/tcp-bbrp-rwnd-aware/main/scripts/rollback.sh -o /tmp/bbrp-rollback.sh && bash /tmp/bbrp-rollback.sh
```

## 2. 解决了什么问题

BBRv1 在 STARTUP 阶段用连续 3 个 RTT 的带宽增长判断管道是否已经填满。高 RTT 接入链路上，客户端的初始接收窗口通常很小，服务端 cwnd 很快就会超过这个窗口，连接进入 rwnd-limited；此时带宽涨不上去并不是因为链路满了，但 BBR 会把它误判成“管道已满”，提前退出 STARTUP。

客户端接收窗口随后通过 autotuning 突然扩大到几 MB，但 BBR 已经离开 STARTUP，`pacing_gain` 从 2.88 掉到 1，错过了最快的爬升窗口，单流平均速度和首屏体验都会受影响。单纯加大 `initcwnd` 只能提高初始发送窗口，不能突破接收端窗口这个真正的限制；BBRv3 也存在同样的提前退出问题。

`bbrp` 的目标不是换掉 BBR，而是让 BBRv1 在 rwnd-limited 阶段不要把“窗口不够”当成“管道已满”。原版 `bbr` 和 `cubic` 保持不动，可以随时切回。

## 3. 修改的原理

`bbrp` 是从内核 `net/ipv4/tcp_bbr.c` 复制出来的独立模块：模块名 `tcp_bbrp`，拥塞控制名 `bbrp`，不会覆盖或卸载正在使用的 `tcp_bbr.ko`。

新增一个判断接收窗口是否受限的辅助函数：

```c
static bool bbrp_is_rwnd_limited(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    /* cwnd 已经大于接收端通告窗口，说明当前是 rwnd-limited */
    return (u64)tcp_snd_cwnd(tp) * tp->mss_cache > tp->snd_wnd;
}
```

然后在原来判断 STARTUP 是否结束的 `bbr_check_full_bw_reached()` 里，把 rwnd-limited 的轮次直接排除：

```c
if (rwnd_aware && bbrp_is_rwnd_limited(sk)) {
    /* 窗口受限不能证明管道已满，不计入 full_bw_cnt */
    bbr->full_bw_cnt = 0;
    return;
}
```

这样在接收窗口还没长开时，`full_bw_cnt` 不会累积到 3，BBR 会继续留在 STARTUP；等客户端窗口扩大、带宽真正停止增长后，再按原版逻辑正常退出。修改只影响 STARTUP 的退出判断，没有改 BBR 的 pacing、cwnd 或丢包处理。

其他必要改动：

- 模块名和拥塞控制名改为 `tcp_bbrp` / `bbrp`，与原版 BBR 共存。
- 去掉第二个模块重复注册 BTF kfunc 的代码，只注册拥塞控制 ops，避免和原 `tcp_bbr` 冲突。
- 增加模块参数 `rwnd_aware`，默认开启。设为 `0` 后行为退回原版 BBRv1，方便对比：

```bash
echo 0 > /sys/module/tcp_bbrp/parameters/rwnd_aware
```

- 仓库里的 `scripts/make_bbrp.py` 会按内核版本处理 `tcp_snd_cwnd()` / `tp->snd_cwnd` 以及 BTF 注册差异，方便在其他内核版本上重新生成。
