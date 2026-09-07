-- 主动健康检查：worker 0 的定时器对全部动态节点做 TCP 探活。
-- 连续失败 FALL 次判定 DOWN（balancer 摘流），连续成功 RISE 次恢复。
local cjson = require "cjson.safe"

local _M = {}

local INTERVAL = 3   -- 探活间隔（秒）
local TIMEOUT  = 2   -- 单次探活超时（秒）
local FALL     = 3   -- 连续失败摘除
local RISE     = 2   -- 连续成功恢复

local nodes_dict  = ngx.shared.upstream_nodes
local health_dict = ngx.shared.node_health

local function node_key(n)
    return "hc:" .. n.host .. ":" .. n.port
end

local function check_one(node)
    local sock = ngx.socket.tcp()
    sock:settimeout(TIMEOUT * 1000)
    local ok = sock:connect(node.host, node.port)
    if ok then
        -- TCP 握手成功即视为存活；如需 HTTP 探活，
        -- 可改为发送 "GET <path> HTTP/1.0\r\nHost: x\r\n\r\n" 并校验状态码
        sock:close()
    end
    return ok
end

local function check_all(premature)
    if premature then return end

    -- 从节点表收集全部去重后的节点
    local seen = {}
    for _, k in ipairs(nodes_dict:get_keys(1024)) do
        if type(k) == "string" and k:sub(1, 4) == "ups:" then
            local nodes = cjson.decode(nodes_dict:get(k) or "")
            for _, n in ipairs(nodes or {}) do
                seen[node_key(n)] = n
            end
        end
    end

    for key, n in pairs(seen) do
        local alive = check_one(n)
        local st = cjson.decode(health_dict:get(key) or "") or { fail = 0, ok = 0, down = false }
        if alive then
            st.fail = 0
            st.ok = (st.ok or 0) + 1
            if st.down and st.ok >= RISE then
                st.down = false
                ngx.log(ngx.NOTICE, "dyn-ups healthcheck: ", key, " recovered (rise ", st.ok, ")")
            end
        else
            st.ok = 0
            st.fail = (st.fail or 0) + 1
            if not st.down and st.fail >= FALL then
                st.down = true
                ngx.log(ngx.WARN, "dyn-ups healthcheck: ", key, " marked DOWN (fall ", st.fail, ")")
            end
        end
        health_dict:safe_set(key, cjson.encode(st))
    end
end

function _M.start()
    -- 仅 worker 0 跑定时器，避免每个 worker 重复探活
    if ngx.worker.id() ~= 0 then return end
    local ok, err = ngx.timer.every(INTERVAL * 1000, check_all)
    if not ok then
        ngx.log(ngx.ERR, "dyn-ups: start healthcheck timer failed: ", err)
    end
end

return _M
