local tcp = require "silly.net.tcp"
local json = require "silly.encoding.json"
local testaux = require "test.testaux"

local conformance = {}

local CONTROL_HOST = "127.0.0.1"
local CONTROL_PORT = 9090
local next_id = 0

local function send_command(conn, cmd, params)
	next_id = next_id + 1
	local msg = json.encode({id = next_id, cmd = cmd, params = params or {}})
	conn:write(msg .. "\n")
	local line, err = conn:read("\n")
	if not line then
		return nil, "control protocol error: " .. (err or "connection closed")
	end
	local resp = json.decode(line)
	if not resp then
		return nil, "control protocol error: invalid JSON"
	end
	if resp.error then
		return nil, resp.error
	end
	return resp.result
end

function conformance.connect(host, port)
	local addr = (host or CONTROL_HOST) .. ":" .. (port or CONTROL_PORT)
	local conn, err = tcp.connect(addr)
	testaux.assertneq(conn, nil, "conformance: connect to Go process at " .. addr)
	testaux.asserteq(err, nil, "conformance: connect to Go process at " .. addr)
	assert(conn)
	return setmetatable({conn = conn}, {__index = conformance})
end

function conformance:start_server(handler, params)
	params = params or {}
	params.handler = handler
	local result, err = send_command(self.conn, "start_server", params)
	if not result then
		return nil, err
	end
	return result
end

function conformance:stop_server(server_id)
	return send_command(self.conn, "stop_server", {server_id = server_id})
end

function conformance:http_request(method, url, opts)
	opts = opts or {}
	local params = {
		method = method,
		url = url,
		headers = opts.headers,
		body = opts.body,
		response_timeout_ms = opts.timeout or 10000,
		disable_keep_alives = opts.disable_keep_alives,
	}
	return send_command(self.conn, "http_request", params)
end

function conformance:http_request_pair(first_url, second_url, opts)
	opts = opts or {}
	local params = {
		first = {
			method = opts.first_method or "GET",
			url = first_url,
		},
		second = {
			method = opts.second_method or "GET",
			url = second_url,
		},
		response_timeout_ms = opts.timeout or 10000,
		disable_keep_alives = opts.disable_keep_alives,
	}
	return send_command(self.conn, "http_request_pair", params)
end

function conformance:shutdown()
	send_command(self.conn, "shutdown")
	self.conn:close()
	self.conn = nil
end

function conformance:close()
	if self.conn then
		self.conn:close()
		self.conn = nil
	end
end

return conformance
