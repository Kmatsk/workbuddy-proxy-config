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

## 静态规则说明

国内域名列表是手工维护的（`CN` 数组），比 geosite 数据集更可控；漏了的域名走代理，不会打不开。
