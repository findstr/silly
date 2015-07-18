local server = require("server")

local timer = {}

function timer.add(ms, handler)
        server.addtimer(500, handler)
end

return timer

