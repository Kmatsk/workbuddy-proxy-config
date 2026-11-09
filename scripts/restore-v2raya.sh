#!/usr/bin/env bash
# ============================================================================
# v2rayA 配置恢复
#
# 默认是 dry-run：只列出将要做什么，不碰任何文件。加 --force 才真正执行。
# 执行顺序：校验包 -> 停服务 -> 现有配置改名留底 -> 解包覆盖 -> 拉起 -> 检查面板
#
# 用法:
#   sudo ./restore-v2raya.sh -a ./v2raya-20261110-010203.tar.gz -d /etc/v2raya
#   sudo ./restore-v2raya.sh -a <包> -d ./etc --force
#   sudo ./restore-v2raya.sh -a <包> -d /etc/v2raya --no-docker --force
#
# 说明: 包里除配置目录外的条目（如 ./rules、docker-compose.yml）会解到配置目录的
#       上一级，也就是原来打包时它们所在的位置。
# ============================================================================
set -euo pipefail

ARCHIVE=""
CONFIG_DIR="/etc/v2raya"
CONTAINER="v2raya"
USE_DOCKER="auto"
FORCE=0
SKIP_SUM=0
TS="$(date +%Y%m%d-%H%M%S)"

die() { echo "错误: $*" >&2; exit 1; }
info() { echo ">> $*"; }
warn() { echo "警告: $*" >&2; }

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--archive)    ARCHIVE="$2"; shift 2 ;;
    -d|--config-dir) CONFIG_DIR="$2"; shift 2 ;;
    -c|--container)  CONTAINER="$2"; shift 2 ;;
    --no-docker)     USE_DOCKER="no"; shift ;;
    --force)         FORCE=1; shift ;;
    --skip-checksum) SKIP_SUM=1; shift ;;
    -h|--help)       usage ;;
    *) die "未知参数: $1（--help 看用法）" ;;
  esac
done

[ -n "$ARCHIVE" ] || die "必须用 -a 指定备份包"
[ -f "$ARCHIVE" ] || die "备份包不存在: $ARCHIVE"
tar -tzf "$ARCHIVE" >/dev/null 2>&1 || die "不是有效的 tar.gz: $ARCHIVE"

# ---------- 校验和 ----------
if [ "$SKIP_SUM" -eq 0 ] && [ -f "$ARCHIVE.sha256" ]; then
  if ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" >/dev/null 2>&1 ); then
    info "校验和通过"
  else
    die "校验和不匹配，包可能损坏（确认无误可加 --skip-checksum）"
  fi
fi

# ---------- 包内容 ----------
TOP="$(tar -tzf "$ARCHIVE" | awk -F/ '{print $1}' | sort -u | grep -v '^$' || true)"
BASE="$(basename "$CONFIG_DIR")"
[ -n "$TOP" ] || die "包是空的"

if echo "$TOP" | grep -qx "$BASE"; then
  SRC="$BASE"
else
  # 目标目录改了名（换机迁移常见）：按内容认出配置目录——含 config.json 或 v2raya.db 的那一层
  SRC="$(tar -tzf "$ARCHIVE" \
        | awk -F/ 'NF>=2 && ($2=="config.json" || $2=="v2raya.db") {print $1}' \
        | sort -u || true)"
  if [ "$(printf '%s\n' "$SRC" | grep -c . || true)" -ne 1 ]; then
    die "包里认不出唯一的配置目录（顶层: $(echo $TOP)），请用 -d 指向与打包时同名的目录"
  fi
  warn "包里配置目录名为 $SRC，将按配置目录恢复到 $CONFIG_DIR"
fi
EXTRAS="$(echo "$TOP" | grep -vx "$SRC" | grep -vx 'BACKUP-MANIFEST.txt' || true)"

echo
echo "==== 恢复计划 ===="
echo "  备份包   : $ARCHIVE"
echo "  配置目录 : $CONFIG_DIR"
echo "  服务     : $([ "$USE_DOCKER" = "no" ] && echo "systemd (v2raya)" || echo "docker ($CONTAINER)")"
[ -n "$EXTRAS" ] && { echo "  额外条目 :"; echo "$EXTRAS" | sed 's/^/     /'; }
echo "  现有配置 : 改名为 ${CONFIG_DIR}.bak-$TS（不删除）"
echo
tar -xzOf "$ARCHIVE" BACKUP-MANIFEST.txt 2>/dev/null | sed 's/^/  | /' || warn "包里没有 MANIFEST"

if [ "$FORCE" -ne 1 ]; then
  echo
  echo "这是 dry-run，未改动任何文件。确认无误后加 --force 执行。"
  exit 0
fi

# ---------- 停服务 ----------
HAVE_DOCKER=0
if [ "$USE_DOCKER" != "no" ] && command -v docker >/dev/null 2>&1 \
   && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  HAVE_DOCKER=1
fi
stop_svc() { if [ "$HAVE_DOCKER" -eq 1 ]; then docker stop "$CONTAINER" >/dev/null; else systemctl stop v2raya; fi; }
start_svc() { if [ "$HAVE_DOCKER" -eq 1 ]; then docker start "$CONTAINER" >/dev/null; else systemctl start v2raya; fi; }

info "停止服务..."
stop_svc || warn "停止服务失败（可能本来就没跑）"

# ---------- 留底 + 解包 ----------
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
info "解包到临时目录..."
tar -xzf "$ARCHIVE" -C "$TMPD"

if [ -d "$CONFIG_DIR" ]; then
  info "现有配置改名为 ${CONFIG_DIR}.bak-$TS"
  mv "$CONFIG_DIR" "${CONFIG_DIR}.bak-$TS"
fi
mkdir -p "$CONFIG_DIR"
if [ -d "$TMPD/$SRC" ]; then
  cp -a "$TMPD/$SRC/." "$CONFIG_DIR/"
  info "已覆盖 $CONFIG_DIR（$(find "$CONFIG_DIR" -type f | wc -l) 个文件）"
else
  die "包结构异常：找不到目录 $SRC，未做任何修改"
fi

for e in $EXTRAS; do
  if [ -e "$TMPD/$e" ]; then
    info "恢复额外条目 $e -> $(dirname "$CONFIG_DIR")/"
    cp -a "$TMPD/$e" "$(dirname "$CONFIG_DIR")/"
  fi
done

if [ "$(id -u)" -eq 0 ]; then
  chown -R root:root "$CONFIG_DIR" 2>/dev/null || true
fi

# ---------- 拉起 + 检查 ----------
info "启动服务..."
start_svc || die "启动失败，看日志：$([ "$HAVE_DOCKER" -eq 1 ] && echo "docker logs $CONTAINER" || echo "journalctl -u v2raya -n 50")"

for i in $(seq 1 30); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:2017 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    info "面板已就绪（http://127.0.0.1:2017 返回 200）"
    break
  fi
  [ "$i" -eq 30 ] && warn "30 秒内面板未返回 200（当前 $code），请手动检查"
  sleep 1
done

cat <<EOF

恢复完成。请到面板确认：账号能登 -> 订阅能更新 -> 节点在 -> 启动核心。
回滚到恢复前状态:
  $( [ "$HAVE_DOCKER" -eq 1 ] && echo "docker stop $CONTAINER" || echo "systemctl stop v2raya" )
  sudo mv "$CONFIG_DIR" "${CONFIG_DIR}.restore-failed-$TS"
  sudo mv "${CONFIG_DIR}.bak-$TS" "$CONFIG_DIR"
  $( [ "$HAVE_DOCKER" -eq 1 ] && echo "docker start $CONTAINER" || echo "systemctl start v2raya" )
EOF
