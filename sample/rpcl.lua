local core = require "sys.core"
local proto = require "rpcproto"

local DO = {}

local idx = 3


DO[proto:tag("rrpc_sum")] = function(fd, cmd, msg)
	idx = idx + 1
	local arpc_sum = {
		val = msg.val1 + msg.val2,
		suffix = msg.suffix .. ".rpcd." .. idx
	}
	core.log("call", fd, cmd, msg)
	return "arpc_sum", arpc_sum
end

return DO

