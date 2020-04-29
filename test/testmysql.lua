local core = require "sys.core"
local mysql = require "sys.db.mysql"
local testaux = require "testaux"
local json = require "sys.json"

return function()
	local db = mysql.connect{
		addr ="127.0.0.1:3306",
		user="root",
		password="root",
	}
	local status, res = db:query("select 0;")
	testaux.asserteq(res[1]["0"], 0, "select 0;")
end

