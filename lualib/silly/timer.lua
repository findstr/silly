local silly = require "silly"

local timer = {}

local session_index = 1

local session_function = {}
local session_param = {}

local function get_session_id()
        local id = session_index;

        assert(session_function[id] == nil)

        session_index = session_index + 1
        if (session_index < 0) then
                session_index = 1;
        end

        return id
end

function timer.add(ms, handler, param)
        local session = get_session_id()

        session_function[session] = handler
        session_param[session] = param

        silly.timeradd(ms, session)
end

function timer.current()
        return silly.global_ms()
end

local function timer_handler(session)
        assert(session_function[session])(session_param[session])
        session_function[session] = nil
        session_param[session] = nil
end


silly.timerentry(timer_handler)


return timer

