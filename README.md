# workbuddy-proxy-config

家里 NAS（192.168.3.100）上 v2rayA 的分流配置，集中放这里，改一次自动生效。

## 文件

| 文件 | 用途 | 谁在用 |
|---|---|---|
| `routingA.txt` | v2rayA 的 RoutingA 分流规则 | NAS 上的 v2rayA，每 6 小时自动拉取 |
| `workbuddy.pac` | 浏览器/系统的 PAC 自动分流脚本 | Windows 系统代理（自动配置脚本） |
| `clash-android.yaml` | Android 用 Clash 配置（HTTP 上游指向 NAS 20172） | FlClash / Clash Meta for Android |
| `docs/v2raya-data-and-upgrades.md` | **v2rayA 数据与升级运维手册**：备份/升级/迁移/回滚 + 官方原文 | 自己部署 v2rayA 的人 |
| `scripts/backup-v2raya.sh` | 一键备份配置目录（默认停服打包，避免 SQLite 撕裂） | 升级前、定期备份 |
| `scripts/restore-v2raya.sh` | 恢复备份（默认 dry-run，`--force` 才执行） | 回滚 / 换机迁移 |
| `scripts/sync-upstream.py` | 抓上游 README 章节，写进上面那份手册 | 本地手动同步 / GitHub Actions |
| `scripts/healthcheck-v2raya.py` | 体检脚本：面板、节点、端口、代理连通、分流规则 | 定期自查 / 排障 |
| `docs/healthcheck-2026-11-10.md` | 最近一次完整体检报告 | 排障参照 |
| `adguard/README.md` | **AdGuard Home 部署与排错**：DNS 链路、v2rayA 劫持豁免、路由器改法、拦截模式与缓存两个坑 | NAS 上的全屋 DNS 过滤 |
| `adguard/douyin-ads.txt` | 抖音/字节系广告域名规则（保守档，激进档默认注释） | AdGuard 自定义过滤器 |
| `adguard/china-app-ads.txt` | 百度联盟、快手、B站、爱优腾广告接口与归因 SDK（三档分级） | AdGuard 自定义过滤器 |

## v2rayA 怎么用

面板 → 设置 → 分流 → RoutingA，规则源填：

```
https://raw.githubusercontent.com/Kmatsk/workbuddy-proxy-config/main/routingA.txt
```

- 更新间隔：6 小时
- 直连更新（不经过代理下载）：开启
- 保存后立即拉取一次；之后每 6 小时检查，内容有变化才会应用并重启核心
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

## 部署与升级

官方文档里「数据与升级」那节只说了原则（哪些文件在配置目录、升级前先停服备份、2.4 之前要迁移 BoltDB），
落到 Docker 上还有一堆细节：卷怎么挂、`-wal` 文件要不要一起拷、容器重建丢什么、镜像 tag 怎么钉。

这些整理在 **[docs/v2raya-data-and-upgrades.md](docs/v2raya-data-and-upgrades.md)**：

- 官方原文（中/英）由 [workflow](.github/workflows/sync-v2raya-docs.yml) 每周一自动同步，跟着上游变
- 其余章节是实际部署经验：路径对照表、升级四步、验证清单、回滚、8 条常见坑
- 从零部署可以直接用 [`examples/docker-compose.yml`](examples/docker-compose.yml)，路径和文档里的一致

升级前的标准动作：

```bash
cd /vol1/1000/docker/v2raya
docker compose stop v2raya
sudo ./scripts/backup-v2raya.sh -d ./etc -o ./backups --stopped
docker compose pull && docker compose up -d
docker exec v2raya v2raya --version   # 与 v2raya_core 版本必须一致
```

> 备份包里含管理员密码哈希和全部订阅链接，脚本已设成 `600`。**别提交进仓库，也别放同步盘。**

## 全屋 DNS 过滤

NAS 上另跑了一个 AdGuard Home（`/vol1/1000/docker/AdGuard`），接管全屋 DNS，上游交给 v2rayA 内核解析：

```
LAN → 路由器 → PPPoE DNS 192.168.3.100:53 → AdGuard（过滤）→ v2rayA 内核 DNS（分流）
```

部署细节、为什么要在 `mangle` 表打 `0x80` 标记绕过 v2rayA 的 DNS 劫持、路由器 PPPoE DNS 怎么填，都在 **[adguard/README.md](adguard/README.md)**。

> AdGuard 的完整配置（含 22 个订阅列表、78 条自定义规则、备份与恢复脚本）已拆到独立仓库：
> **[workbuddy-adguard-config](https://github.com/Kmatsk/workbuddy-adguard-config)**。
> 这里只保留与代理分流耦合的那部分说明。

抖音规则单独一份：[adguard/douyin-ads.txt](adguard/douyin-ads.txt)。国内其它广告位（百度联盟、快手、B站、爱奇艺/优酷）在 [adguard/china-app-ads.txt](adguard/china-app-ads.txt)。**DNS 层拦不掉信息流视频广告和贴片广告**（和正片同域名同 CDN），能拦的是广告 SDK、监测、统计上报、归因平台，具体边界写在文件头和 README 里。

现网规则共 22 组、约 219 万条：HaGeZi Pro / AdRules / AdGuard DNS filter / Phishing Army / anti-AD / ShadowWhisperer Malware / URLHaus / AWAvenue / 四家国产手机 tracker / OISD Small / 以及家长控制四件套（HaGeZi NSFW 7.4 万 + OISD NSFW 48.6 万 + HaGeZi Gambling 64.1 万 + HaGeZi DoH 3.6 千），外加本仓库两份自定义规则。

拦截模式目前用 `0.0.0.0`（`blocking_mode: default`），实测正常工作——前提是路由器 PPPoE 的主 DNS 直接填 AdGuard（`192.168.3.100`），没有「主 DNS 失败就 fallback 到运营商 DNS」的链路。如果哪天发现广告又能解析了，先查这一步。

## 静态规则说明

国内域名列表是手工维护的（`CN` 数组），比 geosite 数据集更可控；漏了的域名走代理，不会打不开。
