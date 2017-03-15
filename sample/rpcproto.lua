local zproto = require "zproto"

local proto = zproto:parse [[

rrpc_sum 0x2001 {
	.val1:integer 1
	.val2:integer 2
	.suffix:string 3
}

arpc_sum 0x2002 {
	.val:integer 1
	.suffix:string 2
}

]]

return proto

