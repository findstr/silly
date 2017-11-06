local core = require "sys.core"
local P = {}

function P.hex(str)
	local tbl = {}
	for i = 1, #str do
		tbl[#tbl + 1] = string.format("%02x", str:byte(i))
	end
	print(table.concat(tbl, " "))
end

function P.print_r(tbl)
	for k, v in pairs(tbl) do
		print("key:", k)
		if type(v) == "table" then
			P.print_r(v)
		else
			print(v)
		end
	end
end

return P

