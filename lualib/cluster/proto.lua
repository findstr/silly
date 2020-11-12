return [[
	worker {
		.id:integer		1
		.type:string		2
		.status:string		3
		.listen:string		4
		.slotid:integer		5
	}
	join_r 0x0001 {
		.self:worker		1
		.workers:worker[]	2
	}
	join_a 0x0002 {
		.result:integer		1
		.status:string		2
		.id:integer		3
		.slotid:integer		4
		.masterid:integer	5
		.capacity:integer	6
	}
	heartbeat_r 0x0003 {
	}
	heartbeat_a 0x0004 {
		.masterid:integer	1
	}
	cluster_r 0x0005 {
		.workers:worker[]	1
	}
	cluster_a 0x0006 {

	}
]]

