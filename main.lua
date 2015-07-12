local socket= require("socket")
local timer = require("timer")

function timer_handler()
        print("heatbeat~")
        a(3)
        print("fadfasfdasfd")
        timer.add(1000, timer_handler)
end

timer.add(1000, timer_handler)


