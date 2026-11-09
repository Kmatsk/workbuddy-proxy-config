# AdGuard Home（NAS 侧 DNS 过滤）

在飞牛 NAS 上跑 AdGuard Home，接管全屋 DNS 过滤；上游交给 v2rayA 内核，所以境外域名照样拿到干净解析。

```
LAN 客户端 → 路由器(192.168.3.1) → PPPoE DNS 192.168.3.100:53
                                        ↓
                                  AdGuard Home（过滤）
                                        ↓ 上游 53（被 v2rayA 劫持到 127.0.0.1:52353）
                                  v2rayA 内核 DNS（按 RoutingA 分流：国内直连 / 国外走代理）
```

> 因为客户端问的是路由器、由路由器转发，AdGuard 查询日志里的「客户端」会显示成**宽带 WAN IP**（NAT 回环把源地址改写成了外网地址），不是设备的内网 IP。过滤照常生效，代价是分不清是哪台设备在查——按设备做规则（儿童保护、单设备放行）就用不了了。要恢复设备粒度，只能让 DHCP 直接下发 `192.168.3.100`。

## 部署

```bash
cd /vol1/1000/docker/AdGuard
mkdir -p work conf
docker compose up -d          # 首次启动后浏览器开 http://<NAS_IP>:3000 走初始化向导
```

`docker-compose.yml` 的关键点：**必须 `network_mode: host`**。桥接模式下 53 端口映射会被 v2rayA 的 DNS 劫持规则截走，AdGuard 收不到 LAN 查询。

DNS 监听地址只能填 **NAS 的 LAN IP**（`192.168.3.100`），不能填 `0.0.0.0`：v2rayA 内核已经占了 `127.2.0.17:53`，通配绑定会报 `bind: address already in use`。

> IP 是 DHCP 拿的。建议在路由器上给 NAS 做地址保留，否则 IP 一变，AdGuard 绑不上 53，全屋 DNS 立刻失效。

## 为什么需要 dns-exempt.sh

v2rayA 开启 DNS 劫持后会往 `nat PREROUTING` 写：

```
-A PREROUTING -p udp --dport 53 -j DNS_REDIRECT
-A PREROUTING -p tcp --dport 53 -j DNS_REDIRECT
```

`PREROUTING` 是「包进网卡就先匹配」，**目的地是本机的包也算**。所以 LAN 客户端查 `192.168.3.100:53` 会被重定向到核心的 52353，AdGuard 一个请求都收不到（现象就是 `nslookup xxx 192.168.3.100` 一直超时）。

第一版用 `iptables -t nat -I PREROUTING 1 ... -j RETURN` 放行，**重启一次 v2rayA 就失效** —— 它每次启动核心都用 `-I` 把劫持规则插到链首，把我们的规则顶到后面。

现在的做法是打标记，利用 v2rayA 自己链首那条 `-m mark --mark 0x80/0x80 -j RETURN`：

```bash
iptables -t mangle -A PREROUTING -d 192.168.3.100 -p udp --dport 53 -j MARK --set-xmark 0x80/0x80
iptables -t mangle -A PREROUTING -d 192.168.3.100 -p tcp --dport 53 -j MARK --set-xmark 0x80/0x80
```

`mangle PREROUTING` 先于 `nat PREROUTING` 执行，包被打上 0x80 后，v2rayA 的第一条规则就把它放行了；mangle 表在 redirect 模式下 v2rayA 不碰，重启核心也不会冲掉（实测重启两次规则仍在）。

开机自启：`/etc/systemd/system/adguard-dns-exempt.service`（oneshot，`After=docker.service`），执行 `/vol1/1000/docker/AdGuard/dns-exempt.sh`，脚本幂等。

只对「发往 NAS 自己 53」的包打标记。NAS 本机发出的 DNS（`dig`、容器里的解析）走 `OUTPUT` 链，仍然被 v2rayA 劫持 —— 这是**故意的**，本机查询不需要再过一遍 AdGuard，也避免了 AdGuard → 内核 → AdGuard 的环。

## 路由器怎么改

路由的 DHCP 参数改不了没关系，改 PPPoE 拨号里的 DNS 就行：路由器会把 LAN 的 DNS 请求转发给这两个地址。

