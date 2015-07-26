local json = {}


function json.decode(str)
        local j = string.gsub(str, '\"([^\"]-)\":','%1=')

        j = "local t =" .. j .."; return t"
 
        t = load(j)()

        return t;
end

local encode_tbl, encode_array

function encode_array(arr)
        local first = true
        local sz = ""
        for _, v in ipairs(arr) do
                assert(type(v) == "table")
                if first then
                        first = false
                        sz = sz .. encode_tbl(v)
                else
                        sz = sz .. ',' .. encode_tbl(v)
                end
        end

        return sz
end

function encode_tbl(tbl)
        local first = true
        local l = tbl or {}
        local sz

        sz = '{'
        for k, v in pairs(tbl) do
                if (type(v) == "table") then
                        if first  then
                                first = false
                                sz = sz .. k .. ':' .. '[' ..  encode_array(v) .. ']'
                        else
                                sz = sz .. ',' .. k .. ':' .. '[' ..  encode_array(v) .. ']'
                        end
                else
                        if first then
                                first = false
                                sz = sz ..'"' .. k .. '"' .. ":" .. '"' .. v .. '"'
                        else
                                sz = sz ..',' .. '"' .. k .. '"' .. ":" .. '"' .. v .. '"'
                        end
                        
                end
        end

        sz = sz .. '}'

        return sz
end

function json.encode(tbl)
        local sz = encode_tbl(tbl)
        return sz
end

------------test--------
--[[
local tbl = {room={{cmd="auth1", uid = "dafas"},
                {cmd="auth2", sid = "123"}}}

local sz = json.encode(tbl)
print(sz)
]]--
return json
