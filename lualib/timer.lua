local silly = require("silly")

local timer = {}

function timer.add(ms, handler)
        silly.timer_add(ms, handler)
end

return timer

