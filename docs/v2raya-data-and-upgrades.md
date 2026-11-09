# v2rayA 数据与升级（自部署运维手册）

> 适用场景：把 v2rayA 装在 NAS / 软路由 / 小主机上，用 Docker 或 systemd 跑，长期自用。
>
> 本页的**「官方原文」两节由脚本自动同步**上游 [v2rayA/v2rayA](https://github.com/v2rayA/v2rayA) README，
> 其余章节是把它落到真实部署上的具体做法、命令和踩坑记录。上游改了原文，这里跟着变；人工经验部分不会被覆盖。

上游原文地址：<https://github.com/v2rayA/v2rayA#data-and-upgrades>（中文：<https://github.com/v2rayA/v2rayA/blob/master/README_zh.md#数据与升级>）

## 这份文档解决什么

- 升级前该备份什么、备份放哪、出问题怎么回滚
- 配置目录、数据库、日志到底在哪，**容器重建后什么会丢**
- 从 2.4 之前的老版本升上来会发生什么（账户为什么要重新注册）
- `v2raya` 和 `v2raya_core` 版本不一致怎么发现
- 换机器迁移时按什么顺序恢复

---

## 一、官方原文（中文）

<!-- BEGIN UPSTREAM zh -->
<!-- source: https://github.com/v2rayA/v2rayA/blob/main/README_zh.md#数据与升级 | commit: 92caf05 | synced: 2026-11-09 -->

SQLite 数据库 `v2raya.db` 与生成的内核配置位于配置目录：Linux 与 macOS 为 `/etc/v2raya`，Windows 服务为 `%ProgramData%\SYSTEM\v2rayA`，`--lite` 为用户配置目录，也可用 `--config` 指定。systemd 与 OpenRC 单元把日志写到 `/var/log/v2raya/v2raya.log`，也可用 `--log-file` 或 `V2RAYA_LOG_FILE` 指定。程序在更新订阅、下载规则数据、测量延迟、解析 DNS、启动时和每周一次向 GitHub 检查新版本，以及 VMess 节点失败时向 `ntp.aliyun.com` 查询时间（用于区分时钟错误与节点故障）时发起网络请求。

升级前先停止服务并备份配置目录。从 2.4 以下版本升级时，首次启动会迁移 BoltDB 数据库，旧文件保留为 `bolt.db.bak`（该名称已存在时为 `bolt.db.bak.1` 及后续编号），账户需要重新注册。`v2raya` 与 `v2raya_core` 必须一起升级：仪表板显示内核版本，版本不一致时显示横幅提示。

<!-- END UPSTREAM zh -->

## 二、官方原文（English）

<!-- BEGIN UPSTREAM en -->
<!-- source: https://github.com/v2rayA/v2rayA/blob/main/README.md#data-and-upgrades | commit: 92caf05 | synced: 2026-11-09 -->

The SQLite database `v2raya.db` and the generated core config live in the configuration directory: `/etc/v2raya` on Linux and macOS, `%ProgramData%\SYSTEM\v2rayA` for the Windows service, the user's config directory with `--lite`, or the path given by `--config`. Logs go to `/var/log/v2raya/v2raya.log` under the systemd and OpenRC units, or to `--log-file` / `V2RAYA_LOG_FILE`. Network requests are made for subscription updates, rule-data downloads, latency probes, DNS, a release check against GitHub at start and weekly, and an NTP query (`ntp.aliyun.com`) when a VMess node fails, to tell a wrong clock from a bad node.

Stop the service and back up the configuration directory before upgrading. Upgrading from a release before 2.4 migrates the BoltDB database on the first start; the old file is kept as `bolt.db.bak` (`bolt.db.bak.1` and up when that name is taken), and accounts have to be registered again. Upgrade `v2raya` and `v2raya_core` together: the dashboard shows the core version, and a mismatch is reported in a banner.

<!-- END UPSTREAM en -->

---

## 三、落到 Docker 部署上：路径对照

官方说的是「配置目录」，裸机和容器里指向的位置不一样。下表是 Docker + `network_mode: host` 的对照（也是本仓库示例配置的部署方式）：

| 内容 | 裸机 systemd | 容器内 | 宿主机实际路径（示例） |
|---|---|---|---|
| 主配置 | `/etc/v2raya/config.json` | `/etc/v2raya/config.json` | `/vol1/1000/docker/v2raya/etc/config.json` |
| 数据库 | `/etc/v2raya/v2raya.db` | `/etc/v2raya/v2raya.db` | `/vol1/1000/docker/v2raya/etc/v2raya.db`（`-wal`/`-shm` 同目录） |
| 规则数据 | `/usr/share/v2raya/{geoip,geosite}.dat` | 同左 | `/vol1/1000/docker/v2raya/rules/` |
| 日志 | `/var/log/v2raya/v2raya.log` | `V2RAYA_LOG_FILE` 指定 | Docker `json-file`（`docker logs v2raya`） |

两条结论：

1. **`./etc` 必须挂出来**。不挂卷，删容器 = 账号、订阅、节点、规则全没。
2. **`./rules` 挂出来是双刃剑**：`geoip.dat` / `geosite.dat` 会一直用挂载里的旧文件，**不会随镜像更新**。要么定期手动换 `.dat`，要么干脆不挂、让镜像自带（代价是容器重建时才刷新）。

示例 compose（与本文路径一致，可直接改路径复用）：

```yaml
services:
  v2raya:
    image: mzz2017/v2raya:latest
    container_name: v2raya
    restart: unless-stopped
    network_mode: host          # 透明代理必需
    privileged: true            # 透明代理必需
    mem_limit: 512m
    cpus: "1.0"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - ./etc:/etc/v2raya           # 账号 / 订阅 / 节点 / 规则配置
      - ./rules:/usr/share/v2raya   # geosite/geoip 规则数据
```

---

## 四、升级流程

### 4.1 先看清楚现在是什么版本

```bash
# 面板显示的版本（仪表板左下角），或者：
docker exec v2raya v2raya --version
docker exec v2raya v2raya_core --version   # 两个号必须一致
```

界面上如果出现「内核版本与 v2raya 不一致」的横幅，就先修版本再谈升级 —— 混搭的两个版本行为不可预测。

### 4.2 标准升级（compose）

```bash
cd /vol1/1000/docker/v2raya

# 1) 停服务：让 SQLite 落盘，避免备份到写了一半的库
docker compose stop v2raya

# 2) 备份配置目录（脚本在 ./scripts/backup-v2raya.sh）
sudo ./scripts/backup-v2raya.sh -d ./etc -o ./backups --stopped

# 3) 拉新镜像并起来
docker compose pull v2raya
docker compose up -d v2raya

# 4) 验证（见 4.4）
docker compose logs --tail=50 v2raya
```

> 顺序很重要：**先停、再备份、后拉取**。反过来的话备份里是旧库、跑的是新程序，回滚时反而对不上。

### 4.3 关于 `latest`

`mzz2017/v2raya:latest` 省事，但每次 `pull` 都可能跨小版本。想稳一点就钉版本号，升级变成显式的动作：

```yaml
image: mzz2017/v2raya:2.5.14   # 升级时才改这一行
```

钉版本的好处：出问题一眼知道从哪个版本开始坏的；坏处：安全修复不会自动来。

### 4.4 升级后的验证清单

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2017          # 2017 面板，期望 200
ss -lntp | grep -E '2017|2017[0-3]|52345'                                # 端口在监听
docker exec v2raya v2raya --version                                      # 与 core 版本一致
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -m 8 https://www.baidu.com
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -m 20 https://github.com
curl -s -m 10 https://api.ipify.org; echo                                 # 出口应为节点 IP
```

再看面板：账号还能登、订阅能更新、节点列表在、核心 running、路由规则行数没变。

### 4.5 回滚

```bash
cd /vol1/1000/docker/v2raya
docker compose stop v2raya
sudo ./scripts/restore-v2raya.sh -a ./backups/v2raya-YYYYmmdd-HHMMSS.tar.gz -d ./etc --force
# 镜像也钉回旧 tag 再 up
docker compose up -d v2raya
```

---

## 五、备份与恢复

### 5.1 为什么不能只 `cp v2raya.db`

v2rayA 用的是 SQLite，且当前默认 **WAL 模式**，配置目录里会同时出现三个文件：

```
v2raya.db        40 KB     主库
v2raya.db-wal   290 KB     未合并的事务日志  ← 最新的改动常在这里
v2raya.db-shm    32 KB     共享内存索引
```

只拷 `v2raya.db` 会丢掉 `-wal` 里还没 checkpoint 的改动（订阅、规则、密码修改都可能在里面）。**要么三个一起拷，要么先停服务再拷。** 运行时热拷三个文件仍有撕裂风险，所以脚本默认「停 → 打包 → 起」。

### 5.2 用脚本（推荐）

```bash
# 容器部署（默认容器名 v2raya）
sudo ./scripts/backup-v2raya.sh -d /vol1/1000/docker/v2raya/etc -o /vol1/1000/docker/v2raya/backups

# 裸机 systemd 部署
sudo ./scripts/backup-v2raya.sh -d /etc/v2raya -o /root/v2raya-backups --no-docker

# 不停服热备份（接受撕裂风险，仅用于临时快照）
sudo ./scripts/backup-v2raya.sh -d /vol1/1000/docker/v2raya/etc -o ./backups --live
```

脚本产出：`v2raya-<时间戳>.tar.gz` + 同名 `.sha256`，打包前先停容器、打包后自动拉起，默认保留最近 10 份。
恢复见 `scripts/restore-v2raya.sh`（默认 dry-run，加 `--force` 才真正落盘，会把当前目录先备份一份）。

### 5.3 手工备份（不想用脚本时）

```bash
docker stop v2raya
sudo tar -czf ~/v2raya-$(date +%Y%m%d-%H%M).tar.gz -C /vol1/1000/docker/v2raya etc rules docker-compose.yml
docker start v2raya
sudo sha256sum ~/v2raya-*.tar.gz > ~/v2raya-$(date +%Y%m%d-%H%M).tar.gz.sha256
```

### 5.4 备份里有什么敏感内容

`v2raya.db` 包含**管理员账号密码哈希**、**全部订阅链接**（自带机场 token）、节点配置。等于把翻墙凭据打成一个包，所以：

- 备份文件权限 `600`，别放进同步盘、别提交进任何 Git 仓库
- 分享配置给别人前，先用面板的导出功能挑要给的节点，别直接发 db
- 这个仓库只放路由规则和 PAC，**永远不要放 `etc/`**

---

## 六、从 2.4 之前升级（BoltDB 迁移）

官方说明：从 2.4 以下的版本升级，**首次启动会把 BoltDB 数据库迁移成 SQLite**，旧文件保留为 `bolt.db.bak`（重名则为 `bolt.db.bak.1`、`.bak.2`……），**账户需要重新注册**。

实操建议：

1. 升级前把整个配置目录备份（`bolt.db` 也一起），迁移是单向的，失败只能靠备份回退
2. **先把订阅链接抄出来**（面板 → 订阅 → 复制 URL，或截图），账户要重新注册，但订阅和节点在库里，通常仍能恢复；链接在手才有兜底
3. 迁移完成后确认 `v2raya.db` 出现、`bolt.db.bak` 存在，再删旧文件
4. 重新注册管理员 → 检查订阅/节点/规则是否都在 → 启动核心验证

---

## 七、迁移到新机器 / 重建容器

按顺序做，别跳步：

1. 旧机：停服务 → 备份（4.2 / 5.2）
2. 新机：装同版本 `v2raya` + `v2raya_core`（或同 tag 镜像），先启动一次让目录结构生成
3. 新机：停服务 → 解包覆盖配置目录 → 确认权限 `root:root`
4. 起服务，检查：账号能登 → 订阅能更新 → 节点在 → 选节点启动核心 → 分流命中
5. 透明代理模式（`redirect`/`tproxy`/`tun`）要重新确认：网卡名、`ip_forward`、iptables/nftables 规则在各发行版差异很大，v2rayA 会自己装，但**路由/防火墙由别的软件管的时候会打架**
6. 端口对外开放的（2017 面板、20170-20173 入站）确认防火墙/安全组放行范围 —— 面板只该内网可达

---

## 八、常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 重建容器后账号/订阅全没 | `./etc` 没挂卷 | 挂卷后重新配置；有备份就恢复 |
| 升级了镜像但分流规则没变 | `geoip.dat`/`geosite.dat` 用的是挂载目录里的旧文件 | 手动换 `.dat`，或去掉 `rules` 挂载重建容器 |
| 备份恢复后少了几条规则 | 只拷了 `v2raya.db`，漏了 `-wal` | 三个文件一起拷，或停服后再拷 |
| 启动报数据库损坏 | 热拷了正在写的 db | 用备份脚本的「停 → 打包 → 起」模式 |
| 面板打不开但容器在跑 | 端口被别的服务占了，或 `--address` 只绑了 127.0.0.1 | `ss -lntp \| grep 2017`，检查启动参数 |
| VMess 节点全部失败 | 系统时钟偏差 | 上游会在 VMess 失败时查 `ntp.aliyun.com` 判断是时钟问题还是节点问题；先 `date` 核对 |
| 日志里一堆 `connection refused` | DNS 规则的上游指向了没监听的地址（比如 `localhost:53`） | 设置 → DNS，把该规则上游改成真实可达的 DNS |
| 容器权限不足 | 透明代理需要 `privileged` + `network_mode: host` | 桥接网络下只能当普通 HTTP/SOCKS 代理用，不能透明代理 |

---

## 九、上游同步是怎么做的

- `scripts/sync-upstream.py`：抓 `README_zh.md` / `README.md`，按标题抽出「数据与升级」/「Data and upgrades」整节，替换本页两个 `<!-- BEGIN UPSTREAM ... -->` 标记之间的内容，并在块内写一行来源（上游 commit、同步日期）
- `.github/workflows/sync-v2raya-docs.yml`：每周一 03:17 UTC 自动跑一次，也可以手动 `Run workflow`；**有变化才提交**，提交信息 `docs: 同步 v2rayA 官方「数据与升级」章节`
- 上游把这一节改名或删掉时，脚本会报错退出、工作流失败，GitHub 会发通知 —— 这比默默不同步要好
- 本地手动跑：

```bash
python3 scripts/sync-upstream.py          # 只改文档
python3 scripts/sync-upstream.py --check  # 只检查是否有差异（CI 用），有差异返回 1
```

同步范围只有这两节原文。第三到第八节是人工维护的部署经验，脚本不碰。
