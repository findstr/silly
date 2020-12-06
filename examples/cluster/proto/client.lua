local proto
do
	local zproto = require "zproto"
	local l = {
		"client.zproto"
	}
	local buf = {}
	local open = io.open
	local prefix= "examples/cluster/proto/"
	for _, name in ipairs(l) do
		local p = prefix .. name
		local f = io.open(p, "r")
		buf[#buf + 1] = f:read("a")
		f:close()
	end
	proto = table.concat(buf, "\n")
end
return proto

