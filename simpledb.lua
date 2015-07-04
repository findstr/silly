local simpledb = {
}

local db = {}

function simpledb.set(tbl, key, value)
        db[tbl] = {}
        db[tbl][key] = value
end

function simpledb.get(tbl, key)
        local t = db[tbl]
        if t then
                return t[key]
        else
                return nil
        end
end

return simpledb
