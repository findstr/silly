-- Test endless loop detection (monitor thread sends SIGUSR2)
-- This test runs a tight loop for >1 second to trigger the monitor.
-- Run separately: ./silly test/testendless.lua
-- Expected output should contain "endless loop" warning

local time = require "silly.time"
local silly = require "silly"

local start = time.now()
local count = 0

-- Run a tight loop for ~1.2 seconds to trigger monitor (checks every 1s)
while time.now() - start < 1200 do
	count = count + 1
end

print("loop finished, count:", count)
silly.exit(0)
