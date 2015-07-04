local db = require("simpledb")
local usrmgr = {}

local global_uid = 0

function usrmgr.reg(usr, pwd)
        local pwd = db.get(usr, "pwd")
        if pwd == nil then
                db.set(usr, "pwd", pwd)
                db.set(usr, "uid", global_uid)
                global_uid = global_uid + 1
                return true
        else
                return false
        end
end

function usrmgr.getpwd(usr)
        local pwd = db.get(usr, "pwd")
        return pwd
end


return usrmgr

