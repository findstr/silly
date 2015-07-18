local json = {}


function json.decode(str)
        local j = string.gsub(str, '\"([^\"]-)\":','%1=')

        j = "local t =" .. j .."; return t"
 
        print(j)

        t = load(j)()

        return t;
end


return json
