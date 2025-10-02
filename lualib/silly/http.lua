local helper = require "silly.http.helper"
local transport = require "silly.http.transport"
local parseurl = helper.parseurl
local setmetatable = setmetatable

local alpn_protos = {"http/1.1", "h2"}

local M = {}

---@class silly.http.server_mt
local server = {
	close = function(self)
		local fd = self.fd
		if fd then
			self.transport.close(fd)
			self.fd = nil
		end
	end
}

local server_mt = {
	__index = server,
}

local listen = transport.listen
---@param conf silly.http.transport.listen.conf
---@return silly.http.server?, string? error
function M.listen(conf)
	local fd, transport = listen(conf)
	if not fd then
		return nil, transport
	end
	---@class silly.http.server:silly.http.server_mt
	local server = {
		fd = fd,
		transport = transport,
	}
	return setmetatable(server, server_mt), nil
end


---@param method string
---@param url string
---@param header table<string, string|number>?
---@param close boolean?
---@param alpn_protos silly.net.tls.alpn_proto[]?
---@return silly.http.h2stream|silly.http.h1stream|nil, string?
function M.request(method, url, header, close, alpn_protos)
	local scheme, host, port, path = parseurl(url)
	local stream, err = transport.connect(scheme, host, port, alpn_protos)
	if not stream then
		return nil, err
	end
	header = header or {}
	header["host"] = host
	local ok, err = stream:request(method, path, header, close)
	if not ok then
		stream:close()
		return nil, err
	end
	return stream, nil
end

local request = M.request

function M.GET(url, header)
	local stream<close>, err = request("GET", url, header, true, alpn_protos)
	if not stream then
		return nil, err
	end
	local status, header = stream:readheader()
	if not status then
		return nil, header
	end
	local body, err = stream:readall()
	if not body then
		return nil, err
	end
	return {
		status = status,
		header = header,
		body = body,
	}, nil
end

function M.POST(url, header, body)
	if body then
		header = header or {}
		header["content-length"] = #body
	end
	local stream<close>, err = request("POST", url, header, false, alpn_protos)
	if not stream then
		return nil, err
	end
	if stream.version == "HTTP/2" then
		stream:close(body)
	else
		stream:write(body)
	end
	local status, header = stream:readheader()
	if not status then
		return nil, header
	end
	local body, err = stream:readall()
	if not body then
		return nil, err
	end
	return {
		status = status,
		header = header,
		body = body,
	}, nil
end

return M

