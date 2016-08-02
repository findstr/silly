local core = require "silly.core"
local ns = require "netstream"
local env = require "silly.env"

local nb_pool = {}
local socket_pool = {}

local socket = {}

local EVENT = {}

local function new_socket(fd)
        local s = {
                fd = fd,
                delim = false,
                suspend = false,
                co = false,
                limit = 8192,
        }
        assert(socket_pool[fd] == nil, 
                "new_socket incorrect" .. fd .. "not be closed")
        socket_pool[fd] = s
end

function EVENT.accept(fd, _, portid, addr)
        local lc = socket_pool[portid];
        new_socket(fd)
        local ok, err = core.pcall(lc, fd, addr)
        if not ok then
                print(err)
                socket.close(fd)
        end
end

function EVENT.close(fd, _, errno)
        local s = socket_pool[fd]
        if s == nil then
                return
        end
        if s.sbuffer then
                ns.clear(nb_pool, s.sbuffer)
        end
        if s.co then
                local co = s.co
                s.co = false
                core.wakeup(co, false)
        end
        socket_pool[fd] = nil
end

function EVENT.data(fd, message)
        local s = socket_pool[fd]
        s.sbuffer = ns.push(nb_pool, s.sbuffer, message)
        if not s.delim then     --non suspend read
                assert(not s.co)
                return 
        end
                
        if type(s.delim) == "number" then
                assert(s.co)
                if ns.check(s.sbuffer) >= s.delim then
                        local co = s.co
                        s.co = false
                        s.delim = false
                        core.wakeup(co, true)
                end
        elseif type(s.delim) == "string" then
                assert(s.co)
                if ns.checkline(s.sbuffer, s.delim) then
                        local co = s.co
                        s.co = false
                        s.delim = false
                        core.wakeup(co, true)
                end
        end
end

local function socket_dispatch(type, fd, message, ...)
        assert(EVENT[type])(fd, message, ...)
end

function socket.listen(port, config)
        assert(port)
        assert(config)
        local portid = core.listen(port, socket_dispatch)
        if not portid then
                return false
        end
        socket_pool[portid] = config
        return true
end

function socket.connect(ip, bind)
        local fd = core.connect(ip, socket_dispatch, bind)
        if fd < 0 then
                return fd
        end
        new_socket(fd)
        return fd
end

function socket.limit(fd, limit)
        local s = socket_pool[fd]
        if s == nil then
                return false
        end
        s.limit = limit
end

function socket.close(fd)
        local s = socket_pool[fd]
        if s == nil then
                return
        end
        if s.so then
                core.wakeup(s.so, false)
        end
        ns.clear(nb_pool, s.sbuffer)
        socket_pool[fd] = nil
        core.close(fd)
end

local function suspend(s)
        assert(not s.co)
        s.co = core.running()
        return core.wait()
end


function socket.read(fd, n)
        local s = socket_pool[fd]
        if not s then
                return nil
        end
        if n <= 0 then
                return ""
        end
        local r = ns.read(nb_pool, s.sbuffer, n)
        if r then
                return r
        end
        s.delim = n
        local ok = suspend(s)
        if ok == false then     --occurs error
                return nil
        end
        local r = ns.read(nb_pool, s.sbuffer, n)
        assert(r)
        return r;
end

function socket.readall(fd)
        local s = socket_pool[fd]
        if not s then
                return nil
        end
        local n = ns.check(s.sbuffer);
        if n == 0 then
                return ""
        end
        local r = ns.read(nb_pool, s.sbuffer, n)
        assert(r)
        return r;
end

function socket.readline(fd, delim)
        delim = delim or "\n"
        local s = socket_pool[fd]
        if not s then
                return nil
        end
        local r = ns.readline(nb_pool, s.sbuffer, delim)
        if r then
                return r
        end

        s.delim = delim
        local ok = suspend(s)
        if ok == false then     --occurs error
                return nil
        end

        local r = ns.readline(nb_pool, s.sbuffer, delim)
        assert(r)
        return r
end

function socket.write(fd, str)
        local s = socket_pool[fd]
        if not s then
                return false
        end
        if #str > s.limit then
                return false, "socket send size is limited:" .. s.limit
        end
        local p, sz = ns.pack(str)
        return core.write(fd, p, sz)
end

return socket


