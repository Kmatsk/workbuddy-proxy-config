#!/usr/bin/env python3
"""同步 v2rayA 官方 README 的「数据与升级 / Data and upgrades」章节。

只替换 docs/v2raya-data-and-upgrades.md 里两条标记之间的内容，其余章节为人工维护。
不依赖第三方库，GitHub Actions 和本地都能直接跑。

用法:
    python3 scripts/sync-upstream.py            # 抓取并写入文档
    python3 scripts/sync-upstream.py --check    # 只检查是否有差异，有差异退出码 1
    python3 scripts/sync-upstream.py --dry-run  # 打印将写入的内容，不落盘
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC_PATH = os.path.join(REPO_ROOT, "docs", "v2raya-data-and-upgrades.md")

UPSTREAM_REPO = "v2rayA/v2rayA"
UPSTREAM_BRANCH = "main"
UA = "workbuddy-proxy-config-docs-sync/1.0 (+https://github.com/Kmatsk/workbuddy-proxy-config)"

# lang -> (README 文件名, 章节标题)
SECTIONS = {
    "zh": ("README_zh.md", "## 数据与升级"),
    "en": ("README.md", "## Data and upgrades"),
}

# lang -> 页内锚点（写进来源注释，方便点回上游原文）
ANCHORS = {"zh": "数据与升级", "en": "data-and-upgrades"}

RAW_URL = "https://raw.githubusercontent.com/{repo}/{branch}/{name}"
BLOB_URL = "https://github.com/{repo}/blob/{branch}/{name}"


def http_get(url: str, timeout: int = 30, retries: int = 3) -> bytes:
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
            last = exc
            print(f"  ! 第 {attempt} 次请求失败: {url} -> {exc}", file=sys.stderr)
    raise RuntimeError(f"请求失败: {url} ({last})")


def upstream_commit() -> str:
    """取 HEAD commit 短号；失败返回 unknown（不影响同步本身）。"""
    url = f"https://api.github.com/repos/{UPSTREAM_REPO}/commits?per_page=1"
    try:
        data = json.loads(http_get(url, timeout=15, retries=1))
        return str(data[0]["sha"])[:7]
    except Exception as exc:  # noqa: BLE001 - 拿不到 commit 不该让同步失败
        print(f"  ! 取上游 commit 失败（忽略）: {exc}", file=sys.stderr)
        return "unknown"


def extract_section(markdown: str, heading: str) -> str:
    """从 README 中抽出 heading 到下一个二级标题之间的正文（不含标题行）。"""
    lines = markdown.splitlines()
    body: list[str] = []
    inside = False
    for line in lines:
        if not inside:
            if line.strip() == heading:
                inside = True
            continue
        if line.startswith("## "):
            break
        body.append(line)
    if not inside:
        raise RuntimeError(f"上游 README 里找不到章节: {heading!r}（可能被改名或删除）")
    while body and not body[-1].strip():
        body.pop()
    while body and not body[0].strip():
        body.pop(0)
    if not body:
        raise RuntimeError(f"章节 {heading!r} 内容为空")
    return "\n".join(body)


def markers(lang: str) -> tuple[str, str]:
    return f"<!-- BEGIN UPSTREAM {lang} -->", f"<!-- END UPSTREAM {lang} -->"


def current_block(doc: str, lang: str) -> str:
    begin, end = markers(lang)
    start = doc.find(begin)
    stop = doc.find(end)
    if start == -1 or stop == -1 or stop < start:
        raise RuntimeError(f"文档里缺少 {lang} 的同步标记，请检查 docs/v2raya-data-and-upgrades.md")
    inner = doc[start + len(begin) : stop]
    lines = [ln for ln in inner.strip("\n").splitlines() if not ln.startswith("<!-- source:")]
    while lines and not lines[-1].strip():
        lines.pop()
    while lines and not lines[0].strip():
        lines.pop(0)
    return "\n".join(lines)


def render_block(lang: str, body: str, commit: str, today: str) -> str:
    begin, end = markers(lang)
    name = SECTIONS[lang][0]
    anchor = ANCHORS[lang]
    source = BLOB_URL.format(repo=UPSTREAM_REPO, branch=UPSTREAM_BRANCH, name=name) + "#" + anchor
    return "\n".join(
        [
            begin,
            f"<!-- source: {source} | commit: {commit} | synced: {today} -->",
            "",
            body,
            "",
            end,
        ]
    )


def replace_block(doc: str, lang: str, rendered: str) -> str:
    begin, end = markers(lang)
    start = doc.find(begin)
    stop = doc.find(end)
    if start == -1 or stop == -1 or stop < start:
        raise RuntimeError(f"文档里缺少 {lang} 的同步标记")
    return doc[:start] + rendered + doc[stop + len(end) :]


def main() -> int:
    parser = argparse.ArgumentParser(description="同步 v2rayA 官方「数据与升级」章节")
    parser.add_argument("--check", action="store_true", help="仅检查是否有差异，有差异退出码 1")
    parser.add_argument("--dry-run", action="store_true", help="打印结果，不写文件")
    args = parser.parse_args()

    if not os.path.exists(DOC_PATH):
        print(f"找不到文档: {DOC_PATH}", file=sys.stderr)
        return 2

    with open(DOC_PATH, encoding="utf-8") as fh:
        doc = fh.read()

    commit = upstream_commit()
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")

    changed = []
    new_doc = doc
    for lang, (name, heading) in SECTIONS.items():
        url = RAW_URL.format(repo=UPSTREAM_REPO, branch=UPSTREAM_BRANCH, name=name)
        print(f"[{lang}] 抓取 {url}")
        markdown = http_get(url).decode("utf-8")
        body = extract_section(markdown, heading)
        if current_block(new_doc, lang).strip() == body.strip():
            print(f"[{lang}] 无变化（{len(body.splitlines())} 行）")
            continue
        changed.append(lang)
        new_doc = replace_block(new_doc, lang, render_block(lang, body, commit, today))
        print(f"[{lang}] 有变化，准备更新（{len(body.splitlines())} 行）")

    if not changed:
        print("文档已是最新。")
        return 0

    print(f"需要更新的章节: {', '.join(changed)}（上游 commit {commit}）")
    if args.dry_run:
        print("--- dry-run，未写入 ---")
        return 0
    if args.check:
        print("--- check 模式，存在差异，退出码 1 ---")
        return 1

    with open(DOC_PATH, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(new_doc)
    print(f"已写入 {os.path.relpath(DOC_PATH, REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"同步失败: {exc}", file=sys.stderr)
        sys.exit(3)
