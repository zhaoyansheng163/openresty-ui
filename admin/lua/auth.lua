-- 登录鉴权与用户管理：
--   POST /api/login    {username, password}  登录，签发 HttpOnly cookie
--   POST /api/logout                          登出，销毁 session
--   GET  /api/me                              当前登录用户 {username, role}
--   GET  /api/users                           用户列表 [{username, role}]（仅 admin）
--   POST /api/users                           新增用户 {username, password, role}（仅 admin）
--   POST /api/users/update                    修改密码/角色 {username, password?, role?}（仅 admin）
--   POST /api/users/delete                    删除用户 {username}（仅 admin）
-- 用户与角色来自 conf/users.json（明文密码，注意文件权限）：
--   { "用户名": {"password": "明文", "role": "admin"|"viewer"}, ... }
-- 每次登录时读取文件，增删改用户保存即生效，无需 reload。
-- 保护规则：不可删除当前登录用户；系统必须始终保留至少一个 admin
--（删除/降级唯一 admin 会被拒绝）；用户信息变更后其全部 session 立即失效。
-- session 存 lua_shared_dict admin_sessions（有效期 8h，活跃自动续期）；
-- 登录失败按 IP 限速：60 秒内最多 10 次。
local cjson = require "cjson.safe"

local sessions_dict = ngx.shared.admin_sessions
local limit_dict    = ngx.shared.admin_login_limit

local USERS_FILE   = ngx.config.prefix() .. "conf/users.json"
local COOKIE       = "_oui_session"
local SESSION_TTL  = 28800   -- 秒，8 小时
local MAX_FAILS    = 10      -- 每 IP 每 60 秒允许的失败次数

-- 文件缺失/损坏时的兜底账号（与仓库默认 users.json 相同，日志有提示）
local DEFAULT_USERS = {
    admin  = { password = "admin123",  role = "admin"  },
    viewer = { password = "viewer123", role = "viewer" },
}

local _M = {}

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
    if not body or body == "" then return nil end
    local data = cjson.decode(body)
    if type(data) ~= "table" then return nil end
    return data
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function get_cookie(name)
    local cookie = ngx.var.http_cookie
    if not cookie then return nil end
    for k, v in cookie:gmatch("([%w_]+)=([^;]*)") do
        if k == name then return v end
    end
    return nil
end

local function load_users()
    local f = io.open(USERS_FILE, "r")
    if not f then
        ngx.log(ngx.WARN, "auth: users file not found: ", USERS_FILE, ", using built-in defaults")
        return DEFAULT_USERS
    end
    local body = f:read("*a")
    f:close()
    local users = cjson.decode(body)
    if type(users) ~= "table" then
        ngx.log(ngx.ERR, "auth: invalid users file: ", USERS_FILE, ", using built-in defaults")
        return DEFAULT_USERS
    end
    return users
end

-- 原子写回用户文件（临时文件 + rename）
local function save_users(users)
    local tmp = USERS_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return "open users file failed" end
    f:write(cjson.encode(users))
    f:close()
    pcall(os.remove, USERS_FILE)
    if not os.rename(tmp, USERS_FILE) then
        return "rename users file failed"
    end
    return nil
end

local function count_admins(users)
    local n = 0
    for _, u in pairs(users) do
        if type(u) == "table" and u.role == "admin" then n = n + 1 end
    end
    return n
end

-- 用户信息（密码/角色）变更或删除后，踢掉该用户全部在线 session
local function drop_sessions_of(username)
    for _, k in ipairs(sessions_dict:get_keys(1024)) do
        if type(k) == "string" and k:sub(1, 5) == "sess:" then
            local sess = cjson.decode(sessions_dict:get(k) or "")
            if type(sess) == "table" and sess.username == username then
                sessions_dict:delete(k)
            end
        end
    end
end

local function new_token()
    -- 多熵源 + shared dict 递增序号，保证 token 不重复、不可预测
    local seq = sessions_dict:incr("::_seq", 1, 0) or 0
    return hex(ngx.sha1_bin(table.concat({
        ngx.now(), ngx.worker.pid(), ngx.worker.id(), seq, math.random(),
    }, ":")))
end

-- ==================== 登录 / 登出 / 当前用户 ====================

function _M.handle_login()
    local ip  = ngx.var.remote_addr
    local fk  = "fail:" .. ip
    if (limit_dict:get(fk) or 0) >= MAX_FAILS then
        return json_exit(429, "E429", "too many failed attempts, retry in 1 minute")
    end

    local args = read_json_body()
    if not args then
        return json_exit(400, "E001", "empty or invalid body")
    end

    local users = load_users()
    local u = users[tostring(args.username or "")]
    if type(u) ~= "table"
       or u.role ~= "admin" and u.role ~= "viewer"
       or type(args.password) ~= "string"
       or u.password ~= args.password then
        limit_dict:incr(fk, 1, 0, 60)
        return json_exit(401, "E401", "invalid username or password")
    end

    limit_dict:delete(fk)

    local username = tostring(args.username)
    local token = new_token()
    local ok = sessions_dict:safe_set("sess:" .. token,
        cjson.encode({ username = username, role = u.role }), SESSION_TTL)
    if not ok then
        return json_exit(500, "E500", "create session failed")
    end

    ngx.header.set_cookie = string.format(
        "%s=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d",
        COOKIE, token, SESSION_TTL)
    return json_exit(200, "OK", "ok", { username = username, role = u.role })
