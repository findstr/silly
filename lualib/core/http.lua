local helper = require "core.http.helper"
local transport = require "core.http.transport"
local tcp = require "core.net.tcp"
local tls = require "core.net.tls"
local h1 = require "core.http.h1stream"
local h2 = require "core.http.h2stream"
local parseurl = helper.parseurl

local M = {}

function M.listen(conf)
	local fd
	local handler = conf.handler
	local port = conf.port or conf.addr
	if not conf.tls then
		fd = tcp.listen(port, transport.httpd("http", handler))
	else
		fd = tls.listen {
			disp = transport.httpd("https", handler),
			port = port,
			certs = conf.certs,
			alpnprotos = conf.alpnprotos,
		}
	end
	return fd
end
local alpn_protos = {"h2"}

function M.request(method, url, header, close, alpn_protos)
	local scheme, host, port, path = parseurl(url)
	local socket, err = transport.connect(scheme, host, port, alpn_protos)
	if not socket then
		return nil, err
	end
	local new = (socket:alpnproto() == "h2") and h2.new or h1.new
	local stream, err = new(scheme, socket)
	if not stream then
		return nil, err
	end
	local ok, err
	header = header or {}
	if stream.version == "HTTP/2" then
		header[":authority"] = host
		ok, err = stream:request(method, path, header, close)
	else
		header["host"] = host
		ok, err = stream:request(method, path, header)
	end
	if not ok then
		stream:close()
		return nil, err
	end
	return stream, nil
end
function M.GET(url, header)
	local stream<close>, err = M.request("GET", url, header, true, alpn_protos)
	if not stream then
		return nil, err
	end
	local status, header = stream:readheader()
	if not status then
		print(status, header)
		return nil, header
	end
	local body = stream:readall()
	return {
		status = status,
		header = header,
		body = body,
	}
end

function M.POST(url, header, body)
	if body then
		header = header or {}
		header["content-length"] = #body
	end
	local stream<close>, err = M.request("POST", url, header, false, alpn_protos)
	if not stream then
		return nil, err
	end
	local version = stream.version
	if version == "HTTP/2" then
		stream:close(body)
	else
		stream:write(body)
	end
	local status, header = stream:readheader()
	if not status then
		return nil, header
	end
	local body = stream:readall()
	return {
		status = status,
		header = header,
		body = body,
	}
end

return M

