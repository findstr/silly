local db = require("simpledb")
local usrmgr = {}

function usrmgr.reg(name)
        local u = db.get("db", "name")
        if u == nil then
                db.set("db", "name", name);
                return true;
        else
                return false;
        end
end


return usrmgr

