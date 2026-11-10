# v2rayA 体检报告 · 2026-11-10

## 环境

| 项 | 值 |
|---|---|
| 主机 | NAS `192.168.3.100`，Docker `host` 网络 + `privileged` |
| 版本 | v2rayA 2.5.14 / 内核 v5.x |
| 检测时间 | 2026-11-10 15:25 (GMT+8) |
| 检测方式 | `scripts/healthcheck-v2raya.py`，从局域网另一台机器发起 |

## 结果：15 项全部通过

```
[ok] 面板登录           — token 已获取
[ok] 核心运行           — running
[ok] 网络暂停           — 未暂停
[ok] 节点               — 1 个
[ok] 已连接节点         — github-anytls-1
[ok] 端口 socks5        — 192.168.3.100:20170
[ok] 端口 http          — 192.168.3.100:20171
[ok] 端口 socks5WithPac — 192.168.3.100:20173
[ok] 端口 httpWithPac   — 192.168.3.100:20172
[ok] 透明代理           — pac / redirect
[ok] 分流模式           — routingA
[ok] DNS 劫持           — yes @ 127.0.0.1:52353
[ok] 分流规则           — 10 条有效规则
[ok] 代理连通           — youtube.com → HTTP 200, 0.81s
[ok] Google 可达        — HTTP 200, 3.52s
```

退出码 0。

## 性能

| 指标 | 实测 |
|---|---|
| 节点 TCP 握手 | 280 ms 中位（法国 OVH，62.210.124.132） |
| YouTube 首页 | 0.81 s |
| Google 首页 | 3.52 s（首次冷连接 2.2 s 建链 + 渲染） |

节点在法国，280 ms 的握手延迟是物理距离决定的，不是故障。介意的话换日本/新加坡节点能压到 80–120 ms。

## 链路结构

```
局域网设备 / NAS 本机
   ├─ TCP 出站 ──> nat TP_RULE ──> REDIRECT :52345 ──> 核心 ──> 节点
   └─ UDP/TCP :53 ─> nat DNS_REDIRECT ──> REDIRECT :52353 ──> v2rayA DNS
                                                │
   例外: mark 0x80 的流量在 PREROUTING 首条 RETURN，直通 AdGuard:53
```

`TP_RULE` 末尾是 `-p tcp -j REDIRECT --to-ports 52345`，即**所有 TCP 出站都被接管**，
包括 853（DoT）。所以 AdGuard 配的 `tls://223.5.5.5` 实际是经 v2rayA 转发出去的，
多一层本地转发开销，但换来了 DNS 加密不被运营商篡改。

## 一个测量陷阱

在 NAS 本机上测任何 TCP 连接延迟都会得到 **0–1 ms** 的假数据——`TP_RULE` 把出站
全部 REDIRECT 到本地 52345，`connect()` 根本没出机器。本报告所有延迟数字都是从
局域网另一台机器测的。同理，在 NAS 上 `dig @192.168.3.100` 测的不是 AdGuard，
而是 v2rayA 自己的 52353。

## 结论

v2rayA 运行正常，代理链路通畅，透明代理与 DNS 劫持规则完整，分流规则已加载。
无需修复项。
