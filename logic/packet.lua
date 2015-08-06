local json = require("json")
local packet = {}

function packet.pack(data)
        local p = json.encode(data)
        return p .. "\n"
end

function packet.unpack(data)
        local cmd = json.decode(data)
        return cmd
end

return packet