| 项目 | 值 |
|---|---|
| 首选 DNS | `192.168.3.100` |
| 备用 DNS | `223.5.5.5` |

备用留公网 DNS 是保命用的：NAS 关机或 AdGuard 挂了，家里还能上网（只是没有广告过滤）。两个都填 NAS 的话，NAS 一停，全屋断网。

改完在 PC 上验证：

```bash
nslookup doubleclick.net 192.168.3.100   # 期望 Non-existent domain（被拦）
nslookup baidu.com 192.168.3.100         # 期望正常 IP
```

再断开重连 WiFi，看是否真的走了新 DNS：AdGuard 面板 → 查询日志里能看到本机请求。

> 期望值是 NXDOMAIN 而不是 `0.0.0.0`，原因见下面「拦截模式」一节。

## 拦截模式必须设成 NXDOMAIN

默认的 `blocking_mode: default` 返回 `0.0.0.0` / `::`。很多家用路由器开了 **DNS 重绑定保护（rebind protection）**，会把「解析结果落在 0.0.0.0 或私网段」的响应当成 DNS 劫持直接丢弃，然后 fallback 到备用 DNS 拿真实 IP。

现象很有迷惑性：**AdGuard 日志里明明写着 `FilteredBlackList`、耗时 0.15ms，客户端却拿到了真地址**，看起来像"规则没生效"。

改成 `nxdomain` 后返回标准的不存在响应，路由器不会丢弃，客户端也会立即放弃连接（比连 `0.0.0.0` 再超时还快一点）：

```bash
# 面板 → 设置 → DNS 设置 → 拦截模式 → NXDOMAIN
# 或者走 API（PUT 整份 dns_info，只改 blocking_mode 字段）
curl -b jar -X POST -H 'Content-Type: application/json' \
     --data-binary @dns_info.json http://192.168.3.100:3000/control/dns_config
```

## 路由器 DNS 缓存造成的「假漏拦」

改完 DNS 后最容易误判的一件事：`doubleclick.net` 还是返回 Google 的 IP，`cpro.baidu.com` 还是真实地址，于是以为规则没生效。

真实原因通常是**路由器的 DNS 缓存**。改 DNS 之前，这些域名已经被运营商的 DNS 解析过并被路由器缓存；只要缓存没过期，路由器就直接回答，**根本不会向上游（AdGuard）发问**。重启路由器能清一次，但设备一联网，这些域名很快又被重新缓存。

判断方法只有一个——**看 AdGuard 日志里有没有这条查询**：

| 日志里有这条查询 | 说明 | 怎么办 |
|---|---|---|
| 有，且 `reason=FilteredBlackList` | AdGuard 拦了，但路由器把响应换了 | 改 `blocking_mode` 为 `nxdomain` |
| 有，但 `reason=NotFiltered*` | 规则库没覆盖这个域名 | 加用户规则 `\|\|域名^` |
| **完全没有** | 路由器用缓存回答了，查询没到 AdGuard | 等缓存过期 / 清路由器缓存 |

验证链路是否真的通，用一个**家里设备从没访问过的域名**最准（比如现编一个 `probe-12345.example.org`），它能进日志就说明转发正常。用热门域名测只会被缓存误导。

## 抖音广告：能拦什么、拦不了什么

**拦不了信息流里的视频广告。** 那些广告和正常视频同域名、同 CDN（`douyinvod.com` / `douyinpic.com`），DNS 只看域名，分不出这条是广告还是正片；拦了就是白屏卡顿。

`douyin-ads.txt` 拦的是另一类东西，效果因版本而异：

- 穿山甲 / 巨量引擎（字节的广告 SDK 与投放后台）—— 主要减少**其它 App** 里嵌的字节广告
- 广告监测与归因（admaster、miaozhen、广点通）
- 统计上报（友盟）

文件里另有一组默认注释掉的「激进档」（`mon.snssdk.com`、`log.snssdk.com`、`mcs.snssdk.com`），去掉行首的 `!` 才会生效，代价写在注释里：推荐变差、消息/直播可能异常。

### 想自己找抖音的广告域名

