local engine = require "zproto.c"

local zproto = {}


local function create(self)
        local t = {}
        setmetatable(t, {
                __index = self,
                __gc = function(table)
                        if t.proto then
                                engine.free(t.proto)
                        end
                end
        })

	t.protocache = {}
	setmetatable(t.protocache, {__mode = "v"})

        return t;
end

function zproto:load(path)
        local t = create(self)
        t.proto = engine.load(path)
        return t;
end

function zproto:parse(str)
        local t = create(self)
        t.proto = engine.parse(str)
        return t
end

local function query(self, typ)
        local record = self.protocache[typ]
        assert(self.proto)
        if not record then
                record = engine.query(self.proto, typ)
                self.protocache[typ] = record
        end

        return record
end

function zproto:encode(typ, protocol, packet)
        local record = query(self, typ)
        assert(record)
        assert(typ)
        assert(packet)
        return engine.encode(self.proto, record, protocol, packet)

end

function zproto:protocol(data, sz)
        return engine.protocol(data, sz)
end

function zproto:decode(typ, data, sz)
        local record = query(self, typ)
        return engine.decode(self.proto, record, data, sz)
end

return zproto

