local silly = require "silly"
local env = require "silly.env"
local metrics = require "silly.metrics.c"
local tcp = require "silly.net.tcp"

local rounds = tonumber(env.get("rounds")) or 2000
local checks = 0
local snapshots = 0

local function listen()
	local listener, err = tcp.listen {
		addr = "127.0.0.1:0",
		accept = function(conn)
			conn:close()
		end,
	}
	assert(listener, tostring(err))
	return listener
end

for _ = 1, rounds do
	local listener = listen()
	local sid = listener.fd
	local baseline = metrics.socketstat(sid)
	assert(baseline.fd == sid)
	assert(baseline.type == "LISTEN")
	assert(baseline.protocol == "TCP")
	assert(baseline.localaddr ~= "")
	assert(listener:close())

	for _ = 1, 8 do
		local info = metrics.socketstat(sid)
		checks = checks + 1
		if info.fd == sid then
			snapshots = snapshots + 1
			assert(info.type == "LISTEN")
			assert(info.protocol == "TCP")
			assert(info.localaddr == baseline.localaddr)
		end
	end
end

print(string.format("socket_stat close race: rounds=%d checks=%d snapshots=%d",
	rounds, checks, snapshots))
silly.exit(0)
