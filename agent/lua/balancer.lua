-- balancer_by_lua 动态负载均衡：
-- 从 shared dict 读节点表 -> 过滤手动摘流与健康检查 DOWN 节点 -> 加权轮询选点。
local balancer = require "ngx.balancer"
local cjson    = require "cjson.safe"

local nodes_dict  = ngx.shared.upstream_nodes
local health_dict = ngx.shared.node_health
local rr_dict     = ngx.shared.rr_counter

local _M = {}

-- 无前缀请求（如 / ）回落到的默认 upstream 名
local DEFAULT_UPS = "backend"

local function node_key(n)
    return n.host .. ":" .. n.port
end

local function get_nodes(ups)
    local raw = nodes_dict:get("ups:" .. ups)
    if not raw then return nil end
    return cjson.decode(raw)
end

local function is_healthy(node)
    local st = cjson.decode(health_dict:get("hc:" .. node_key(node)) or "")
    if st and st.down then return false end
    return true
end

-- 权重展开为槽位 + 共享计数器取模，实现加权轮询；
-- exclude 用于 proxy_next_upstream 重试时避开刚失败的节点
local function pick(pool, exclude)
    local slots = {}
    for _, n in ipairs(pool) do
        if not exclude or node_key(n) ~= exclude then
            local w = tonumber(n.weight) or 1
            if w < 1 then w = 1 end
            if w > 100 then w = 100 end
            for _ = 1, w do
                slots[#slots + 1] = n
            end
        end
    end
    if #slots == 0 then return nil end
    local cnt = rr_dict:incr("rr", 1, 0)
    return slots[(cnt - 1) % #slots + 1]
end

function _M.run(ups)
    local nodes = get_nodes(ups)
    if type(nodes) ~= "table" or #nodes == 0 then
        ngx.log(ngx.ERR, "dyn-ups: upstream [", ups, "] has no server, return 502")
        return ngx.exit(502)
    end

    local candidates, fallback = {}, {}
    for _, n in ipairs(nodes) do
        -- manual_down 是人工摘流指令，任何情况下都不参与分发
        if not n.manual_down then
            if is_healthy(n) then
                candidates[#candidates + 1] = n
            else
                fallback[#fallback + 1] = n
            end
        end
    end

    local pool = candidates
    if #pool == 0 then
        -- 健康检查全部摘除时退回全部非手动摘流节点，尽力而为，避免直接 502
        pool = fallback
        ngx.log(ngx.WARN, "dyn-ups: upstream [", ups, "] all servers unhealthy, fallback to all")
    end
    if #pool == 0 then
        ngx.log(ngx.ERR, "dyn-ups: upstream [", ups, "] all servers manually down, return 502")
        return ngx.exit(502)
    end

    local last = ngx.ctx.dyn_ups_last_peer
    local picked = pick(pool, (#pool > 1) and last or nil)
    if not picked then
        picked = pool[1]
    end

    local ok, err = balancer.set_more_tries(1)
    if not ok then
        ngx.log(ngx.WARN, "dyn-ups: set_more_tries failed: ", err)
    end

    ok, err = balancer.set_current_peer(picked.host, picked.port)
    if not ok then
        ngx.log(ngx.ERR, "dyn-ups: set_current_peer failed: ", err)
        return ngx.exit(502)
    end

    ngx.ctx.dyn_ups_last_peer = node_key(picked)
end

-- URI 前缀自动路由：/{upstream名}/... 使用该名字的节点表；
-- 无前缀回落默认 upstream；前缀名未登记返回 502。
-- 名字规则与 upstream_api 的校验保持一致（字母数字点横线下划线）。
function _M.run_auto()
    local name = (ngx.var.uri or ""):match("^/([%w%.%-_]+)/")
    if not name then
        return _M.run(DEFAULT_UPS)
    end
    if not nodes_dict:get("ups:" .. name) then
        ngx.log(ngx.ERR, "dyn-ups: uri 前缀 [", name, "] 未登记任何节点, return 502")
        return ngx.exit(502)
    end
    return _M.run(name)
end

return _M
