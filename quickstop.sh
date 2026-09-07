#!/usr/bin/env bash
# 停止 quickstart.sh 拉起的全部演示进程（backend / agent / admin）。
set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
DEMO="$BASE/demo"

command -v openresty >/dev/null 2>&1 \
  || { echo "[x] 未找到 openresty"; exit 1; }

for d in backend agent admin; do
  dir="$DEMO/$d"
  if [ -f "$dir/logs/nginx.pid" ]; then
    if openresty -p "$dir" -c conf/nginx.conf -s stop 2>/dev/null; then
      echo "[+] stopped: $dir"
    else
      echo "[!] $dir 停止失败（可能进程已不在），忽略"
    fi
  fi
done
echo "提示: demo/ 目录保留以便查看日志；再次执行 ./quickstart.sh 会自动重建。"
