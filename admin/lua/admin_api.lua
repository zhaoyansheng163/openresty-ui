-- 管理端 API（登录鉴权见 lua/auth.lua，用户配置见 conf/users.json）：
--   POST /api/login                            登录 {username, password}
--   POST /api/logout                           登出
--   GET  /api/me                               当前登录用户
--   GET  /api/users                            用户列表（仅 admin）
--   POST /api/users                            新增用户 {username, password, role}（仅 admin）
--   POST /api/users/update                     改密码/角色 {username, password?, role?}（仅 admin）
--   POST /api/users/delete                     删除用户 {username}（仅 admin）
--   GET  /api/instances                        实例列表（登录即可）
--   POST /api/instances                        添加实例 {name, host, port, token}（仅 admin）
--   POST /api/instances/delete                 删除实例 {name}（仅 admin）
--   GET  /api/upstreams?instance=NAME          查询指定实例的 upstream（转发 agent list，登录即可）
--   POST /api/upstreams/add_server             {instance, upstream, host, port, weight}（仅 admin）
--   POST /api/upstreams/update_server          {instance, upstream, host, port, weight, new_host, new_port}（仅 admin）
--   POST /api/upstreams/delete_server          {instance, upstream, host, port}（仅 admin）
--   POST /api/upstreams/set_server             {instance, upstream, host, port, down}（仅 admin）
local cjson = require "cjson.safe"
local httpc = require "httpc"
local auth = require "auth"

local INSTANCES_FILE = ngx.config.prefix() .. "data/instances.json"

-- ==================== 通用 ====================

local function json_exit(status, code, msg, data)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({ code = code, msg = msg, data = data }))
    return ngx.exit(status == 200 and ngx.HTTP_OK or status)
end

local function read_json_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then return nil, "empty body" end
    local data = cjson.decode(body)
    if type(data) ~= "table" then return nil, "body must be a JSON object" end
    return data
end

-- ==================== 实例存取 ====================

local function load_instances()
    local f = io.open(INSTANCES_FILE, "r")
    if not f then return {} end
    local body = f:read("*a")
    f:close()
    local list = cjson.decode(body)
    if type(list) ~= "table" then return {} end
    return list
end

local function save_instances(list)
    local tmp = INSTANCES_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return "open instances file failed" end
    f:write(cjson.encode(list))
    f:close()
    pcall(os.remove, INSTANCES_FILE)
    if not os.rename(tmp, INSTANCES_FILE) then
        return "rename instances file failed"
    end
    return nil
end

local function find_instance(list, name)
    for _, inst in ipairs(list) do
        if inst.name == name then return inst end
    end
    return nil
end

-- ==================== 实例管理 ====================

local function handle_instances_get()
    local list = load_instances()
    return json_exit(200, "OK", "ok", list)
end

