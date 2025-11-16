local tcp = require "silly.net.tcp"
local tls = require "silly.net.tls"
local h2 = require "silly.net.http.h2"
local code = require "silly.net.grpc.code"

local ALPN_PROTOS<const> = {"h2"}

local function dispatch(registrar)
	local handlers = registrar.handlers
	---@param stream silly.net.http.h2.stream
	return function(stream)
		local path = stream.header[':path']
		local fn = handlers[path]
		if not fn then
			stream:respond(200, {
				['content-type'] = 'application/grpc',
				['grpc-status'] = code.Unimplemented,
				['grpc-message'] = "grpc: method not found"
			})
			return
		end
		stream:respond(200, {
			['content-type'] = 'application/grpc',
		})
		fn(stream)
	end
end


---@param conf {
---	tls:boolean?,
---	addr:string,
---	ciphers:string?,
---	registrar:silly.net.grpc.registrar,
---	certs:{cert:string, cert_key:string}[],
---}
---@return silly.net.tcp.listener|silly.net.tls.listener|nil, string? error
local function listen(conf)
	local handler = dispatch(conf.registrar)
	local accept = function(conn)
		h2.httpd(handler, conn)
	end
	if not conf.tls then
		return tcp.listen {
			addr = conf.addr,
			accept = accept
		}
	else
		return tls.listen {
			addr = conf.addr,
			certs = conf.certs,
			alpnprotos = ALPN_PROTOS,
			accept = accept,
		}
	end
end

return listen