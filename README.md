# openresty-ui

**OpenResty 动态 Upstream 管理平台** —— 在网页上给 OpenResty 加减后端节点、改权重、摘流，全部 **0 reload 实时生效**。

纯 OpenResty 实现，**不依赖 etcd / Consul / Redis / 数据库**，不需要安装任何额外的 Lua 库；管理台是一个单文件网页，不需要 Node.js 构建。整个项目只包含两个目录：`admin`（管理台）和 `agent`（被管理的 OpenResty 实例）。

## 功能特性

- **动态 Upstream 管理**：添加 / 编辑 / 删除后端节点，调整权重，手动摘流与恢复，全部实时生效，无需 reload
- **多实例集中管理**：一个 admin 管理台可以管理任意多台 OpenResty 实例（agent），添加实例时自动验证连通性
- **登录鉴权与角色**：账号存本地配置文件，支持**超级管理员**（全部操作）与**只读用户**（仅查看）两种角色，每种角色可配多个用户；登录失败按 IP 限速
- **主动健康检查**：TCP 探活（默认 3s 间隔、超时 2s、连续失败 3 次自动摘除、连续成功 2 次自动恢复），页面实时展示节点健康状态
- **加权轮询**：按权重分发流量，故障节点自动重试下一个（`proxy_next_upstream`）
- **URI 前缀自动路由**：`/{upstream 名}/...` 自动路由到同名节点表，新增业务 upstream 不需要改 nginx 配置
- **重启自动恢复**：节点表全量持久化为 JSON，实例重启后自动加载，管理台实例列表同样持久化
- **零依赖**：仅使用 OpenResty 自带能力（`lua_shared_dict` + `balancer_by_lua` + cosocket）

## 架构

```
                      ┌──────────────────────────┐
   浏览器 ────────────▶  admin 管理台 (:8088)     │
                      │  html/ 单页 + Lua API     │
                      └────────┬─────────────────┘
                               │ HTTP + X-Auth-Token（agent 管理口）
                ┌──────────────┴───────────────┐
                ▼                              ▼
      ┌───────────────────┐          ┌───────────────────┐
      │ agent（OpenResty）│          │ agent（OpenResty） │
      │   业务口 :8080    │          │   业务口 :8080     │
      │   管理口 :8081    │          │   管理口 :8081     │
      └─────┬─────────────┘          └─────┬─────────────┘
            │ 加权轮询 + 健康检查             │
            ▼                              ▼
        后端节点池                       后端节点池
```

- **admin**：静态单页 + Lua API。登录用户与角色配置在 `conf/users.json`，实例列表持久化在 `data/instances.json`，对 upstream 的操作全部转发给对应 agent。
- **agent**：一个 OpenResty 实例。业务流量走动态 upstream `dyn_ups`（`balancer_by_lua` 从 shared dict 读节点表选点）；管理接口跑在独立端口，用 `X-Auth-Token` 鉴权。

```
openresty-ui/
├── admin/                 管理台（部署 1 台）
│   ├── conf/nginx.conf    监听 8088
│   ├── conf/users.json    登录用户与角色（明文密码，注意文件权限）
│   ├── html/index.html    管理页面（单文件，无构建）
│   ├── lua/admin_api.lua  实例管理 + 转发 API
│   ├── lua/auth.lua       登录 / session / 角色校验
│   └── data/              instances.json 持久化目录
├── agent/                 被管理的 OpenResty 实例（每台部署 1 份）
│   ├── conf/nginx.conf    业务口 8080 + 管理口 8081
│   └── lua/
│       ├── upstream_api.lua   管理 API（节点增删改查/摘流）
│       ├── balancer.lua       加权轮询 + URI 前缀路由
│       ├── healthcheck.lua    TCP 主动健康检查
│       └── init_worker.lua    重启恢复节点表 + 启动探活
├── quickstart.sh          一键体验（本机拉起完整演示环境）
└── quickstop.sh           停止演示
```

## 环境要求

