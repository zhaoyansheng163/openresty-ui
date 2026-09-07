-- 基于 cosocket 的极简 HTTP 客户端，仅覆盖管理面所需的 GET / POST JSON，
-- 不引入 lua-resty-http 等外部依赖。
local _M = {}

local function read_response(sock)
    local line = sock:receive("*l")
    if not line then return nil, "empty response" end
    local status = tonumber(line:match("^HTTP/%d%.%d (%d+)"))
    if not status then return nil, "malformed status line" end

    local headers = {}
    while true do
        line = sock:receive("*l")
        if not line or line == "" then break end
        local k, v = line:match("^(%S-):%s*(.-)%s*$")
        if k then headers[k:lower()] = v end
    end

    local body
    local len = tonumber(headers["content-length"])
    if len and len > 0 then
        body = sock:receive(len)
    elseif headers["transfer-encoding"] == "chunked" then
        local chunks = {}
        while true do
            local n = tonumber(sock:receive("*l") or "", 16)
            if not n or n == 0 then break end
            chunks[#chunks + 1] = sock:receive(n)
            sock:receive("*l")  -- chunk 后的 CRLF
        end
        body = table.concat(chunks)
    else
        body = ""
    end
    return status, body
end

-- httpc.request("POST", host, port, path, json_body_or_nil, token, timeout_ms)
-- 成功返回 status, body；失败返回 nil, err
function _M.request(method, host, port, path, body, token, timeout_ms)
    local sock = ngx.socket.tcp()
    sock:settimeout(timeout_ms or 5000)

    local ok, err = sock:connect(host, port)
    if not ok then return nil, "connect " .. host .. ":" .. port .. " failed: " .. tostring(err) end

    local req = {
        method .. " " .. path .. " HTTP/1.1\r\n",
        "Host: " .. host .. "\r\n",
        "Connection: close\r\n",
    }
    if token and token ~= "" then
        req[#req + 1] = "X-Auth-Token: " .. token .. "\r\n"
    end
    if body then
        req[#req + 1] = "Content-Type: application/json\r\n"
        req[#req + 1] = "Content-Length: " .. #body .. "\r\n"
    end
    req[#req + 1] = "\r\n"
    if body then
        req[#req + 1] = body
    end

    ok, err = sock:send(table.concat(req))
    if not ok then
        sock:close()
        return nil, "send failed: " .. tostring(err)
    end

    local status, resp = read_response(sock)
    sock:close()
    if not status then
        return nil, "read response failed: " .. tostring(resp)
    end
    return status, resp
end

return _M
