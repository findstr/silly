local code = require "silly.net.grpc.code"
local pb = require "pb"

local M = {}

local HDR_SIZE<const> = 5
local REQ_MAX_LEN<const> = 4*1024*1024

local assert = assert
local pack = string.pack
local unpack = string.unpack

---@param h2stream silly.net.http.h2.stream
---@param isreq boolean
---@param pbtype string
---@return table?, string? error
function M.readbody(h2stream, isreq, pbtype)
	--read header
	local data, err = h2stream:read(HDR_SIZE)
	if err then
		return nil, err
	end
	local compress, frame_size = unpack(">I1I4", data)
	-- TODO:
	assert(compress == 0, "grpc: compression not supported")
	if isreq and frame_size > REQ_MAX_LEN then
		h2stream:respond(200, {
			['content-type'] = 'application/grpc',
			['grpc-status'] = code.ResourceExhausted,
		})
		return nil, "grpc: received message larger than max"
	end
	data, err = h2stream:read(frame_size)
	if err then
		return nil, err
	end
	local resp = pb.decode(pbtype, data)
	if not resp then
		return nil, "decode error"
	end
	return resp, nil
end

local NIL<const> = {}

---@param h2stream silly.net.http.h2.stream
---@param pbtype string
---@param obj table
---@param close boolean
---@return boolean, string? error
function M.writebody(h2stream, pbtype, obj, close)
	local dat = pb.encode(pbtype, obj or NIL)
	local body = pack(">I1I4", 0, #dat) .. dat
	if not close then
		return h2stream:write(body)
	end
	return h2stream:closewrite(body)
end

return M