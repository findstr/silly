local db = require("simpledb")
local usrmgr = {}

function usrmgr.reg(name, uid)
        local u = db.get("db", name)
        if u == nil then
                db.set("db", name, uid)
                db.set("db", uid, name)
                return true;
        else
                return false;
        end
end

function usrmgr.kick(uid)
        local name = db.get("db", uid)
        assert(name)
        db.set("db", name, nil)
        db.set("db", uid, nil)
end


return usrmgr

