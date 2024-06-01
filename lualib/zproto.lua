local engine = require "zproto.c"

local zproto = {}

local cachemt = {__mode = "kv"}
local indexmt = {
	__index = zproto,
	__gc = function(table)
		if table.proto then
			engine.free(table.proto)
		end
	end
}



local function create(proto)
	local t = {
		ncache = {}, -- name cache
		tcache = {}, -- tag cache
		nametag = {}, -- name tag cache
		proto = proto,
	}
	setmetatable(t, indexmt)
	setmetatable(t.ncache, cachemt)
	setmetatable(t.tcache, cachemt)
	setmetatable(t.nametag, cachemt)
	return t;
end

function zproto:load(path)
	local proto, err = engine.load(path)
	if not proto then
		return nil, err
	end
	return create(proto)
end

function zproto:parse(str)
	local proto, err = engine.parse(str)
	if not proto then
		return nil, err
	end
	return create(proto)
end

local function query(self, typ)
	local itype
	local proto
	if type(typ) == "number" then
		itype = true
		proto = self.tcache[typ]
	elseif type(typ) == "string" then
		itype = false
		proto = self.ncache[typ]
	else
		assert(false, "typ must be 'number' or 'string'")
	end
	if proto then
		return proto
	end
	local proto, tag = engine.query(self.proto, typ)
	if itype then
		self.tcache[typ] = proto
	else
		self.ncache[typ] = proto
		self.nametag[typ] = tag
	end
	return proto
end

function zproto:encode(typ, packet, raw)
	return engine.encode(query(self, typ), packet, raw)
end

function zproto:tag(typ)
	local tag = self.nametag[typ]
	if not tag then
		query(self, typ)
		tag = self.nametag[typ]
	end
	return tag
end

function zproto:decode(typ, data, sz)
	return engine.decode(query(self, typ), data, sz)
end

function zproto:default(typ)
	return engine.default(query(self, typ))
end

function zproto:travel(mod, typ)
	if typ then
		return engine.travel(self.proto, mod, query(self, typ))
	else
		return engine.travel(self.proto, mod, nil)
	end
end

function zproto:pack(data, sz, raw)
	return engine.pack(data, sz, raw)
end

function zproto:unpack(data, sz, raw)
	return engine.unpack(data, sz, raw);
end

return zproto

