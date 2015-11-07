local silly = require "silly"

local env = {}

function env.get(k)
        return silly.getenv(k)
end

function env.set(k, v)
        return silly.setenv(k, v)
end

return env

