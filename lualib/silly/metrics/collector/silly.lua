local silly = require "silly"
local c = require "silly.metrics.c"
local gauge = require "silly.metrics.gauge"
local counter = require "silly.metrics.counter"

local M = {}
M.__index = M

---@return silly.metrics.collector
function M.new()
	local silly_worker_backlog = gauge(
		"silly_worker_backlog",
		"Number of pending messages in worker queue."
	)
	local silly_timer_pending = gauge(
		"silly_timer_pending",
		"Number of pending timer events."
	)
	local silly_timer_scheduled_total = counter(
		"silly_timer_scheduled_total",
		"Total number of scheduled timer events."
	)
	local silly_timer_fired_total = counter(
		"silly_timer_fired_total",
		"Total number of timer events fired."
	)
	local silly_timer_canceled_total = counter(
		"silly_timer_canceled_total",
		"Total number of canceled timer events."
	)
	local silly_tasks_runnable = gauge(
		"silly_tasks_runnable",
		"Number of tasks in runnable state."
	)
	local silly_tcp_connections = gauge(
		"silly_tcp_connections",
		"Number of active TCP connections."
	)
	local silly_socket_requests_total = counter(
		"silly_socket_requests_total",
		"Total number of socket operation requests."
	)
	local silly_socket_processed_total = counter(
		"silly_socket_processed_total",
		"Total number of socket operations processed."
	)
	local silly_network_sent_bytes_total = counter(
		"silly_network_sent_bytes_total",
		"Total number of bytes sent via network."
	)
	local silly_network_received_bytes_total = counter(
		"silly_network_received_bytes_total",
		"Total number of bytes received via network."
	)
	local last_timer_scheduled = 0
	local last_timer_fired = 0
	local last_timer_canceled = 0
	local last_socket_request = 0
	local last_socket_processed = 0
	local last_sent_bytes = 0
	local last_received_bytes = 0

	---@param buf silly.metrics.metric[]
	local collect = function(_, buf)
		local worker_backlog = c.workerstat()
		local timer_pending, timer_scheduled, timer_fired, timer_canceled = c.timerstat()
		local task_runnable_size = silly.taskstat()
		local tcp_connections, sent_bytes, received_bytes,
			socket_operate_request, socket_operate_processed = c.netstat()

		silly_worker_backlog:set(worker_backlog)
		silly_timer_pending:set(timer_pending)
		silly_tasks_runnable:set(task_runnable_size)
		silly_tcp_connections:set(tcp_connections)
		if timer_scheduled > last_timer_scheduled then
			silly_timer_scheduled_total:add(timer_scheduled - last_timer_scheduled)
		end
		if timer_fired > last_timer_fired then
			silly_timer_fired_total:add(timer_fired - last_timer_fired)
		end
		if timer_canceled > last_timer_canceled then
			silly_timer_canceled_total:add(timer_canceled - last_timer_canceled)
		end
		if socket_operate_request > last_socket_request then
			silly_socket_requests_total:add(socket_operate_request - last_socket_request)
		end
		if socket_operate_processed > last_socket_processed then
			silly_socket_processed_total:add(socket_operate_processed - last_socket_processed)
		end
		if sent_bytes > last_sent_bytes then
			silly_network_sent_bytes_total:add(sent_bytes - last_sent_bytes)
		end
		if received_bytes > last_received_bytes then
			silly_network_received_bytes_total:add(received_bytes - last_received_bytes)
		end
		last_timer_scheduled = timer_scheduled
		last_timer_fired = timer_fired
		last_timer_canceled = timer_canceled
		last_socket_request = socket_operate_request
		last_socket_processed = socket_operate_processed
		last_sent_bytes = sent_bytes
		last_received_bytes = received_bytes

		local len = #buf
		buf[len+1] = silly_worker_backlog
		buf[len+2] = silly_timer_pending
		buf[len+3] = silly_timer_scheduled_total
		buf[len+4] = silly_timer_fired_total
		buf[len+5] = silly_timer_canceled_total
		buf[len+6] = silly_tasks_runnable
		buf[len+7] = silly_tcp_connections
		buf[len+8] = silly_socket_requests_total
		buf[len+9] = silly_socket_processed_total
		buf[len+10] = silly_network_sent_bytes_total
		buf[len+11] = silly_network_received_bytes_total
	end
	local c = {
		name = "Silly",
		new = M.new,
		collect = collect,
	}
	return c
end

return M

