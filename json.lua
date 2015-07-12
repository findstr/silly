local json = {}


function json.decode(str)
        local j = string.gsub(str, '\"([^\"]-)\":','%1=')

        j = "local t =" .. j .."; return t"
 
        t = load(j)()

        return t;
end


function json.encode(tbl)
        local l = tbl or {}
        local sz

        sz = '{'
        for k, v in pairs(tbl) do
                sz = sz ..'"' .. k .. '"' .. ":" .. '"' .. v .. '"' .. ','
        end

        sz = sz .. '}\r\n\r'
        
        return sz
end

------------test--------
--[[ 
local tbl = {cmd="fdas", uid = "dafas"}

local sz = json.encode(tbl)

print(sz)
]]--

return json
