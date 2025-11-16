local tcp = require "silly.net.tcp"
local tls = require "silly.net.tls"
local h1 = require "silly.net.http.h1"
local h2 = require "silly.net.http.h2"
local client = require "silly.net.http.client"

local httpc = client.new()

local M = {}

---@class silly.net.http.transport.listen.conf
---@field handler fun(s:silly.net.http.h1.stream.client|silly.net.http.h2.stream)
---@field addr string
---@field tls boolean?
---@field certs table<number, {
---		cert:string,
---		cert_key:string,
---	}>?,
---@field alpnprotos string[]?
---}

---@param conf silly.net.http.transport.listen.conf
---@return silly.net.tcp.listener|silly.net.tls.listener|nil, string?
function M.listen(conf)
	local accept = function(conn)
		local alpnproto = conn.alpnproto
		if alpnproto and alpnproto(conn) == "h2" then
			h2.httpd(conf.handler, conn)
		else
			local scheme = conf.tls and "https" or "http"
			h1.httpd(conf.handler, conn, scheme)
		end
	end
	local addr = conf.addr
	if not conf.tls then
		return tcp.listen {
			addr = addr,
			accept = accept
		}
	else
		return tls.listen {
			addr = addr,
			certs = conf.certs,
			alpnprotos = conf.alpnprotos,
			accept = accept,
		}
	end
end

function M.newclient(conf)
	return httpc.new(conf)
end

function M.get(url, header)
	return httpc:get(url, header)
end

function M.post(url, header, body)
	return httpc:post(url, header, body)
end

return M

