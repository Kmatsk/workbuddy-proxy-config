# workbuddy-proxy-config

家里 NAS（192.168.3.100）上 v2rayA 的分流配置，集中放这里，改一次自动生效。

## 文件

| 文件 | 用途 | 谁在用 |
|---|---|---|
| `routingA.txt` | v2rayA 的 RoutingA 分流规则 | NAS 上的 v2rayA，每 24 小时自动拉取 |
| `workbuddy.pac` | 浏览器/系统的 PAC 自动分流脚本 | Windows 系统代理（自动配置脚本） |

## v2rayA 怎么用

面板 → 设置 → 分流 → RoutingA，规则源填：

```
https://raw.githubusercontent.com/Kmatsk/workbuddy-proxy-config/main/routingA.txt
```

- 更新间隔：24 小时
- 直连更新（不经过代理下载）：开启
- 保存后立即拉取一次；之后每 24 小时检查，内容有变化才会应用并重启核心
- 拉取失败或语法错误时**保留原规则**，不会把网络搞挂

## PAC 怎么用

Windows：设置 → 网络和 Internet → 代理 → 使用自动配置脚本：

```
https://cdn.jsdelivr.net/gh/Kmatsk/workbuddy-proxy-config@main/workbuddy.pac
```

分流逻辑：内网/IP 直连 → GitHub 全族走代理 → 国内域名直连 → 其余走 `PROXY 192.168.3.100:20172`。

## 改完怎么生效

- `routingA.txt`：提交后等下一次检查（或面板里手动保存一次触发）
- `workbuddy.pac`：jsdelivr 对 `@main` 有缓存，最长约 12 小时；急用可加 `?v=2` 之类的查询参数强制刷新

## 静态规则说明

国内域名列表是手工维护的（`CN` 数组），比 geosite 数据集更可控；漏了的域名走代理，不会打不开。
