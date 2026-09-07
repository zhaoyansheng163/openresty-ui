#!/usr/bin/env bash
# openresty-ui 一键体验：在本机拉起「2 个演示后端 + 1 个 agent + 1 个 admin」，
# 并自动完成后端节点与实例的注册，1 分钟即可体验动态 upstream 全流程。
# 仅用于快速体验；正式部署见 README.md「正式部署」。
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
DEMO="$BASE/demo"
TOKEN="dyn-ups-inner-token"   # 与 agent/conf/nginx.conf 中 $inner_token 默认值一致

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v openresty >/dev/null 2>&1 \
  || die "未找到 openresty，请先安装: https://openresty.org/cn/installation.html"
command -v curl >/dev/null 2>&1 || die "未找到 curl"

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

for p in 8080 8081 8088 9001 9002; do
  port_in_use "$p" && die "端口 $p 已被占用（若是上次演示残留，请先执行 ./quickstop.sh）"
done

# ---------- 1. 准备目录：演示后端 + agent/admin 副本 ----------
rm -rf "$DEMO"
mkdir -p "$DEMO/backend/conf" "$DEMO/backend/logs"
cp -r "$BASE/agent" "$DEMO/agent"
cp -r "$BASE/admin" "$DEMO/admin"
mkdir -p "$DEMO/agent/logs" "$DEMO/admin/logs"

cat > "$DEMO/backend/conf/nginx.conf" <<'EOF'
worker_processes  1;
error_log  logs/error.log  warn;
pid        logs/nginx.pid;
events { worker_connections  256; }
http {
    default_type  text/plain;
    access_log    off;
    server { listen 9001; return 200 "demo-backend-1\n"; }
    server { listen 9002; return 200 "demo-backend-2\n"; }
}
EOF

# 演示环境用随机密码的管理员账号（源码目录 admin/conf/users.json 不受影响）
ADMIN_PASS="$(head -c 32 /dev/urandom | sha1sum | cut -c1-10)"
cat > "$DEMO/admin/conf/users.json" <<EOF
{
  "admin": { "password": "$ADMIN_PASS", "role": "admin" }
}
EOF

# ---------- 2. 启动 ----------
start_one() {
  openresty -p "$1" -c conf/nginx.conf || die "$1 启动失败，请查看 $1/logs/error.log"
}
log "启动演示后端 (127.0.0.1:9001 / 9002) ..."
start_one "$DEMO/backend"
log "启动 agent (业务口 8080 / 管理口 8081) ..."
start_one "$DEMO/agent"
log "启动 admin 管理台 (8088) ..."
start_one "$DEMO/admin"

wait_http() {
  for _ in $(seq 1 20); do
    curl -s -m 1 -o /dev/null "$1" && return 0
    sleep 0.3
  done
  return 1
}
wait_http "http://127.0.0.1:8081/" || die "agent 管理口未就绪，请查看 $DEMO/agent/logs/error.log"
wait_http "http://127.0.0.1:8088/" || die "admin 未就绪，请查看 $DEMO/admin/logs/error.log"

# ---------- 3. 自动注册 ----------
reg_node() { # port
  curl -s -m 5 -X POST "http://127.0.0.1:8081/nginx_inner/upstream/add_server" \
    -H "Content-Type: application/json" -H "X-Auth-Token: $TOKEN" \
    -d "{\"upstream\":\"backend\",\"host\":\"127.0.0.1\",\"port\":$1,\"weight\":1}" \
    | grep -q '"OK"' || die "注册演示后端 127.0.0.1:$1 失败"
}
reg_node 9001
reg_node 9002
log "已将 2 个演示后端注册到 agent 的 upstream [backend]"

# 注册实例需要管理员会话，先登录拿 cookie
COOKIE="$DEMO/.admin_cookie"
curl -s -m 5 -c "$COOKIE" -X POST "http://127.0.0.1:8088/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" \
  | grep -q '"OK"' || die "登录 admin 失败，请查看 $DEMO/admin/logs/error.log"

curl -s -m 5 -b "$COOKIE" -X POST "http://127.0.0.1:8088/api/instances" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"local-agent\",\"host\":\"127.0.0.1\",\"port\":8081,\"token\":\"$TOKEN\"}" \
  | grep -q '"OK"' || die "向 admin 注册实例失败"
log "已将实例 local-agent 注册到 admin 管理台"

# ---------- 4. 体验指引 ----------
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$LAN_IP" ] || LAN_IP="127.0.0.1"

echo
echo "==================== 部署完成 ===================="
echo "  管理台界面 : http://$LAN_IP:8088/   (实例: local-agent)"
echo "  登录账号   : admin  密码: $ADMIN_PASS"
echo "  业务入口   : http://$LAN_IP:8080/   (upstream: backend)"
echo "  演示后端   : 127.0.0.1:9001 / 9002"
echo "=================================================="
echo
log "负载均衡验证（连续请求，可见两个后端交替返回）:"
for _ in 1 2 3 4; do printf '  curl 8080 => '; curl -s "http://127.0.0.1:8080/"; done
echo
log "接着到管理台试试：选中 local-agent -> 对 demo-backend-1 点「摘流」，"
log "再重复上面的 curl，流量将全部落到 demo-backend-2；点「恢复」即回到双节点。"
echo
echo "停止演示: ./quickstop.sh     查看日志: demo/*/logs/error.log"