1. 手机连家里 WiFi，打开抖音刷 1 分钟
2. AdGuard 面板 → 查询日志，按客户端 IP 过滤，看「已拦截」和请求量最高的域名
3. 可疑域名先在「用户规则」里临时加 `||xxx.com^` 试，**改完清一次 App 缓存**（抖音会缓存接口结果）
4. 视频加载不出来就立刻 `@@||xxx.com^` 放行

DNS 层能做到的就是这些。要真正去掉信息流广告，只能改客户端（去广告版 / LSPosed 模块），或者在路由器做 SNI 拦截（会误杀正常视频，不推荐）。

## 过滤规则构成

总共约 92 万条（去重前），内存占用 199MB、CPU 0.03%（x86 NAS）。更新间隔 12 小时。

| 规则 | 条数 | 覆盖 |
|---|---|---|
| HaGeZi's Pro Blocklist | 224287 | 国际广告/追踪主力，误拦控制比 Ultimate 好 |
| CHN: AdRules DNS List | 208313 | 国内广告，与 anti-AD 互补 |
| AdGuard DNS filter | 188167 | 全球通用底座 |
| Phishing Army | 143998 | 钓鱼站点 |
| anti-AD（中文广告） | 102508 | 国内最全，广告 + 追踪 + 部分 App 接口 |
| ShadowWhisperer's Malware | 47760 | 恶意软件分发域名 |
| Malicious URL Blocklist (URLHaus) | 1930 | 活跃恶意 URL（更新快） |
| AWAvenue Ads Rule | 913 | 国内移动端开屏/信息流广告 |
| HaGeZi Xiaomi / OPPO / Vivo / Huawei Tracker | 349/489/243/135 | 国内手机厂商遥测与画像 |
| 本仓库：抖音保守档 | 12 | 穿山甲、巨量、广告监测 |
| 本仓库：国内 App 补充包 | 41 | 百度联盟、快手广告位、B站/爱奇艺/优酷广告接口、归因 SDK |

刻意没加 `HaGeZi Ultimate`、`1Hosts (Xtra)`、`OISD Big`：它们和 Pro 高度重叠，叠加只会增加误拦率和内存，收益很小。

### DNS 侧的几个调优项

| 参数 | 值 | 原因 |
|---|---|---|
| `blocking_mode` | `nxdomain` | 绕开路由器 rebind protection，见上文 |
| `upstream_mode` | `parallel` | 两个上游并行，任一慢不拖累整体 |
| `cache_optimistic` | `true` | 缓存过期也先返回，后台刷新，减少等待 |
| `cache_size` | 8 MB | 家庭规模足够，命中率显著高于默认 4MB |
| `resolve_clients` | `false` | 客户端都是同一个 WAN IP，反查 PTR 纯属浪费且拖慢响应 |
| `use_private_ptr_resolvers` | `false` | 内网没有 PTR 记录，关掉避免无谓查询 |
| `bootstrap_dns` | `223.5.5.5` | 原来混进了 `192.168.3.1`，会形成 AdGuard↔路由器 的查询环，已去掉 |

上游保持 `223.5.5.5` + `119.29.29.29`：这两个查询会被 v2rayA 的 `OUTPUT` 链劫持进内核 DNS，由 RoutingA 决定直连还是走代理，所以**不需要**在 AdGuard 里配国内外分流——分流的活已经由 v2rayA 干了。v2rayA 挂掉时它们还能直连出去兜底。

## 运维

```bash
# 状态
docker ps --filter name=adguardhome
ss -lnup | grep ':53 '

# 配置在哪
/vol1/1000/docker/AdGuard/conf/AdGuardHome.yaml   # 全部设置（含密码哈希）
/vol1/1000/docker/AdGuard/work/                   # 查询日志、统计库

# 改了 dns-exempt.sh 之后
sudo systemctl restart adguard-dns-exempt.service

# 备份（含密码哈希与过滤规则，注意权限）
sudo tar -czf ~/adguard-$(date +%F).tar.gz -C /vol1/1000/docker AdGuard
```

查询日志保留期在面板「设置 → 常规设置」里调，API 改会报 `unsupported interval`（`/control/querylog_config` 的字段校验比较挑），UI 改最省事。

