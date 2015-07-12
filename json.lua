local json = {}


function json.decode(str)
        local j = string.gsub(str, '\"([^\"]-)\":','%1=')

        j = "local t =" .. j .."; return t"
 
        t = load(j)()

        return t;
end

local encode_tbl, encode_array

function encode_array(arr)
        local sz = ""
        for _, v in ipairs(arr) do
                assert(type(v) == "table")
                sz = sz .. encode_tbl(v) .. ','
        end

        return sz
end

function encode_tbl(tbl)
        local l = tbl or {}
        local sz

        sz = '{'
        for k, v in pairs(tbl) do
                if (type(v) == "table") then
                        sz = sz .. k .. ':' .. '[' ..  encode_array(v) .. '],'
                else
                        sz = sz ..'"' .. k .. '"' .. ":" .. '"' .. v .. '"' .. ','
                end
        end

        sz = sz .. '}'

        return sz
end

function json.encode(tbl)
        local sz = encode_tbl(tbl)
        return (sz .. '\r\n\r')
end

------------test--------
local tbl = {room={{cmd="auth1", uid = "dafas"},
                {cmd="auth2", sid = "123"}}}

local sz = json.encode(tbl)
print(sz)

return json
