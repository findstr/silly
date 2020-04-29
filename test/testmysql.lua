local core = require "sys.core"
local mysql = require "sys.db.mysql"
local testaux = require "testaux"

return function()
	local db = mysql.create {
		addr ="127.0.0.1:3306",
		user="root",
		password="root",
	}
	db:connect()
	local status, res = db:query("select 0;")
	testaux.asserteq(res[1]["0"], "0", "select 0;")
end