- Linux（CentOS 7+ / Ubuntu 等主流发行版；Windows 建议在 WSL 中运行）
- [OpenResty](https://openresty.org/cn/installation.html) ≥ 1.15（建议 1.19+）
- curl（快速开始脚本使用）

## 快速开始（一键体验）

在一台装好 OpenResty 的 Linux 机器上：

```bash
git clone <本项目地址> && cd openresty-ui
./quickstart.sh
```

脚本会自动：

1. 启动 2 个演示后端（`127.0.0.1:9001` / `9002`，分别返回 `demo-backend-1` / `demo-backend-2`）
2. 启动 1 个 agent（业务口 `8080`、管理口 `8081`）
3. 启动 admin 管理台（`8088`）
4. 把 2 个演示后端注册进 agent 的 upstream `backend`，再把实例注册进管理台

完成后即可体验（登录账号沿用 `admin/conf/users.json` 中的配置，默认 `admin/admin123`；仅当该配置缺失时脚本才会临时生成随机密码并打印）：

```bash
# 连续请求业务入口，可以看到两个后端交替返回（加权轮询）
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/
```

浏览器打开 `http://<本机IP>:8088/`：

1. 左侧已登记实例 `local-agent`，点选后右侧展示 upstream 节点与实时健康状态（每 5s 自动刷新）
2. 对 `demo-backend-1` 点「摘流」，再连续 `curl 8080`，流量全部落到 `demo-backend-2`；点「恢复」回到双节点
3. 试「+ 添加节点」「编辑（改权重）」「删除」，全部即时生效

停止演示：

```bash
./quickstop.sh
```

## 正式部署

快速开始使用默认 token 且未做任何访问限制，**仅限体验**。正式部署请按下面步骤操作。

### 1. 部署 agent（每台 OpenResty 机器）

```bash
# 上传 agent 目录（示例放到 /opt/openresty-ui-agent）
scp -r agent/ root@<agent机器IP>:/opt/openresty-ui-agent/

# 【必须】修改管理口令为随机长串
# /opt/openresty-ui-agent/conf/nginx.conf 中：
#   set $inner_token "dyn-ups-inner-token";   <-- 改掉

# 【必须】放开管理口 IP 白名单（仅允许 admin 机器访问），去掉 conf 中注释：
#   allow <admin机器IP>;
#   deny all;

# 启动
openresty -p /opt/openresty-ui-agent -c conf/nginx.conf

# 放行管理口（业务口按需放行）
firewall-cmd --add-port=8081/tcp --permanent && firewall-cmd --reload
```

**接入业务流量**（agent 的 conf/nginx.conf 已内置示例）：把业务 server 的 `proxy_pass` 指向动态 upstream 即可：

```nginx
location / {
    proxy_pass http://dyn_ups;
    proxy_next_upstream error timeout;   # 失败自动重试下一节点
    ...
}
```

路由规则（免 reload，页面登记后立即生效）：

| 请求 URI | 使用的节点表 |
| --- | --- |
| `/{名字}/...`（已登记） | upstream `名字` |
| `/`（无前缀） | 默认 upstream `backend` |
| `/{名字}/...`（未登记） | 返回 502（error.log 有记录） |

如需传统的「路径与 upstream 强绑定」，也可以并存使用：

```nginx
upstream order_svc {
    server 0.0.0.0:1;   # 占位，balancer 接管
    balancer_by_lua_block { require("balancer").run("order_svc") }
}
server {
    listen 8080;
    location /order/ { proxy_pass http://order_svc; }
}
```

**配置域名证书（HTTPS）**：证书是 nginx 静态配置，与动态 upstream 互不影响——业务照常走 `dyn_ups`，节点仍由页面动态管理。建议证书统一放在 `conf/certs/` 目录，路径写绝对路径。在 agent 的 `conf/nginx.conf` 中新增：

```nginx
# ---------------- HTTPS 业务入口 ----------------
server {
    listen 443 ssl;
    server_name example.com www.example.com;

    # fullchain 证书（含中间证书）与私钥
    ssl_certificate     /opt/openresty-ui-agent/conf/certs/example.com.pem;
    ssl_certificate_key /opt/openresty-ui-agent/conf/certs/example.com.key;

    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_ciphers             HIGH:!aNULL:!MD5;
    ssl_session_cache       shared:SSL:10m;
    ssl_session_timeout     10m;

    location / {
        proxy_pass http://dyn_ups;              # 照常走动态 upstream
        proxy_next_upstream error timeout;
        proxy_set_header  Host             $host;
        proxy_set_header  X-Real-IP        $remote_addr;
        proxy_set_header  X-Forwarded-For  $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto https;
        proxy_connect_timeout 3s;
        proxy_read_timeout    10s;
    }
}

# ---------------- HTTP 跳转 HTTPS ----------------
server {
    listen 8080;                                # 或按需监听 80
    server_name example.com;
    return 301 https://$host$request_uri;
}
```

要点：

- **多个域名**：每个域名一个 server 块各配证书；域名较多且同属一个主体时可用一张通配符证书（`*.example.com`）
- **证书变更需 reload**：certbot / acme 更新证书文件后不会自动生效，执行一次平滑 reload 即可（不断连接）：
  ```bash
  openresty -p /opt/openresty-ui-agent -c conf/nginx.conf -s reload
  ```
  只有证书 / 端口这类静态配置变更才需要 reload，节点增删改仍然 0 reload

### 2. 部署 admin（任选 1 台机器）

```bash
scp -r admin/ root@<admin机器IP>:/opt/openresty-ui-admin/

# 【必须】修改登录账号：编辑 /opt/openresty-ui-admin/conf/users.json
# （默认 admin/admin123、viewer/viewer123，仅用于开箱体验）

# 生产环境建议 conf 中 user 改为专用低权用户，目录属主同步调整
openresty -p /opt/openresty-ui-admin -c conf/nginx.conf

firewall-cmd --add-port=8088/tcp --permanent && firewall-cmd --reload
```

浏览器打开 `http://<admin机器IP>:8088/`，点「+ 添加实例」：

- **名称**：自定义，如 `openresty-107`
- **IP 地址**：agent 机器 IP
- **端口**：agent 管理口，默认 `8081`
- **Token**：agent 的 `inner_token` 值

保存时会先验证连通性与 token，成功后即可在页面上管理该实例的节点。

### 3. 安全清单（生产必读）

- [ ] agent 的 `inner_token` 已改为随机长串（两个方向都要改：agent conf 与 admin 登记值）
- [ ] agent 管理口 8081 已配置 IP 白名单（`allow/deny`）或安全组，**仅 admin 机器可达**
- [ ] admin 登录账号已修改：删除或改掉默认的 `admin/admin123`、`viewer/viewer123`，`conf/users.json` 权限收紧为 `chmod 600`（密码为明文存储）
- [ ] admin 端口 8088 虽已有登录鉴权，仍建议用防火墙 / 安全组限制来源 IP（登录失败限速仅为 10 次/分钟/IP）
- [ ] admin 与 agent 建议部署在 `/opt` 等目录并以专用低权用户运行（conf 内 `user` 指令）
- [ ] 跨机房 / 公网传输时，管理口建议套 VPN 或 stunnel 等加密通道（当前为明文 HTTP + token，cookie 未强制 HTTPS）

## 用户与角色

登录用户保存在 `admin/conf/users.json`（明文密码，注意文件权限）。**每次登录时读取，增删改用户保存即生效，无需重启或 reload。**

```json
{
  "admin":    { "password": "改成强密码",   "role": "admin"  },
  "ops":      { "password": "改成强密码",   "role": "admin"  },
  "zhangsan": { "password": "改成强密码",   "role": "viewer" },
  "monitor":  { "password": "改成强密码",   "role": "viewer" }
}
```

| 角色 | 权限 |
| --- | --- |
| `admin`（超级管理员） | 全部操作：实例增删、节点增删改、权重调整、摘流/恢复 |
| `viewer`（只读用户） | 仅查看：实例列表、节点列表与健康状态（页面隐藏全部写操作按钮，接口层同样拦截返回 403） |

其他行为说明：

- 超级管理员可在页面右上角「用户管理」中新增用户、删除用户、修改密码与角色（写入 `conf/users.json`，立即生效）
- 保护规则：不能删除当前登录用户；系统始终保留至少一个超级管理员（删除/降级唯一 admin 会被拒绝）；用户密码或角色变更后，该用户所有在线 session 立即失效，需重新登录
- 登录后签发 HttpOnly Cookie，session 有效期 8 小时（活跃自动续期），存在内存中，admin 重启后需重新登录
- 登录失败按 IP 限速：60 秒内最多 10 次失败，超出返回 429

## API

除页面外，全部能力都可以脚本化调用。

### agent API（管理口 8081，请求头 `X-Auth-Token`）

| 方法 | 路径 | 参数 | 说明 |
| --- | --- | --- | --- |
| GET | `/nginx_inner/upstream/list` | - | 查看全部 upstream 节点（含健康状态） |
| POST | `/nginx_inner/upstream/add_server` | `upstream, host, port, weight` | 添加节点 |
| POST | `/nginx_inner/upstream/update_server` | `upstream, host, port, weight, new_host, new_port` | 修改节点（地址 / 权重） |
| POST | `/nginx_inner/upstream/delete_server` | `upstream, host, port` | 删除节点 |
| POST | `/nginx_inner/upstream/set_server` | `upstream, host, port, down` | 手动摘流（`down:true`）/ 恢复 |

```bash
TOKEN="你的inner_token"

# 添加节点
curl -X POST http://127.0.0.1:8081/nginx_inner/upstream/add_server \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"upstream":"backend","host":"192.168.2.145","port":8080,"weight":1}'

# 摘流（发布前摘掉一台）
curl -X POST http://127.0.0.1:8081/nginx_inner/upstream/set_server \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"upstream":"backend","host":"192.168.2.145","port":8080,"down":true}'

# 查看节点与健康状态
curl -H "X-Auth-Token: $TOKEN" http://127.0.0.1:8081/nginx_inner/upstream/list
```

### admin API（8088，需先登录）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/login` | 登录 `{username, password}`，成功签发 HttpOnly cookie |
| POST | `/api/logout` | 登出 |
| GET | `/api/me` | 当前登录用户 `{username, role}` |
| GET | `/api/users` | 用户列表（仅 admin，不含密码） |
| POST | `/api/users` | 新增用户 `{username, password, role}`（仅 admin） |
| POST | `/api/users/update` | 改密码/角色 `{username, password?, role?}`（仅 admin，密码留空不改） |
| POST | `/api/users/delete` | 删除用户 `{username}`（仅 admin） |
| GET | `/api/instances` | 实例列表（登录即可，viewer 可用） |
| POST | `/api/instances` | 添加实例 `{name, host, port, token}`（仅 admin，先探活校验） |
| POST | `/api/instances/delete` | 删除实例 `{name}`（仅 admin） |
| GET | `/api/upstreams?instance=名称` | 查询该实例全部节点（登录即可，viewer 可用） |
| POST | `/api/upstreams/add_server` 等 | 同 agent 的 4 个操作，body 增加 `instance` 字段（仅 admin） |

```bash
# 登录（cookie 存入当前目录 cookie.txt，后续请求带上）
curl -c cookie.txt -X POST http://127.0.0.1:8088/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"你的密码"}'

# 查询实例节点
curl -b cookie.txt "http://127.0.0.1:8088/api/upstreams?instance=openresty-107"
```

## 工作原理

- **0 reload 的关键**：节点表存放在 `lua_shared_dict`，`balancer_by_lua` 每个请求实时读取，管理接口改写 shared dict 后下一个请求即生效
- **健康检查**：worker 0 定时器对全部节点 TCP 探活，状态写回 shared dict，balancer 选点时过滤 DOWN 节点；全部 DOWN 时兜底放行避免误杀
- **持久化与恢复**：每次变更全量落盘 `data/upstreams.json`（临时文件 + rename 原子写），重启后 `init_worker` 恢复；admin 的实例列表同样落盘 `data/instances.json`
- **加权轮询**：权重展开为槽位 + 共享计数器取模；重试时避开刚失败的节点

## 常见问题

**Q：agent 重启后节点还在吗？**
在。节点表每次变更都持久化到 `data/upstreams.json`，重启自动恢复。

**Q：健康检查能换成 HTTP 探活吗？**
可以，`agent/lua/healthcheck.lua` 的 `check_one` 中已留注释说明改法。

**Q：一个 admin 能管多少 agent？**
没有硬限制；agent 数量、探活频率都低于管理面的处理能力，几百台规模没有压力。

**Q：与 Consul / Nacos 等注册中心方案相比？**
本项目面向「只要动态 upstream、不想引入新组件」的场景：无 etcd、无数据库、无额外进程，一个 OpenResty 全搞定；代价是没有服务自动注册、多数据中心等高级能力。

## License

[Apache-2.0](LICENSE)
