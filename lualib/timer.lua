local silly = require("silly")

local timer = {}

local closure = {}

function timer.add(ms, handler, session)
        silly.timer_add(ms, handler, session)
end


return timer

