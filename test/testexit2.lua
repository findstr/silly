-- testexit2: Reproduce shutdown BUG where __gc on pending UDP connection
-- triggers "BUG: wakeup on task stat:nil" during lua_close.
--
-- Flow:
-- 1. Coroutine blocks on conn:recvfrom() (sets s.co = running())
-- 2. Timer fires silly.exit(0)
-- 3. task._exit clears task_status, then engine shuts down
-- 4. worker_exit → lua_close → GC → conn.__gc → conn.close → wakeup(co)
-- 5. wakeup sees task_status[co] == nil → error

local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local udp = require "silly.net.udp"

local conn = assert(udp.bind("127.0.0.1:18999"))


time.after(100, function()
	silly.exit(0)
end)

conn:recvfrom()
