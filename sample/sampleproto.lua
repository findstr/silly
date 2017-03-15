local zproto = require "zproto"

local proto = zproto:parse [[

r_hello 0x1001 {
	.val:string 1
}

a_hello 0x1002 {
	.val:string 1
}

r_sum 0x1003 {
	.val1:integer 1
	.val2:integer 2
	.suffix:string 3
}

a_sum 0x1004 {
	.val:integer 1
	.suffix:string 2
}

]]

return proto

