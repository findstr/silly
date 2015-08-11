local json = {}


function json.decode(str)
        local j = string.gsub(str, '\"([^\"]-)\":','%1=')

        j = "local t =" .. j .."; return t"
 
        t = assert(load(j))()

        return t;
end

local encode_tbl, encode_array, encode_object

local function table_type(tbl)
        assert(type(tbl) == "table")
        for k, v in pairs(tbl) do
                if type(k) ~= "number" then
                        return "object"
                end
        end

        return "array"
end

function encode_array(arr)
        local first = true
        local sz = "["
        for _, v in ipairs(arr) do
                local encode
                if (type(v) == "table") then
                        encode = encode_tbl(v)
                else
                        encode = '"' .. v .. '"'
                end
                
                if first then
                        first = false
                else
                        sz = sz .. ','
                end
                        
                sz = sz .. encode
        end

        return sz .. "]"
end

function encode_object(tbl)
        local sz = ""
        local first = true
        local encode

        sz = "{"
        for k, v in pairs(tbl) do
                if (type(v) == "table") then
                        encode = encode_tbl(v)
                else
                        encode = '"' .. k .. '"' .. ":" .. '"' .. v .. '"'
                end

                if first then
                        first = false
                else
                        sz = sz .. ","
                end
               
                sz = sz .. encode

        end
        sz = sz .. "}"

        return sz
end


function encode_tbl(tbl)
        local sz = ""
        local first = true
        local t;

        assert(type(tbl) == "table")

        t = table_type(tbl)
        if t == "object" then
                sz = sz .. encode_object(tbl)
        elseif t == "array" then
                sz = sz .. encode_array(tbl)
        end

        return sz
end

function json.encode(tbl)
        local sz = encode_tbl(tbl)
        return sz
end

return json


