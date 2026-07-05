#!/system/bin/sh
# PicaComic 专用 logcat 读取脚本
# 用法:
#   ./log.sh              # 录到按 Ctrl+C 结束
#   ./log.sh 120          # 录 120 秒后自动结束
#   ./log.sh 0 com.github.pacalini.pica_comic   # 0 = 仅 Ctrl+C
#   LOG_DIR=/sdcard/Download ./log.sh

set -u

APP_PACKAGE="${2:-${APP_PACKAGE:-com.github.pacalini.pica_comic}}"
DURATION="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR="/data/data/com.termux/files/home/PicaComic"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR}"

mkdir -p "$LOG_DIR" 2>/dev/null || {
  echo "无法创建日志目录: $LOG_DIR"
  exit 1
}

if [ "$(id -u)" != "0" ]; then
  echo "提示: 未 root，部分机型 logcat --pid 可能失败，将退化为包名 grep"
fi

stamp="$(date +%Y%m%d_%H%M%S)"
if [ -n "$APP_PACKAGE" ]; then
  LOG_FILE="$LOG_DIR/logcat_${APP_PACKAGE}_${stamp}.log"
else
  LOG_FILE="$LOG_DIR/logcat_all_${stamp}.log"
fi

APP_PID=""
if [ -n "$APP_PACKAGE" ]; then
  APP_PID="$(pidof "$APP_PACKAGE" 2>/dev/null | awk '{print $1}')"
fi

LOGCAT_PID=""
DURATION_PID=""
ENDED=0

cleanup() {
  [ "$ENDED" -eq 1 ] && return
  ENDED=1
  echo ""
  echo "----------------------------------------"
  echo "正在结束记录 ($(date '+%H:%M:%S'))..."

  [ -n "${DURATION_PID:-}" ] && kill "$DURATION_PID" 2>/dev/null
  [ -n "${LOGCAT_PID:-}" ] && kill "$LOGCAT_PID" 2>/dev/null

  wait "$LOGCAT_PID" 2>/dev/null

  sleep 0.3
  kill -9 "$LOGCAT_PID" 2>/dev/null

  {
    echo ""
    echo "========== capture end $(date '+%Y-%m-%d %H:%M:%S') =========="
    if [ -f "$LOG_FILE" ]; then
      echo "lines: $(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')"
      echo "size: $(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ') bytes"
    fi
  } >> "$LOG_FILE" 2>/dev/null

  echo "日志已保存: $LOG_FILE"
  if [ -f "$LOG_FILE" ]; then
    du -h "$LOG_FILE" 2>/dev/null | awk '{print "大小: "$1}'
    wc -l < "$LOG_FILE" 2>/dev/null | awk '{print "行数: "$1}'
  fi
  exit 0
}

trap cleanup INT TERM

{
  echo "========== PicaComic log capture =========="
  echo "start: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "package: ${APP_PACKAGE:-<all>}"
  echo "pid: ${APP_PID:-<not running>}"
  echo "duration: ${DURATION:-until Ctrl+C}"
  echo "file: $LOG_FILE"
  echo "tags of interest: Flutter, Dart, PicaComic, WebView, chromium, cr_, AndroidRuntime"
  echo "----------------------------------------"
} > "$LOG_FILE"

echo "开始记录 → $LOG_FILE"
echo "包名: ${APP_PACKAGE:-全部}  PID: ${APP_PID:-未运行}"
if [ -n "$DURATION" ] && [ "$DURATION" -gt 0 ] 2>/dev/null; then
  echo "时长: ${DURATION}s（可随时 Ctrl+C 提前结束）"
else
  echo "时长: 直到 Ctrl+C"
fi
echo "----------------------------------------"

# logcat：WebView renderer 是独立进程，不能只按主进程 PID 过滤。
if [ -n "$APP_PACKAGE" ]; then
  logcat -v threadtime 2>&1 | grep -iE "$APP_PACKAGE|pica_comic|PicaComic|flutter|dart|WebView|InAppWebView|chromium|cr_|AndroidRuntime|RenderProcess|AwContents|libmonochrome" >> "$LOG_FILE" &
  LOGCAT_PID=$!
else
  logcat -v threadtime >> "$LOG_FILE" 2>&1 &
  LOGCAT_PID=$!
fi

# 定时结束（可选）
if [ -n "$DURATION" ] && [ "$DURATION" -gt 0 ] 2>/dev/null; then
  (
    sleep "$DURATION"
    kill -TERM $$ 2>/dev/null
  ) &
  DURATION_PID=$!
fi

# 等待 logcat；Ctrl+C 走 trap
wait "$LOGCAT_PID" 2>/dev/null
cleanup
