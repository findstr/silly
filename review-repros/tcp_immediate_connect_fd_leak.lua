-- Reproducer for an fd leak when nonblocking connect fails before sp_add.
-- Run from the Silly repository with a TEST=ON build:
--   ./silly ../review-repros/tcp_immediate_connect_fd_leak.lua

local silly = require "silly"
local tcp = require "silly.net.tcp"
local metrics = require "silly.metrics.c"
local time = require "silly.time"

local before = metrics.openfds()
local attempts = 8

for _ = 1, attempts do
	-- Connecting a TCP socket to the IPv4 limited broadcast address is
	-- rejected immediately (ENETUNREACH/EACCES), before the fd enters epoll.
	local conn = tcp.connect("255.255.255.255:9", { timeout = 1000 })
	assert(conn == nil)
end

time.sleep(20)
local after = metrics.openfds()
print(string.format("open fds: before=%d after=%d delta=%d", before, after,
	after - before))

silly.exit(after - before == attempts and 0 or 2)
