local pb     = require "pb"
local stream = require "http2.stream"
local proto = require "etcd.proto"

local match = string.match
local pack = string.pack
local setmetatable = setmetatable

local M = {}
local mt = {__index = M}

function M:new(conf)
	local cli = {
		roundrobin = 0

	}
	local endpoints = conf.endpoints
	for i = 1, #endpoints do
		local host, port = match(endpoints[i], "([^:]+):(%d+)")
		local s, err = stream.connect("http", host, port)
		assert(s, err)
		cli[i] = s
	end
	setmetatable(cli, mt)
	return cli
end

function M:balance()
	local r = self.roundrobin + 1
	if r == #self then
		self.roundrobin = 0
	end
	return self[r]
end

function M:put(k, v)
	local req = {
		key = k,
		value = v,
	}
	local body = pb.encode("etcdserverpb.PutRequest", req)
	local hdr = string.pack(">I4", #body)
	local s = self:balance()
	local header = {
		['content-type'] = "application/grpc"
	}
	local ok, err = s:req("POST", "/etcdserverpb.KV/Put", header, false)
	if not ok then
		return nil, err
	end
	local hdr = pack(">I1I4", 0, #body)
	s:write(hdr .. body)
	local header, err = s:read()
	print("recv 0", header, err)
	if not header then
		return nil, err
	end
	local status = tonumber(header[':status'])
	print("status", status)
	local body = s:read()
	print("recv", #body)
end


return M
