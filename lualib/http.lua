local helper = require "http.helper"
local stream = require "http.stream"
local tcp = require "sys.net.tcp"
local tls = require "sys.tls"
local parseurl = helper.parseurl

local M = {}

function M.listen(conf)
	local fd
	local handler = conf.handler
	local port = conf.port or conf.addr
	if not conf.tls then
		fd = tcp.listen(port, stream.httpd("http", handler))
	else
		fd = tls.listen {
			disp = stream.httpd("https", handler),
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
	local stream, err = stream.connect(scheme, host, port, alpn_protos)
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
		return nil, err
	end
	return stream, nil
end

function M.GET(url, header)
	local stream, err = M.request("GET", url, header, true, alpn_protos)
	if not stream then
		return nil, err
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

function M.POST(url, header, body)
	if body then
		header = header or {}
		header["content-length"] = #body
	end
	local stream, err = M.request("POST", url, header, false, alpn_protos)
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
	if version ~= "HTTP/2" then
		stream:close()
	end
	return {
		status = status,
		header = header,
		body = body,
	}
end

return M