## 实测记录（2026-11-10，飞牛 NAS / x86_64）

部署当天：

- AdGuard Home v0.107.80，`network_mode: host`，DNS 绑 `192.168.3.100:53`，面板 `:3000`
- 拦截生效：`pangle.io`、`doubleclick.net`、`admaster.com.cn`、`gdt.qq.com`、`umeng.com` → 被拦
- 未误伤：`v3-web.douyinvod.com`、`p3-sign.douyinpic.com`、`api.amemv.com` 正常返回 CDN IP
- 防污染：经 AdGuard 查 `www.google.com` 得到 `2001:4860:482a:7700::`；路由器直连得到 `2001::1`（污染）
- 劫持确认：客户端查询后 `iptables -t nat -L OUTPUT -n -v` 的 `udp dpt:53` 计数递增，说明 AdGuard 的上游确实进了内核
- 规则存活：v2rayA 连续重启 2 次，mangle 里的两条 MARK 规则仍在，LAN 解析未中断
- 代理未受影响：`curl -x 192.168.3.100:20172 https://github.com` → 200，baidu 正常

路由器改 DNS 后二次优化：

- 拦截模式 `default` → `nxdomain` 后，被路由器丢弃响应导致的漏拦消失
- 规则扩到 13 组、约 92 万条；内存 104MB → 199MB，CPU 0.03%
- 误拦专项检查全部通过：`baidu.com`、`www.qq.com`、`weixin.qq.com`、`taobao.com`、`jd.com`、`bilibili.com`、`douyin.com`、`kuaishou.com`、`iqiyi.com`、`v.qq.com`、`wx.qq.com`、`long.weixin.qq.com`、`github.com`、`upos-sz-mirrorcos.bilivideo.com` 均返回真实 IP
- 拦截专项检查 11/11 命中：`doubleclick.net`、`cpro.baidu.com`、`pos.baidu.com`、`admaster.com.cn`、`pagead2.googlesyndication.com`、`pangle.io`、`pangolin-sdk-toutiao.com`、`gdt.qq.com`、`umeng.com`、`tracking.miaozhen.com`、`ads.kuaishou.com`
- 补充包命中且主站无损：`ad/ads.kuaishou.com`、`cm/data.bilibili.com`、`afp.iqiyi.com`、`atm.youku.com`、`eclick.baidu.com` 被拦；`www.kuaishou.com`、`www.bilibili.com`、`www.iqiyi.com`、`www.youku.com` 正常
- 容器重建（改 compose 加 `expose`）后 mangle 两条规则仍在，53/3000 均正常

## 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `nslookup 192.168.3.100` 超时 | 豁免规则没生效，查询被 v2rayA 劫走 | `iptables -t mangle -S PREROUTING \| grep 192.168.3.100`，没有就跑 `dns-exempt.sh` |
| 容器起不来，日志报 `bind: address already in use` | DNS 监听填了 `0.0.0.0` | 改成 NAS 的 LAN IP |
| 重启 v2rayA 后 DNS 全挂 | 用了 nat 表 RETURN 的旧方案 | 换 `dns-exempt.sh`（mangle 打标记版） |
| 换了 NAS 的 IP 后全屋断网 | AdGuard 绑的还是旧 IP | 改 `AdGuardHome.yaml` 的 `bind_hosts`，或给 NAS 做 DHCP 保留 |
| 全屋断网但 NAS 能上 | 路由器 DNS 指向 NAS，而 AdGuard/豁免规则挂了 | 先把 PPPoE 备用 DNS 设成 `223.5.5.5`，再修 |
| 日志写着已拦截，客户端却拿到真 IP | `blocking_mode=default` 返回 `0.0.0.0`，被路由器 rebind protection 丢弃后 fallback | 改成 `nxdomain` |
| 改完 DNS，热门域名仍不生效 | 路由器缓存了改之前的解析结果，查询没到 AdGuard | 查日志确认无该查询后，清缓存或等 TTL 过期 |
| 面板里客户端全是同一个公网 IP | 路由器转发时做了 NAT 回环 | 正常现象，过滤不受影响，只是分不清设备 |
