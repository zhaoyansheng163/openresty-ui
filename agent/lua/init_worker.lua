-- 每个 worker 启动时执行：
-- 1. 重启后（shared dict 为空）从 data/upstreams.json 恢复节点表；
--    reload 时 shared dict 数据保留、"::_boot" 标记仍在，不会重复加载。
-- 2. 启动主动健康检查定时器（仅 worker 0）。
local cjson = require "cjson.safe"

local function restore_from_file()
    local dict = ngx.shared.upstream_nodes

    -- add 为原子操作，仅当 key 不存在时成功，保证多 worker 下只有一个加载
    local ok, err = dict:add("::_boot", 1)
    if not ok then
        if err == "exists" then return end
        ngx.log(ngx.ERR, "dyn-ups: add boot flag failed: ", err)
        return
    end

    local path = ngx.config.prefix() .. "data/upstreams.json"
    local f = io.open(path, "r")
    if not f then
        ngx.log(ngx.NOTICE, "dyn-ups: no persisted file, start with empty node table")
        return
    end
    local body = f:read("*a")
    f:close()

    local data = cjson.decode(body)
    if type(data) ~= "table" then
        ngx.log(ngx.ERR, "dyn-ups: invalid persisted file, ignore")
        return
    end

    local n = 0
    for name, nodes in pairs(data) do
        if type(name) == "string" and type(nodes) == "table" then
            local ok2, err2 = dict:safe_set("ups:" .. name, cjson.encode(nodes))
            if ok2 then
                n = n + #nodes
            else
                ngx.log(ngx.ERR, "dyn-ups: restore [", name, "] failed: ", err2)
            end
        end
    end
    ngx.log(ngx.NOTICE, "dyn-ups: restored ", n, " servers from persisted file")
end

restore_from_file()
require("healthcheck").start()