local function handle_instances_add()
    local args, err = read_json_body()
    if not args then return json_exit(400, "E001", err) end

    local name = args.name
    if type(name) ~= "string" or not name:match("^[%w%.%-_]+$") or #name > 64 then
        return json_exit(400, "E002", "invalid instance name")
    end
    local host = args.host
    if type(host) ~= "string" or not host:match("^[%w%.%-]+$") or #host > 128 then
        return json_exit(400, "E002", "invalid host")
    end
    local port = tonumber(args.port)
    if not port or port < 1 or port > 65535 or math.floor(port) ~= port then
        return json_exit(400, "E002", "invalid port (1-65535)")
    end
    local token = args.token
    if token ~= nil and (type(token) ~= "string" or #token > 128) then
        return json_exit(400, "E002", "invalid token")
    end

    local list = load_instances()
    if find_instance(list, name) then
        return json_exit(400, "E101", "instance already exists")
    end

    -- 添加前先探活，尽早暴露地址/端口/token 错误
    local status, resp = httpc.request("GET", host, port, "/nginx_inner/upstream/list",
                                       nil, token, 3000)
    if not status then
        return json_exit(400, "E102", "instance unreachable: " .. tostring(resp))
    end
    if status == 401 then
        return json_exit(400, "E103", "auth failed: check token")
    end

    list[#list + 1] = { name = name, host = host, port = port, token = token or "" }
    err = save_instances(list)
    if err then return json_exit(500, "E500", err) end
    return json_exit(200, "OK", "instance added")
end

local function handle_instances_delete()
    local args, err = read_json_body()
    if not args then return json_exit(400, "E001", err) end
    local list = load_instances()
    local found = false
    for i, inst in ipairs(list) do
        if inst.name == args.name then
            table.remove(list, i)
            found = true
            break
        end
    end
    if not found then
        return json_exit(404, "E104", "instance not found")
    end
    err = save_instances(list)
    if err then return json_exit(500, "E500", err) end
    return json_exit(200, "OK", "instance deleted")
end

-- ==================== 转发到 agent ====================

local function current_instance(args)
    local name = args.instance
    if type(name) ~= "string" or name == "" then
        return nil, json_exit(400, "E002", "missing instance")
    end
    local inst = find_instance(load_instances(), name)
    if not inst then
        return nil, json_exit(404, "E104", "instance not found: " .. name)
    end
    return inst
end

local function forward_get_list()
    local inst, jerr = current_instance({ instance = ngx.var.arg_instance })
    if not inst then return jerr end

    local status, resp = httpc.request("GET", inst.host, inst.port,
                                       "/nginx_inner/upstream/list", nil, inst.token, 5000)
    if not status then
        return json_exit(502, "E201", "agent unreachable: " .. tostring(resp))
    end
    if status == 401 then
        return json_exit(502, "E103", "agent auth failed: check token")
    end
    -- 透传 agent 响应，包一层实例信息
    local agent_data = cjson.decode(resp or "")
    return json_exit(200, "OK", "ok", {
        instance = inst.name,
        upstreams = (agent_data and agent_data.data) or {},
    })
end

local function forward_post(action)
    local args, err = read_json_body()
    if not args then return json_exit(400, "E001", err) end
    local inst, jerr = current_instance(args)
    if not inst then return jerr end

    local status, resp = httpc.request("POST", inst.host, inst.port,
                                       "/nginx_inner/upstream/" .. action,
                                       cjson.encode(args), inst.token, 5000)
    if not status then
        return json_exit(502, "E201", "agent unreachable: " .. tostring(resp))
    end
    if status == 401 then
        return json_exit(502, "E103", "agent auth failed: check token")
    end

    -- 原样透传 agent 的 {code, msg, data}
    ngx.status = 200
    ngx.header.content_type = "application/json"
    local out = resp
    if not out or out == "" then
        out = cjson.encode({ code = "E202", msg = "empty agent response" })
    end
    ngx.say(out)
    return ngx.exit(ngx.HTTP_OK)
end

-- ==================== 路由 ====================

local uri, method = ngx.var.uri, ngx.var.request_method

-- 登录相关，无需鉴权
if uri == "/api/login" and method == "POST" then
    return auth.handle_login()
elseif uri == "/api/logout" and method == "POST" then
    return auth.handle_logout()
elseif uri == "/api/me" and method == "GET" then
    return auth.handle_me()
end

-- 其余接口一律需要登录（admin / viewer 均可）
local sess = auth.require_login()
if not sess then return end

-- 查询类：登录即可
if uri == "/api/instances" and method == "GET" then
    return handle_instances_get()
elseif uri == "/api/upstreams" and method == "GET" then
    return forward_get_list()
end

-- 写操作类：仅超级管理员
if not auth.require_admin(sess) then return end

if uri == "/api/instances" and method == "POST" then
    return handle_instances_add()
elseif uri == "/api/instances/delete" and method == "POST" then
    return handle_instances_delete()
elseif uri == "/api/users" and method == "GET" then
    return auth.handle_users_list()
elseif uri == "/api/users" and method == "POST" then
    return auth.handle_users_add()
elseif uri == "/api/users/update" and method == "POST" then
    return auth.handle_users_update()
elseif uri == "/api/users/delete" and method == "POST" then
    return auth.handle_users_delete(sess)
elseif uri == "/api/upstreams/add_server" and method == "POST" then
    return forward_post("add_server")
elseif uri == "/api/upstreams/update_server" and method == "POST" then
    return forward_post("update_server")
elseif uri == "/api/upstreams/delete_server" and method == "POST" then
    return forward_post("delete_server")
elseif uri == "/api/upstreams/set_server" and method == "POST" then
    return forward_post("set_server")
end

return json_exit(404, "E404", "not found: " .. method .. " " .. uri)
