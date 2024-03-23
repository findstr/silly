local core = require "core"
local c = require "core.metrics.c"
local gauge = require "core.metrics.gauge"
local setmetatable = setmetatable

local M = {}
M.__index = M

function M:new()
	local worker_queue = gauge(
		"core_worker_queue",
		"Total number of pending message size in worker queue."
	)
	local timer_active = gauge(
		"core_timer_active",
		"Total number of pending timer event."
	)
	local timer_expired = gauge(
		"core_timer_expired",
		"Total number of timer event issued."
	)
	local task_pool = gauge(
		"core_task_pool",
		"Total number of task pool size."
	)
	local task_ready = gauge(
		"core_task_runnable",
		"Total number of task in runnable stat."
	)
	local tcp_connecting = gauge(
		"core_tcp_connecting",
		"Total number of tcp connecting socket."
	)
	local tcp_client = gauge(
		"core_tcp_client",
		"Total number of tcp client."
	)
	local socket_queue = gauge(
		"core_socket_queue",
		"Total number of pending message size in socket queue."
	)
	local socket_send = gauge(
		"core_socket_send",
		"Total number of bytes sended via socket."
	)
	local socket_recv = gauge(
		"core_socket_recv",
		"Total number of byted received via socket."
	)

	local collect = function(_, buf, len)
		local worker_queue_size = c.workerstat()
		local timer_active_size, timer_expired_size = c.timerstat()
		local task_pool_size, task_ready_size = core.taskstat()
		local tcp_connecting_count,
			tcp_client_count,
			socket_queue_size,
			socket_send_size,
			socket_recv_size = c.netstat()

		worker_queue:set(worker_queue_size)
		timer_active:set(timer_active_size)
		timer_expired:set(timer_expired_size)
		task_pool:set(task_pool_size)
		task_ready:set(task_ready_size)
		tcp_connecting:set(tcp_connecting_count)
		tcp_client:set(tcp_client_count)
		socket_queue:set(socket_queue_size)
		socket_send:set(socket_send_size)
		socket_recv:set(socket_recv_size)

		buf[len + 1] = worker_queue
		buf[len + 2] = timer_active
		buf[len + 3] = timer_expired
		buf[len + 4] = task_pool
		buf[len + 5] = task_ready
		buf[len + 6] = tcp_connecting
		buf[len + 7] = tcp_client
		buf[len + 8] = socket_queue
		buf[len + 9] = socket_send
		buf[len + 10] = socket_recv

		return len + 10
	end
	local c = {
		name = "Core",
		new = M.new,
		collect = collect,
	}
	return c
end

return M

