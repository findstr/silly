local core = require "silly.core"
local ns = require "netstream"

local nb_pool = {}
local socket_pool = {}

local socket = {}

local EVENT = {}

function EVENT.close(_, fd, _, _)
        local s = socket_pool[fd]
        if s == nil then
                return
        end
        ns.clear(s.sbuffer)
        if s.co then
                local co = s.co
                s.co = false
                core.resume(co, false)
        end
        socket_pool[fd] = nil
end

function EVENT.data(_, fd, _, message)
        local s = socket_pool[fd]
        s.sbuffer = ns.push(nb_pool, s.sbuffer, message)
        if not s.delim then     --non suspend read
                assert(not s.co)
                return 
        end
                
        if type(s.delim) == "number" then
                assert(s.co)
                if ns.check(s.sbuffer, s.delim) then
                        local co = s.co
                        s.co = false
                        s.delim = false
                        core.resume(co, true)
                end
        elseif type(s.delim) == "string" then
                assert(s.co)
                if ns.checkline(s.sbuffer, s.delim) then
                        local co = s.co
                        s.co = false
                        s.delim = false
                        core.resume(co, true)
                end
        end
end

local function socket_dispatch(type, fd, _, message)
        local s = assert(socket_pool[fd])
        assert(type ~= "accept")
        assert(EVENT[type])(type, fd, _, message)
end


function socket.connect(ip, port)
        local fd = core.connect(ip, port, socket_dispatch)
        if fd < 0 then
                return fd
        end

        s = {
                fd = fd,
                delim = false,
                suspend = false,
                co = false,
        }

        socket_pool[fd] = s
        return fd
end

function socket.close(fd)
        local s = socket_pool[fd]
        assert(s)
        assert(not s.co)

        ns.clear(nb_pool, s.sbuffer)
        socket_pool[fd] = nil

        core.close(fd)
end

function socket.closed(fd)
        local s = socket_pool[fd]
        if s then
                return true
        else
                return false
        end
end

local function suspend(s)
        assert(not s.co)
        s.co = core.running()
        return core.yield()
end


function socket.read(fd, n)
        local s = socket_pool[fd]
        assert(s)
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

function socket.readline(fd, delim)
        delim = delim or "\n"
        local s = socket_pool[fd]
        assert(s)
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
        local p, sz = ns.pack(str)
        core.write(fd, p, sz)
end

return socket


