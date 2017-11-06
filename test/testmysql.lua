local core = require "sys.core"
local mysql = require "sys.db.mysql"

return function()
	local db = mysql.create {
		host="127.0.0.1@3306",
		user="root",
		password="root",
	}
	db:connect()
	local status, res = db:query("show databases;")
	assert(status, res)
	print("query databases:", status, res)
	for _, v in pairs(res) do
		print(v.Database)
	end
	print("test ok")
end

