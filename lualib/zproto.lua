local engine = require "zproto.c"

local zproto = {}

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
		pcache = {}, -- name cache
		nametag = {}, -- name tag cache
		proto = proto,
	}
	setmetatable(t, indexmt)
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

local equery = engine.query
local function query(self, typ)
	local pcache = self.pcache
	local proto = pcache[typ]
	if proto then
		return proto
	end
	local proto, tag, name = equery(self.proto, typ)
	if proto then
		local nametag = self.nametag
		pcache[tag] = proto
		pcache[name] = proto
		nametag[name] = tag
		nametag[tag] = name
	end
	return proto
end

local encode = engine.encode
function zproto:encode(typ, packet, raw)
	return encode(query(self, typ), packet, raw)
end

function zproto:tag(typ)
	local nametag = self.nametag
	local tag = nametag[typ]
	if not tag then
		query(self, typ)
		tag = nametag[typ]
	end
	return tag
end

local decode = engine.decode
function zproto:decode(typ, data, sz)
	return decode(query(self, typ), data, sz)
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

local pack = engine.pack
function zproto:pack(data, sz, raw)
	return pack(data, sz, raw)
end

local unpack = engine.unpack
function zproto:unpack(data, sz, raw)
	return unpack(data, sz, raw);
end

return zproto

