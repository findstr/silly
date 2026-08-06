-- Deterministic reproducer for CAND-SOCK-001.
-- Run from the Silly repository with a TEST=ON build:
--   ./silly ../review-repros/socket_exit_pending_wlist.lua

local silly = require "silly"
local tcp = require "silly.net.tcp"
local time = require "silly.time"
local test = require "test.aux.c"

local host = "127.0.0.1"
local port = 23111
local peer

assert(tcp.listen {
	addr = host .. ":" .. port,
	accept = function(conn)
		-- Keep all sends in the operation buffer, and force any shutdown
		-- flush to consume at most one byte from the first batch.
		test.debugctrl("socket.conf", {
			defer_trigger = true,
			sendv_cap = 1,
		})

		local chunk = string.rep("x", 4096)
		for _ = 1, 8 do
			assert(conn:write(chunk))
		end

		-- Re-enable automatic triggering without removing sendv_cap. Kick
		-- once, then exit. Whether the socket thread flips before or after
		-- OP_EXIT is appended, pending wlist nodes must be owned and freed.
		test.debugctrl("socket.conf", {
			defer_trigger = false,
			sendv_cap = 1,
		})
		test.debugctrl("socket.kick")
		silly.exit(0)
	end,
})

peer = assert(test.connect(host, port))

-- The accept callback exits the runtime. This only keeps the root task alive
-- until that callback is dispatched.
while peer do
	time.sleep(1000)
end
