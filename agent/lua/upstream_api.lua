-- /nginx_inner/upstream/* 管理 API：
--   GET  /nginx_inner/upstream/list           查看全部 upstream 节点（含健康状态）
--   POST /nginx_inner/upstream/add_server     {upstream, host, port, weight}
--   POST /nginx_inner/upstream/update_server  {upstream, host, port, weight, new_host, new_port}
--   POST /nginx_inner/upstream/delete_server  {upstream, host, port}
--   POST /nginx_inner/upstream/set_server     {upstream, host, port, down}  手动摘流/恢复
-- 变更实时写入 lua_shared_dict（balancer 立即生效，0 reload），并全量持久化到
-- data/upstreams.json，实例重启后自动恢复。
local cjson = require "cjson.safe"

local nodes_dict  = ngx.shared.upstream_nodes
local health_dict = ngx.shared.node_health

local PERSIST_FILE = ngx.config.prefix() .. "data/upstreams.json"

-- ==================== 通用 ====================

local function json_exit(code, msg, data)
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({ code = code, msg = msg, data = data }))
    return ngx.exit(ngx.HTTP_OK)
end

local function auth()
    local token = ngx.var.http_x_auth_token
    if token and token ~= "" and token == ngx.var.inner_token then
        return true
    end
    ngx.status = ngx.HTTP_UNAUTHORIZED
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({ code = "E401", msg = "invalid or missing X-Auth-Token" }))
    return ngx.exit(ngx.HTTP_UNAUTHORIZED)
end

local function read_json_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "r")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end
    if not body or body == "" then return nil, "empty body" end
    local data = cjson.decode(body)
    if type(data) ~= "table" then return nil, "body must be a JSON object" end
    return data
end

-- ==================== 校验 ====================

local function check_int(v, min, max)
    local n = tonumber(v)
    if not n or n < min or n > max or math.floor(n) ~= n then return nil end
    return n
end

local function validate(args)
    if type(args.upstream) ~= "string"
       or not args.upstream:match("^[%w%.%-_]+$")
       or #args.upstream > 64 then
        return nil, "invalid upstream name"
    end
    -- 仅允许 IPv4 / 域名字符（暂不支持 IPv6 字面量，key 拼接用 host:port）
    if type(args.host) ~= "string"
       or not args.host:match("^[%w%.%-]+$")
       or #args.host > 128 then
        return nil, "invalid host"
    end
    local port = check_int(args.port, 1, 65535)
    if not port then return nil, "invalid port (1-65535)" end
    return {
        upstream = args.upstream,
        host = args.host,
        port = port,
    }
end

-- ==================== 节点表存取与持久化 ====================

local function load_nodes(ups)
    local raw = nodes_dict:get("ups:" .. ups)
    if not raw then return {} end
    local nodes = cjson.decode(raw)
    if type(nodes) ~= "table" then return {} end
    return nodes
end

-- 全量持久化 dict 中的 ups:* 到 JSON 文件（临时文件 + rename 原子替换）
local function persist()
    local data = {}
    for _, k in ipairs(nodes_dict:get_keys(1024)) do
        if type(k) == "string" and k:sub(1, 4) == "ups:" then
            local nodes = cjson.decode(nodes_dict:get(k))
            if type(nodes) == "table" then
                data[k:sub(5)] = nodes
            end
        end
    end

    local tmp = PERSIST_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return "open persist file failed"
    end
    f:write(cjson.encode(data))
    f:close()
    pcall(os.remove, PERSIST_FILE)
    if not os.rename(tmp, PERSIST_FILE) then
        return "rename persist file failed"
    end
    return nil
end

local function save_nodes(ups, nodes)
    local ok, err = nodes_dict:safe_set("ups:" .. ups, cjson.encode(nodes))
    if not ok then return err end
    return persist()
end

local function find_index(nodes, host, port)
    for i, n in ipairs(nodes) do
        if n.host == host and tonumber(n.port) == port then return i end
    end
    return nil
end

local function drop_health(host, port)
    health_dict:delete("hc:" .. host .. ":" .. port)
end

-- ==================== 各操作 ====================

local function handle_list()
    local result = {}
    for _, k in ipairs(nodes_dict:get_keys(1024)) do
        if type(k) == "string" and k:sub(1, 4) == "ups:" then
            local nodes = cjson.decode(nodes_dict:get(k)) or {}
            for _, n in ipairs(nodes) do
                local st = cjson.decode(health_dict:get("hc:" .. n.host .. ":" .. n.port) or "") or {}
                n.fails       = st.fail or 0
                n.health_down = st.down and true or false
            end
            result[k:sub(5)] = nodes
        end
    end
    return json_exit("OK", "ok", result)
end

local function handle_add_server()
    local args, err = read_json_body()
    if not args then return json_exit("E001", err) end
    local node, verr = validate(args)
    if not node then return json_exit("E002", verr) end
    local weight = check_int(args.weight or 1, 1, 100)
    if not weight then return json_exit("E002", "invalid weight (1-100)") end

    local nodes = load_nodes(node.upstream)
    if find_index(nodes, node.host, node.port) then
        return json_exit("E101", "server already exists")
    end
    nodes[#nodes + 1] = {
        host = node.host, port = node.port,
        weight = weight, manual_down = false,
    }
    err = save_nodes(node.upstream, nodes)
    if err then return json_exit("E500", "persist failed: " .. err) end
    return json_exit("OK", "added")
end

local function handle_update_server()
    local args, err = read_json_body()
    if not args then return json_exit("E001", err) end
    local node, verr = validate(args)
    if not node then return json_exit("E002", verr) end

    local nodes = load_nodes(node.upstream)
    local i = find_index(nodes, node.host, node.port)
    if not i then
        return json_exit("E102", "server not found")
    end

    local cur = nodes[i]
    local new_host, new_port = cur.host, cur.port
    if args.new_host or args.new_port then
        new_host = args.new_host or cur.host
        new_port = check_int(args.new_port or cur.port, 1, 65535)
        if type(new_host) ~= "string" or not new_host:match("^[%w%.%-]+$") then
            return json_exit("E002", "invalid new_host")
        end
        if not new_port then
            return json_exit("E002", "invalid new_port")
        end
        if new_host ~= cur.host or new_port ~= tonumber(cur.port) then
            if find_index(nodes, new_host, new_port) then
                return json_exit("E101", "target server already exists")
            end
            drop_health(cur.host, cur.port)
        end
    end

    local weight = cur.weight
    if args.weight ~= nil then
        weight = check_int(args.weight, 1, 100)
        if not weight then return json_exit("E002", "invalid weight (1-100)") end
    end

    nodes[i] = { host = new_host, port = new_port, weight = weight, manual_down = cur.manual_down }
    err = save_nodes(node.upstream, nodes)
    if err then return json_exit("E500", "persist failed: " .. err) end
    return json_exit("OK", "updated")
end

local function handle_delete_server()
    local args, err = read_json_body()
    if not args then return json_exit("E001", err) end
    local node, verr = validate(args)
    if not node then return json_exit("E002", verr) end

    local nodes = load_nodes(node.upstream)
    local i = find_index(nodes, node.host, node.port)
    if not i then
        return json_exit("E102", "server not found")
    end
    table.remove(nodes, i)
    drop_health(node.host, node.port)
    err = save_nodes(node.upstream, nodes)
    if err then return json_exit("E500", "persist failed: " .. err) end
    return json_exit("OK", "deleted")
end

local function handle_set_server()
    local args, err = read_json_body()
    if not args then return json_exit("E001", err) end
    local node, verr = validate(args)
    if not node then return json_exit("E002", verr) end

    local nodes = load_nodes(node.upstream)
    local i = find_index(nodes, node.host, node.port)
    if not i then
        return json_exit("E102", "server not found")
    end
    nodes[i].manual_down = args.down and true or false
    err = save_nodes(node.upstream, nodes)
    if err then return json_exit("E500", "persist failed: " .. err) end
    return json_exit("OK", args.down and "set manual DOWN" or "set manual UP")
end

-- ==================== 路由 ====================

auth()

local action = ngx.var.uri:match("^/nginx_inner/upstream/([%w_]+)$")

if action == "list" then
    if ngx.var.request_method ~= "GET" then return json_exit("E003", "method not allowed") end
    return handle_list()
end

local post_handlers = {
    add_server    = handle_add_server,
    update_server = handle_update_server,
    delete_server = handle_delete_server,
    set_server    = handle_set_server,
}

local handler = post_handlers[action]
if not handler then
    return json_exit("E004", "unknown action: " .. tostring(action))
end
if ngx.var.request_method ~= "POST" then
    return json_exit("E003", "method not allowed")
end
handler()
