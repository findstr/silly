local core = require "silly.core"
local np = require "netpacket"
local proto = require "sampleproto"
local M = {}

function M.decode(proto, d, sz)
	local str = core.tostring(d, sz)
	np.drop(d)
	local len = #str
	assert(len >= 4)
	local data
	local cmd = string.unpack("<I4", str)
	if (len > 4) then
		data = proto:decode(cmd, str, 4)
	else
		data = NIL
	end
	return cmd, data
end

function M.encode(proto, cmd, body)
	if type(cmd) == "string" then
		cmd = proto:querytag(cmd)
	end
	local cmddat = string.pack("<I4", cmd)
	local bodydat = proto:encode(cmd, body)
	return cmddat .. bodydat
end

return M

