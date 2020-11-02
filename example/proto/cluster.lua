local str = require "proto.client"
do
	local tag = 0
	local buf = {}
	for l in string.gmatch(str, "([^\n]+)\n") do
		if l:find("{%s*$") then
			buf[#buf + 1] = l
		elseif l:find("^}") then
			buf[#buf + 1] = "\t.uid_:uinteger " .. (tag + 1)
			buf[#buf + 1] = l
			tag = 0
		else
			if l:find("^%s*%.") then
				tag = tonumber(l:match("%s+(%d+)%s*"))
			end
			buf[#buf + 1] = l
		end
	end
	str = table.concat(buf, "\n")
	local prefix= "example/proto/"
	local f = io.open(prefix.."cluster.zproto")
	str = str .. f:read("a")
	f:close()
end
return str

