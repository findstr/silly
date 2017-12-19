local core = require "sys.core"
local mysql = require "sys.db.mysql"
local testaux = require "testaux"

return function()
	local db = mysql.create {
		host="127.0.0.1:3306",
		user="root",
		password="root",
	}
	db:connect()
	local status, res = db:query("show databases;")
	print("mysql show databases;", status)
	testaux.asserteq(res[1].Database, "information_schema", "mysql query showdatabases;")
end

