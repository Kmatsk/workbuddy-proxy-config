// WorkBuddy PAC  —  默认走 NAS 代理，国内站点与内网直连
// 代理：192.168.3.100:20172 （v2rayA 已在 NAS 侧做二次分流：国外出口代理、国内出口家宽）
// 维护：改完本文件后，浏览器需重启或重新打开“自动配置脚本”开关才会刷新缓存。

var PX = "PROXY 192.168.3.100:20172; DIRECT";
var DR = "DIRECT";

// ---------- 需要强制走代理的域名（直连实测不通或不稳）----------
var FORCE_PROXY = [
  "github.com",           // 覆盖 api / gist / codeload / raw 等全部子域
  "githubusercontent.com",
  "githubassets.com",
  "githubapp.com",
  "github.dev",
  "github.io",
  "githubstatus.com"
];

// ---------- 国内域名：直连，避免绕路 ----------
var CN = [
  // 百度 / 搜索
  "baidu.com", "bdstatic.com", "bdimg.com", "bcebos.com", "sogou.com",
  "so.com", "360.cn", "360.com", "chinaso.com", "sm.cn",
  // 腾讯系
  "qq.com", "qpic.cn", "qlogo.cn", "gtimg.cn", "qqmail.com", "tencent.com",
  "tencentcloud.com", "myqcloud.com", "qcloud.com", "weixin.com", "wechat.com",
  "weixinbridge.com", "tenpay.com", "dnspod.cn",
  // 阿里系
  "alipay.com", "alipayobjects.com", "taobao.com", "tmall.com", "tmcdn.net",
  "alicdn.com", "aliyun.com", "aliyuncs.com", "alibaba.com", "1688.com",
  "dingtalk.com", "alidns.com", "taobao.net", "alimama.com",
  // 字节 / 抖音
  "douyin.com", "douyincdn.com", "bytedance.com", "byteimg.com", "bytecdn.cn",
  "toutiao.com", "ixigua.com", "feishu.cn", "feishu.net", "larkoffice.com",
  // 视频 / 音乐
  "bilibili.com", "hdslb.com", "bilivideo.com", "biliapi.net", "b23.tv",
  "iqiyi.com", "qiyipic.com", "youku.com", "tudou.com", "mgtv.com",
  "163.com", "126.net", "126.com", "127.net", "netease.com", "youdao.com",
  "kugou.com", "kuwo.cn", "xiami.com",
  // 社交 / 内容
  "weibo.com", "weibo.cn", "sina.com.cn", "sinaimg.cn", "sinaapp.com", "weibocdn.com",
  "zhihu.com", "zhimg.com", "douban.com", "doubanio.com", "hupu.com", "tieba.com",
  "csdn.net", "cnblogs.com", "gitee.com", "oschina.net", "juejin.cn",
  "segmentfault.com", "51cto.com", "infoq.cn",
  // 电商 / 生活
  "jd.com", "360buyimg.com", "jdcloud.com", "pinduoduo.com", "yangkeduo.com",
  "pddpic.com", "suning.com", "vip.com", "meituan.com", "meituan.net",
  "dianping.com", "ele.me", "ctrip.com", "qunar.com", "ly.com", "12306.cn",
  "amap.com", "autonavi.com", "58.com", "ke.com", "lianjia.com", "anjuke.com",
  "zhipin.com", "lagou.com", "zhaopin.com",
  // 手机 / 硬件
  "xiaomi.com", "mi.com", "miui.com", "xiaomi.net", "huawei.com", "hicloud.com",
  "huaweicloud.com", "honor.com", "oppo.com", "vivo.com", "meizu.com",
  // 办公 / 软件
  "wps.cn", "kdocs.cn", "wps.com", "jinritemai.com", "yuque.com",
  // 资讯 / 科技
  "36kr.com", "ithome.com", "cnbeta.com", "ifanr.com", "sspai.com",
  "mydrivers.com", "pconline.com.cn", "zol.com.cn", "chinaz.com", "runoob.com",
  // 政务 / 教育
  "gov.cn", "edu.cn", "edu.hk", "ac.cn",
  // 下载 / 工具
  "xunlei.com", "onlinedown.net", "crsky.com", "skycn.com"
];

// ---------- PAC 内置函数兜底（部分引擎不提供 endsWith）----------
function _endsWith(s, suf) {
  return s.length >= suf.length && s.substring(s.length - suf.length) === suf;
}

function _inList(host, list) {
  for (var i = 0; i < list.length; i++) {
    var d = list[i];
    if (host === d || _endsWith(host, "." + d)) return true;
  }
  return false;
}

function _isIP(host) {
  return /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host);
}

function FindProxyForURL(url, host) {
  if (!host) return DR;
  host = host.toLowerCase();

  // 本机 / 无点主机名
  if (host === "localhost" || host === "127.0.0.1" || host === "::1") return DR;

  // 纯 IP：内网直连，其余走代理
  if (_isIP(host)) {
    if (isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||
        isInNet(host, "127.0.0.0", "255.0.0.0") ||
        isInNet(host, "169.254.0.0", "255.255.0.0")) {
      return DR;
    }
    return PX;
  }

  if (_endsWith(host, ".local") || _endsWith(host, ".lan") || _endsWith(host, ".home")) return DR;
  if (host.indexOf(".") === -1) return DR;      // 无点主机名=内网短名

  // GitHub 全族强制代理
  if (_inList(host, FORCE_PROXY)) return PX;

  // 国内域名直连
  if (_inList(host, CN)) return DR;

  // 其余一律走代理
  return PX;
}
