return [[
	worker {
		.epoch:integer		1
		.type:string		2
		.status:string		3
		.listen:string		4
		.slot:integer		5
	}
	join_r 0x0001 {
		.self:worker		1
		.workers:worker[]	2
	}
	join_a 0x0002 {
		.result:integer		1
		.status:string		2
		.epoch:integer		3
		.slot:integer		4
		.mepoch:integer		5
		.capacity:integer	6
	}
	heartbeat_r 0x0003 {
	}
	heartbeat_a 0x0004 {
		.mepoch:integer	1
	}
	cluster_r 0x0005 {
		.workers:worker[]	1
	}
	cluster_a 0x0006 {

	}
	status_r 0x0007 {
	}
	status_a 0x0008 {
		.pid:integer 1
		.cpu_sys:string 2
		.cpu_user:string 3
		.memory_used:long 4
		.memory_rss:long 5
		.memory_allocator:string 6
		.version:string 7
		.multiplexing_api:string 8
		.uptime_in_seconds:integer 9
		.message_pending:integer 10
		.timer_resolution:integer 11
	}
]]

