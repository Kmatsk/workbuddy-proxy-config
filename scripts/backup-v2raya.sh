#!/usr/bin/env bash
# ============================================================================
# v2rayA 配置备份
#
# 默认行为：停服务 -> 打包配置目录 -> 拉起服务 -> 校验 -> 清理旧备份
# 停服务是为了 SQLite 的 -wal / -shm 落盘，避免备份到写了一半的库。
#
# 用法:
#   sudo ./backup-v2raya.sh                          # Docker，备份 /etc/v2raya
#   sudo ./backup-v2raya.sh -d ./etc -o ./backups    # 指定目录
#   sudo ./backup-v2raya.sh -d /etc/v2raya --no-docker   # 裸机 systemd
#   sudo ./backup-v2raya.sh -d ./etc --live          # 不停服（有撕裂风险）
#   sudo ./backup-v2raya.sh -d ./etc -x ./rules -x docker-compose.yml
#
# 产出: v2raya-<时间戳>.tar.gz + .sha256，默认保留最近 10 份
# ============================================================================
set -euo pipefail

CONFIG_DIR="/etc/v2raya"
OUT_DIR="./v2raya-backups"
CONTAINER="v2raya"
KEEP=10
USE_DOCKER="auto"
STOP_MODE="stop"        # stop | live | already
EXTRAS=()
TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE=""

die() { echo "错误: $*" >&2; exit 1; }
info() { echo ">> $*"; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--config-dir) CONFIG_DIR="$2"; shift 2 ;;
    -o|--out)        OUT_DIR="$2"; shift 2 ;;
    -c|--container)  CONTAINER="$2"; shift 2 ;;
    -k|--keep)       KEEP="$2"; shift 2 ;;
    -x|--extra)      EXTRAS+=("$2"); shift 2 ;;
    --no-docker)     USE_DOCKER="no"; shift ;;
    --docker)        USE_DOCKER="yes"; shift ;;
    --live)          STOP_MODE="live"; shift ;;
    --stopped)       STOP_MODE="already"; shift ;;
    -h|--help)       usage ;;
    *) die "未知参数: $1（--help 看用法）" ;;
  esac
done

[ -d "$CONFIG_DIR" ] || die "配置目录不存在: $CONFIG_DIR"
CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"

# ---------- 选择服务管理方式 ----------
HAVE_DOCKER=0
if [ "$USE_DOCKER" != "no" ] && command -v docker >/dev/null 2>&1 \
   && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  HAVE_DOCKER=1
fi
if [ "$USE_DOCKER" = "yes" ] && [ "$HAVE_DOCKER" -eq 0 ]; then
  die "找不到容器 $CONTAINER"
fi

svc_running() {
  if [ "$HAVE_DOCKER" -eq 1 ]; then
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]
  else
    systemctl is-active --quiet v2raya 2>/dev/null
  fi
}

svc_stop() {
  if [ "$HAVE_DOCKER" -eq 1 ]; then docker stop "$CONTAINER" >/dev/null; else systemctl stop v2raya; fi
}

svc_start() {
  if [ "$HAVE_DOCKER" -eq 1 ]; then docker start "$CONTAINER" >/dev/null; else systemctl start v2raya; fi
}

# ---------- 停服务（可恢复） ----------
STARTED_BY_US=0
resume() {
  if [ "$STARTED_BY_US" -eq 1 ]; then
    info "重新拉起服务..."
    svc_start || echo "警告: 服务未能自动拉起，请手动 start" >&2
    STARTED_BY_US=0
  fi
}
trap resume EXIT

if [ "$STOP_MODE" = "stop" ]; then
  if svc_running; then
    info "停止服务（让 SQLite 落盘）..."
    svc_stop
    STARTED_BY_US=1
  else
    info "服务本来就没在跑，直接打包"
  fi
elif [ "$STOP_MODE" = "already" ]; then
  info "按已有停服状态打包"
else
  echo "警告: --live 热备份，数据库可能不一致（仅供临时快照）" >&2
fi

# ---------- 打包 ----------
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
ARCHIVE="$OUT_DIR/v2raya-$TS.tar.gz"

TMPD="$(mktemp -d)"
MANIFEST="$TMPD/BACKUP-MANIFEST.txt"
{
  echo "v2rayA backup"
  echo "created   : $(date -Is)"
  echo "host      : $(hostname)"
  echo "config_dir: $CONFIG_DIR"
  echo "container : $([ "$HAVE_DOCKER" -eq 1 ] && echo "$CONTAINER" || echo "-")"
  if command -v docker >/dev/null 2>&1 && [ "$HAVE_DOCKER" -eq 1 ]; then
    echo "image     : $(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo unknown)"
  fi
  echo "files     :"
  ( cd "$CONFIG_DIR" && find . -type f -printf '  %p (%s bytes)\n' 2>/dev/null | sort ) || true
} > "$MANIFEST"

TAR_ARGS=(-czf "$ARCHIVE" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")" -C "$TMPD" BACKUP-MANIFEST.txt)
for p in "${EXTRAS[@]:-}"; do
  [ -n "$p" ] || continue
  [ -e "$p" ] || { echo "警告: 附加路径不存在，跳过: $p" >&2; continue; }
  TAR_ARGS+=(-C "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")")
done

info "打包到 $ARCHIVE"
tar "${TAR_ARGS[@]}"

chmod 600 "$ARCHIVE"
( cd "$OUT_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
rm -rf "$TMPD"

# ---------- 校验 ----------
tar -tzf "$ARCHIVE" >/dev/null || die "备份包校验失败: $ARCHIVE"
SIZE="$(du -h "$ARCHIVE" | cut -f1)"
FILES="$(tar -tzf "$ARCHIVE" | grep -vc '/$' || true)"
info "完成: $ARCHIVE（$SIZE，$FILES 个文件）"

# ---------- 清理旧备份 ----------
if [ "$KEEP" -gt 0 ]; then
  mapfile -t OLD < <(ls -1t "$OUT_DIR"/v2raya-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) || true)
  for f in "${OLD[@]:-}"; do
    [ -n "$f" ] || continue
    info "删除旧备份: $(basename "$f")"
    rm -f "$f" "$f.sha256"
  done
fi

cat <<EOF

恢复方式:
  sudo ./restore-v2raya.sh -a "$ARCHIVE" -d "$CONFIG_DIR" --force

注意: 备份里含管理员密码哈希与全部订阅链接，权限已设为 600，别放进同步盘或 Git。
EOF
