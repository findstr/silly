local core = require "silly.core"
local mysql = require "mysql"

return function()
	local db = mysql.create {
		host="192.168.2.118@3306",
		user="root",
		password="root",
	}
	db:connect()
	local status, res = db:query("show databases;")
	print("query databases:", status, res)
	for _, v in pairs(res) do
		print(v.Database)
	end
	print("test ok")
end

