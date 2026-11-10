#!/usr/bin/env python3
"""v2rayA 体检脚本 —— 纯标准库。

用法:
    python3 healthcheck-v2raya.py --host 192.168.3.100 --port 2017 \
        --user Kmatsk --password 'xxx'

退出码: 0 全部通过, 1 有失败项。
"""

import argparse
import json
import socket
import sys
import time
import urllib.parse
import urllib.request

PASS, FAIL, WARN = "PASS", "FAIL", "WARN"
results = []


def record(name, status, detail=""):
    results.append((name, status))
    mark = {PASS: "[ok]  ", FAIL: "[FAIL]", WARN: "[warn]"}[status]
    print(f"{mark} {name}" + (f"  — {detail}" if detail else ""))


class V2rayA:
    def __init__(self, host, port, timeout=15):
        self.base = f"http://{host}:{port}"
        self.timeout = timeout
        self.token = None

    def _req(self, path, payload=None):
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Content-Type": "application/json"} if data else {}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(self.base + path, data=data, headers=headers)
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode())

    def login(self, user, password):
        o = self._req("/api/login", {"username": user, "password": password})
        if o.get("code") != "SUCCESS":
            raise RuntimeError(o.get("message") or o.get("errorCode") or "登录失败")
        self.token = o["data"]["token"]
        return self

    def touch(self):
        return self._req("/api/touch")["data"]

    def ports(self):
        return self._req("/api/ports")["data"]

    def setting(self):
        return self._req("/api/setting")["data"]

    def routing_a(self):
        return self._req("/api/routingA")["data"]


def port_open(host, port, timeout=3):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        return True
    except Exception:
        return False
    finally:
        s.close()


def proxy_fetch(url, proxy_host, proxy_port, timeout=20):
    """通过 v2rayA 的 http 代理发起请求，返回 (状态码, 耗时秒) 或 (None, 错误)。"""
    proxy = f"http://{proxy_host}:{proxy_port}"
    handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy})
    opener = urllib.request.build_opener(handler)
    req = urllib.request.Request(url, headers={"User-Agent": "healthcheck/1.0"})
    t0 = time.time()
    try:
        with opener.open(req, timeout=timeout) as resp:
            resp.read(64)
            return resp.status, time.time() - t0
    except Exception as exc:
        return None, str(exc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.3.100")
    ap.add_argument("--port", type=int, default=2017)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--proxy-url", default="https://www.youtube.com")
    args = ap.parse_args()

    print(f"目标: {args.host}:{args.port}\n")

    if not port_open(args.host, args.port):
        record("面板端口", FAIL, f"{args.host}:{args.port} 不可达")
        return summarize()

    try:
        api = V2rayA(args.host, args.port).login(args.user, args.password)
        record("面板登录", PASS, "token 已获取")
    except Exception as exc:
        record("面板登录", FAIL, str(exc))
        return summarize()

    try:
        t = api.touch()
        record("核心运行", PASS if t.get("running") else FAIL,
               "running" if t.get("running") else "未运行")
        record("网络暂停", PASS if not t.get("networkPaused") else FAIL,
               "未暂停" if not t.get("networkPaused") else "已暂停")
        servers = (t.get("touch") or {}).get("servers") or []
        record("节点", PASS if servers else WARN, f"{len(servers)} 个")
        conn = (t.get("touch") or {}).get("connectedServer") or []
        if conn:
            sid = conn[0].get("id") if isinstance(conn[0], dict) else conn[0]
            name = next((s.get("name") for s in servers if s.get("id") == sid), sid)
            record("已连接节点", PASS, str(name))
        else:
            record("已连接节点", FAIL, "未选中任何节点")
    except Exception as exc:
        record("读取状态", FAIL, str(exc))

    try:
        p = api.ports()
        for k in ("socks5", "http", "socks5WithPac", "httpWithPac"):
            port = p.get(k)
            if port:
                ok = port_open(args.host, port)
                record(f"端口 {k}", PASS if ok else FAIL, f"{args.host}:{port}")
    except Exception as exc:
        record("读取端口", FAIL, str(exc))

    try:
        st = api.setting().get("setting") or {}
        record("透明代理", PASS if st.get("transparent") else WARN,
               f"{st.get('transparent')} / {st.get('transparentType')}")
        record("分流模式", PASS if st.get("pacMode") else WARN, str(st.get("pacMode")))
        record("DNS 劫持", PASS if st.get("dnsHijack") == "yes" else WARN,
               f"{st.get('dnsHijack')} @ {st.get('dnsListenAddr')}")
    except Exception as exc:
        record("读取设置", WARN, str(exc))

    try:
        ra = api.routing_a().get("routingA") or ""
        lines = [l for l in ra.splitlines() if l.strip() and not l.strip().startswith("#")]
        record("分流规则", PASS if len(lines) >= 3 else WARN, f"{len(lines)} 条有效规则")
    except Exception as exc:
        record("分流规则", WARN, str(exc))

    http_port = None
    try:
        http_port = api.ports().get("http")
    except Exception:
        pass
    if http_port:
        status, cost = proxy_fetch(args.proxy_url, args.host, http_port)
        if status:
            record("代理连通", PASS, f"{args.proxy_url} → HTTP {status}, {cost:.2f}s")
        else:
            record("代理连通", FAIL, f"{args.proxy_url} 失败: {cost}")
        status2, cost2 = proxy_fetch("https://www.google.com", args.host, http_port)
        if status2:
            record("Google 可达", PASS, f"HTTP {status2}, {cost2:.2f}s")
        else:
            record("Google 可达", FAIL, str(cost2))

    summarize()


def summarize():
    fails = [r for r in results if r[1] == FAIL]
    warns = [r for r in results if r[1] == WARN]
    oks = [r for r in results if r[1] == PASS]
    print(f"\n汇总: {len(oks)} 通过 / {len(warns)} 警告 / {len(fails)} 失败")
    if fails:
        print("失败项: " + ", ".join(r[0] for r in fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