end

function _M.handle_logout()
    local token = get_cookie(COOKIE)
    if token then
        sessions_dict:delete("sess:" .. token)
    end
    ngx.header.set_cookie = string.format("%s=; Path=/; HttpOnly; Max-Age=0", COOKIE)
    return json_exit(200, "OK", "ok")
end

-- ==================== 中间件 ====================

-- 返回 {username, role}；未登录返回 nil
function _M.get_session()
    local token = get_cookie(COOKIE)
    if not token or token == "" then return nil end
    local raw = sessions_dict:get("sess:" .. token)
    if not raw then return nil end
    local sess = cjson.decode(raw)
    if type(sess) ~= "table" or not sess.username then return nil end
    -- 活跃续期：重置 TTL，避免使用中被登出
    sessions_dict:safe_set("sess:" .. token, raw, SESSION_TTL)
    return sess
end

-- 未登录直接回 401 并结束请求；返回 session
function _M.require_login()
    local sess = _M.get_session()
    if not sess then
        json_exit(401, "E401", "not logged in")
        return nil
    end
    return sess
end

-- 非超管直接回 403 并结束请求；通过返回 true
function _M.require_admin(sess)
    if sess.role ~= "admin" then
        json_exit(403, "E403", "admin role required")
        return false
    end
    return true
end

function _M.handle_me()
    local sess = _M.get_session()
    if not sess then
        return json_exit(401, "E401", "not logged in")
    end
    return json_exit(200, "OK", "ok", sess)
end

-- ==================== 用户管理（仅 admin，路由层已拦截） ====================

local function valid_username(name)
    return type(name) == "string" and name:match("^[%w%.%-_]+$") and #name <= 64
end

local function valid_password(pw)
    return type(pw) == "string" and #pw >= 6 and #pw <= 128
end

function _M.handle_users_list()
    local users = load_users()
    local list = {}
    for name, u in pairs(users) do
        if valid_username(name) and type(u) == "table"
           and (u.role == "admin" or u.role == "viewer") then
            list[#list + 1] = { username = name, role = u.role }
        end
    end
    table.sort(list, function(a, b) return a.username < b.username end)
    return json_exit(200, "OK", "ok", list)
end

function _M.handle_users_add()
    local args = read_json_body()
    if not args then return json_exit(400, "E001", "empty or invalid body") end

    if not valid_username(args.username) then
        return json_exit(400, "E002", "invalid username (1-64 chars, letters/digits/._-)")
    end
    if not valid_password(args.password) then
        return json_exit(400, "E002", "invalid password (6-128 chars)")
    end
    if args.role ~= "admin" and args.role ~= "viewer" then
        return json_exit(400, "E002", "invalid role (admin/viewer)")
    end

    local username = args.username
    local users = load_users()
    if users[username] then
        return json_exit(400, "E101", "user already exists")
    end

    users[username] = { password = args.password, role = args.role }
    local err = save_users(users)
    if err then return json_exit(500, "E500", err) end
    ngx.log(ngx.NOTICE, "auth: user [", username, "] added, role=", args.role)
    return json_exit(200, "OK", "user added")
end

-- 修改密码（可选）与角色（可选）；密码字段不传或为空表示不改
function _M.handle_users_update()
    local args = read_json_body()
    if not args then return json_exit(400, "E001", "empty or invalid body") end

    local username = tostring(args.username or "")
    local users = load_users()
    local u = users[username]
    if not valid_username(username) or type(u) ~= "table" then
        return json_exit(404, "E102", "user not found")
    end

    local new_role = u.role
    if args.role ~= nil then
        if args.role ~= "admin" and args.role ~= "viewer" then
            return json_exit(400, "E002", "invalid role (admin/viewer)")
        end
        new_role = args.role
    end

    -- 不允许把系统里唯一的管理员降级为只读
    if new_role ~= "admin" and u.role == "admin" and count_admins(users) <= 1 then
        return json_exit(400, "E103", "cannot demote the last admin")
    end

    local pw_changed = false
    if args.password ~= nil and args.password ~= "" then
        if not valid_password(args.password) then
            return json_exit(400, "E002", "invalid password (6-128 chars)")
        end
        u.password = args.password
        pw_changed = true
    end
    u.role = new_role

    local err = save_users(users)
    if err then return json_exit(500, "E500", err) end

    -- 变更后踢下线，重新登录生效
    drop_sessions_of(username)
    ngx.log(ngx.NOTICE, "auth: user [", username, "] updated",
            pw_changed and " (password changed)" or "")
    return json_exit(200, "OK", "user updated")
end

function _M.handle_users_delete(sess)
    local args = read_json_body()
    if not args then return json_exit(400, "E001", "empty or invalid body") end

    local username = tostring(args.username or "")
    if sess.username == username then
        return json_exit(400, "E104", "cannot delete the current logged-in user")
    end

    local users = load_users()
    local u = users[username]
    if not valid_username(username) or type(u) ~= "table" then
        return json_exit(404, "E102", "user not found")
    end
    if u.role == "admin" and count_admins(users) <= 1 then
        return json_exit(400, "E105", "cannot delete the last admin")
    end

    users[username] = nil
    local err = save_users(users)
    if err then return json_exit(500, "E500", err) end

    drop_sessions_of(username)
    ngx.log(ngx.NOTICE, "auth: user [", username, "] deleted")
    return json_exit(200, "OK", "user deleted")
end

return _M
